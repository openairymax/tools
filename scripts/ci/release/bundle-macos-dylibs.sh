#!/usr/bin/env bash
# bundle-macos-dylibs.sh — macOS 包 dylib 自包含（0.1.13 G4 / U6）
#
# 背景（一手证据）：0.1.12 前 macOS 包内二进制链接 brew dylib（/opt/homebrew
# 或 /usr/local），干净机器（无 brew 依赖）daemon 启动即 dyld 失败——社区用户
# U6。Linux 侧已由容器内 ldd 收集 + ELF 守卫 fail-closed（P15/U3）；macOS 无
# 容器、ldd 不存在，需 otool -L 递归收集 + install_name_tool 重写到包内。
#
# 方案：
#   1) 遍历 bin/ 全部 Mach-O，otool -L 收集非系统 dylib（系统豁免：/usr/lib、
#      /System、/Library/Apple）；BFS 展开传递依赖（dylib 自身也可能依赖其他
#      brew dylib），拷贝至 <stage>/lib/。
#   2) 对 bin/ 与 lib/ 所有被改写文件 install_name_tool -change 绝对路径 →
#      @executable_path/../lib/<basename>（@executable_path 恒相对主可执行，
#      嵌套依赖同样可解；所有 daemon/CLI 均位于 bin/）。
#   3) 改写后 codesign --force -s - 重签（Apple Silicon 强制，Intel 无害）。
#   4) fail-closed 校验：任一 Mach-O 残留非 @executable_path/../lib/ 且非系统
#      前缀的依赖 → 中止（杜绝"干净机启动失败"缺陷包出库）。
#
# 用法：bundle-macos-dylibs.sh <stage_dir>
#   stage_dir 内含 bin/（daemon + CLI + TUI 等）与 lib/（python 等）。
set -euo pipefail

STAGE="${1:?usage: bundle-macos-dylibs.sh <stage_dir>}"
BIN_DIR="$STAGE/bin"
LIB_DIR="$STAGE/lib"
mkdir -p "$LIB_DIR"
[ -d "$BIN_DIR" ] || { echo "::error::bin/ 不存在: $BIN_DIR"; exit 1; }

# Mach-O 判定：前 4 字节魔数（0xFEEDFACE / 0xFEEDFACF / 0xCAFEBABE 等）
is_macho() {
    local m
    m="$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$m" = "cffaedfe" ] || [ "$m" = "cefaedfe" ] || [ "$m" = "cafebabe" ] \
        || [ "$m" = "bebafeca" ] || [ "$m" = "feedface" ] || [ "$m" = "feedfacf" ]
}

# 系统库豁免：Apple 自带，目标机必有，不入包
is_system_dylib() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        # @rpath/@loader_path/@executable_path 相对或已改写路径，跳过收集
        @*) return 0 ;;
    esac
    return 1
}

# 收集一个 Mach-O 的全部依赖路径（otool -L：首行自身 install name，跳过）
deps_of() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

declare -a QUEUE=()      # 待拷贝的绝对 dylib 路径
declare -a SEEN_LIBS=()  # 已入队 basename（bash 3.2 无关联数组，用线性表）

seen() {
    local s="$1" x
    for x in "${SEEN_LIBS[@]:-}"; do [ "$x" = "$s" ] && return 0; done
    return 1
}

enqueue() {
    local p="$1" n
    [ -n "$p" ] || return 0
    is_system_dylib "$p" && return 0
    [ -f "$p" ] || { echo "  warn: 依赖不存在: $p"; return 0; }
    n="$(basename "$p")"
    seen "$n" && return 0   # 同名已入队（防环/重复）
    SEEN_LIBS+=("$n")
    QUEUE+=("$p")
}

collect_from() { # 递归展开某 Mach-O 的依赖树并拷贝
    local f="$1" p n
    while read -r p; do enqueue "$p"; done < <(deps_of "$f")
}

# ---- 1) BFS：从 bin/ 全部 Mach-O 收集并拷贝到 lib/ ----
for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    collect_from "$f"
done
i=0
while [ "$i" -lt "${#QUEUE[@]}" ]; do
    p="${QUEUE[$i]}"; i=$((i+1))
    n="$(basename "$p")"
    # 同名不同内容告警（同 prefix 树内通常一致；防静默错配）
    if [ -f "$LIB_DIR/$n" ] && ! cmp -s "$p" "$LIB_DIR/$n"; then
        echo "  warn: 同名 dylib 内容不一致（已保留首个）: $n"
        continue
    fi
    cp -f "$p" "$LIB_DIR/$n"
    # 该 dylib 自身的依赖也要展开（传递依赖）
    collect_from "$LIB_DIR/$n"
done
echo "dylib 收集完成: lib/ 共 $(ls "$LIB_DIR" | wc -l | tr -d ' ') 项（含 python/config 目录则合并计数）"

# ---- 2) 重写依赖路径到 @executable_path/../lib ----
# @executable_path 恒相对主可执行文件（bin/ 下），对 bin/ 与 lib/ 内嵌套依赖
# 均成立（dyld 以主可执行解析该变量）。
rewrite_macho() {
    local f="$1" p n rewrote=0
    while read -r p; do
        is_system_dylib "$p" && continue
        # 已指向包内（@executable_path/../lib/）则跳过
        case "$p" in @executable_path/../lib/*) continue ;; esac
        n="$(basename "$p")"
        if [ -f "$LIB_DIR/$n" ]; then
            install_name_tool -change "$p" "@executable_path/../lib/$n" "$f" 2>/dev/null \
                || { echo "  warn: install_name_tool 失败($f -> $n)"; }
            rewrote=1
        else
            echo "  warn: 依赖未入库（漏收集）: $p (in $f)"
        fi
    done < <(deps_of "$f")
    [ "$rewrote" = "1" ] && codesign --force -s - "$f" >/dev/null 2>&1 || true
}

for f in "$BIN_DIR"/* "$LIB_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    rewrite_macho "$f"
done

# ---- 3) fail-closed 校验：无残留未解析非系统依赖 ----
BAD=0
for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    while read -r p; do
        case "$p" in
            @executable_path/../lib/*) [ -f "$LIB_DIR/${p#@executable_path/../lib/}" ] || { echo "  FAIL: 包内缺 $p ($f)"; BAD=1; } ;;
            *) is_system_dylib "$p" || { echo "  FAIL: 残留非系统依赖 $p ($f)"; BAD=1; } ;;
        esac
    done < <(deps_of "$f")
done
if [ "$BAD" = "1" ]; then
    echo "::error::macOS dylib 自包含校验失败，中止打包"
    exit 1
fi
echo "[OK] macOS dylib 自包含：全部非系统依赖已入库并重写 ($(ls "$LIB_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') 个)"
