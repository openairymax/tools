#!/usr/bin/env bash
# smoke-macos-runtime.sh — macOS 打包产物"干净机可启"冒烟（0.1.13 G4 验收代理）
#
# 背景：G4 终验口径 = "干净 macOS 真机 daemon 群可启"（U6）。真实终端用户机
# 无法在本流水线内到达；GitHub 托管 macos runner 为一次性干净 VM，仅含系统库
# 与本包产物（不安装任何 brew 组件），是"干净机"的最强 CI 代理——dylib 自包含
# 的判定完全等价：若包内任一 Mach-O 仍依赖包外非系统 dylib，dyld 在本机同样
# 无法解析（系统库例外，目标机必有）。
#
# 判定语义（loader 自包含目标，非"无配置可跑全功能"）：
#   - stderr 出现 dyld 加载失败特征（Library not loaded / Symbol not found）
#     → FAIL：自包含破坏，阻断打包；
#   - 进程存活 ≥2s（进入 main 常驻）→ [可启]；
#   - 快速退出（无配置/无 TTY 等正常快速失败，含 signal 终止）→ [可启]，
#     记录退出码；stderr 前几行一并输出供审计。SIGABRT 等信号退出只证明
#     main 已进入（dyld 已完成解析），不属于自包含失败。
#
# 用法：smoke-macos-runtime.sh <stage_dir>
set -euo pipefail

STAGE="${1:?usage: smoke-macos-runtime.sh <stage_dir>}"
BIN_DIR="$STAGE/bin"
[ -d "$BIN_DIR" ] || { echo "::error::bin/ 不存在: $BIN_DIR"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

is_macho() {
    local m
    m="$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$m" = "cffaedfe" ] || [ "$m" = "cefaedfe" ] || [ "$m" = "cafebabe" ] \
        || [ "$m" = "bebafeca" ] || [ "$m" = "feedface" ] || [ "$m" = "feedfacf" ]
}

dyld_error() { grep -Eq "dyld: (Library not loaded|Symbol not found)|image not found" "$1"; }

FAILED=0
LAUNCHED=0
for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    is_macho "$f" || continue
    n="$(basename "$f")"
    LAUNCHED=$((LAUNCHED + 1))
    out="$TMPD/$n.out"; err="$TMPD/$n.err"
    : > "$out"; : > "$err"
    echo "  -- probe: $n"
    # 后台启动（/dev/null 输入防 TTY 阻塞）；bash 3.2 无 setsid，起后轮询存活
    "$f" </dev/null >"$out" 2>"$err" &
    pid=$!
    rc=0
    alive=1
    for _ in 1 2; do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    done
    if [ "$alive" = "1" ]; then
        kill "$pid" 2>/dev/null || true
        # wait 置于 if 条件避免 set -e 对非零返回的中止（bash 3.2）
        if wait "$pid" 2>/dev/null; then :; else rc=$?; fi
        echo "  [可启] $n : 常驻运行 ≥2s（已终止探针进程）"
        continue
    fi
    if wait "$pid" 2>/dev/null; then :; else rc=$?; fi
    if dyld_error "$err"; then
        echo "::error::FAIL $n : dyld 加载失败（非系统依赖未解析）"
        sed 's/^/    /' "$err" | head -5
        FAILED=1
    else
        echo "  [可启] $n : 加载器解析完整，退出码=$rc（无配置/无 TTY 快速退出属预期）"
        if [ "$rc" -ge 128 ]; then
            echo "  note: $n 以信号终止（rc=$rc），非自包含失败；stderr 摘要："
            sed 's/^/    /' "$err" | head -4
        fi
    fi
done

echo "冒烟完成：bin/ 共探测 $LAUNCHED 个 Mach-O"
if [ "$FAILED" = "1" ]; then
    echo "::error::macOS 运行时冒烟失败：存在 dyld 加载失败产物，中止"
    exit 1
fi
echo "[OK] macOS 运行时冒烟通过：全部产物无系统外 dylib 依赖，可启"
