#!/usr/bin/env bash
# ============================================================================
# AgentRT 发布流水线：签名 + manifest 生成 + 上传 atomgit Release
#
# 双轨签名体系（防供应链攻击）：
#   1. cosign —— 对每个 tarball 做 sign-blob，产出 <file>.sig
#   2. GPG    —— 对 manifest.<channel>.json 做 detached 签名（权威校验链）
#
# 通道：tag 含 -beta./-rc. → beta 通道；否则 stable。
#   官方制品仓库：https://atomgit.com/openairymax/agentrt（用户指定）
#   制品 URL:      https://atomgit.com/openairymax/agentrt/releases/download/<tag>/<file>
#   manifest 固定入口（更新器轮询）：仓库代码树 latest/ 目录，
#      URL: https://atomgit.com/openairymax/agentrt/raw/main/latest/manifest.<channel>.json
#      （0.1.6b：主域 raw 路径。raw.atomgit.com 子域对非 Markdown 返回
#      "暂不支持预览"403，部分网络不可达，安装器/更新器一律用主域。）
#
# 用法：
#   ./publish-release.sh v0.1.5 [DIST_DIR]              # stable 发布
#   ./publish-release.sh v0.1.5-beta.1 [DIST_DIR]       # beta 发布
# 环境变量：
#   COSIGN_PRIVATE_KEY / COSIGN_PASSWORD   cosign 私钥（base64 或文件路径）
#   GPG_PRIVATE_KEY / GPG_PASSPHRASE       GPG 私钥（base64）+ 口令
#   ATOMGIT_TOKEN / ATOMGIT_REPO           atomgit 令牌 + 目标仓（默认 openairymax/agentrt）
#   RELEASE_NOTES / RELEASE_NOTES_FILE     变更日志摘要
#   SKIP_SIGN=1 跳过签名（仅生成 manifest）  SKIP_UPLOAD=1 不上传  DRY_RUN=1 模拟
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

VERSION="${1:-}"
DIST_DIR="${2:-${HOME}/.airymaxrt/dist}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_COSIGN="${SKIP_COSIGN:-0}"
SKIP_GPG="${SKIP_GPG:-0}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
ATOMGIT_REPO="${ATOMGIT_REPO:-openairymax/agentrt}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() {
    if [ "$DRY_RUN" = "1" ]; then log_info "DRY-RUN: $*"; else "$@"; fi
}

[ -n "$VERSION" ] || { echo "用法: $0 <版本号> [DIST_DIR]"; exit 1; }

# ─── 通道判定 ──────────────────────────────────────────────────────────────
# 语义：stable（生产）/ beta（预发布）/ rc（候选发布）。rc 独立通道
# （manifest.rc.json），避免与 beta 混淆（问题 10：rc 通道曾塌缩为 beta）。
case "$VERSION" in
    *-rc.*)     CHANNEL="rc";     PRERELEASE="true" ;;
    *-beta.*)   CHANNEL="beta";   PRERELEASE="true" ;;
    *)          CHANNEL="stable"; PRERELEASE="false" ;;
esac
log_info "AgentRT 发布 ${VERSION}（通道: ${CHANNEL}）"
log_info "制品目录: ${DIST_DIR}  目标: ${ATOMGIT_REPO}"

# ─── 收集制品 ──────────────────────────────────────────────────────────────
ARTIFACTS=()
for f in "$DIST_DIR"/agentrt-${VERSION}-*.tar.gz "$DIST_DIR"/agentrt-${VERSION}-*.zip; do
    [ -e "$f" ] || continue
    ARTIFACTS+=("$f")
done
[ ${#ARTIFACTS[@]} -gt 0 ] || { log_fail "未找到制品: ${DIST_DIR}/agentrt-${VERSION}-*.{tar.gz,zip}"; exit 1; }
log_info "制品清单:"
for f in "${ARTIFACTS[@]}"; do log_info "  $(basename "$f")"; done

# ─── 阶段 0.5：发布预检（0.1.6f 强化，fail-closed）──────────────────────
# 准确性门禁：版本号格式 / sha256 校验件一致 / 包大小 sanity / 包内
# 启动器语法。任一不过即中止，杜绝发布损坏或错配制品。
# 0.1.7 修复：原 glob 模式 `v[0-9]*.[0-9]*.[0-9]*[-.+a-zA-Z0-9]*` 中
# [0-9]* 为「一位数字+任意串」glob，且末段要求至少一个后缀字符，
# 纯版本号 v0.1.7（无后缀）被误拒，仅带后缀（如 v0.1.6h）可通过。
# 改用正则：vX.Y.Z 可选后接 -/.+ 开头或直接字母数字的后缀段
# （兼容 0.1.6a~0.1.6h 字母后缀系列，与 release.sh 口径一致）。
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.+][a-zA-Z0-9.]+|[a-zA-Z0-9]+)?$ ]]; then
    log_fail "版本号格式非法: ${VERSION}（应为 vX.Y.Z 或带后缀，如 v0.1.6h、v0.1.7-beta.1）"; exit 1
fi
PREFAIL=0
for f in "${ARTIFACTS[@]}"; do
    if [ ! -f "$f.sha256" ]; then
        log_fail "缺少校验文件: $(basename "$f").sha256"; PREFAIL=1; continue
    fi
    computed="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    declared="$(awk '{print $1}' "$f.sha256" 2>/dev/null)"
    if [ -z "$computed" ] || [ "$computed" != "$declared" ]; then
        log_fail "sha256 不匹配: $(basename "$f")"; PREFAIL=1
    fi
    size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)"
    # 下限 1MB（原 5MB 会误伤小而完整的包，如 macOS-arm64 ~4.6MB）；
    # 仍能拦截 qemu 静默空包（~3KB）等损坏制品。
    if [ -z "$size" ] || [ "$size" -lt 1000000 ]; then
        log_fail "制品异常小（疑似损坏）: $(basename "$f")（${size:-?} 字节）"; PREFAIL=1
    fi
done
# 包内关键组件预检（0.1.6h 漏件教训：启动器 bin/airymaxrt 由安装器
# 生成、包内不含，旧检查 grep 'bin/airymaxrt' 永远不命中形同虚设）。
# 改为 fail-closed：关键二进制缺任一即中止；包内脚本做语法预检。
# 0.1.13 补全（2026-09-06）：此前 REQUIRED_BIN 只列 8 项，漏 7 个 daemon
# （market_d/monit_d/notify_d/channel_d/a2a_d/cupolas_d/maths_d/hook_d）——
# 漏件门禁形同虚设，正是"总是缺东西"的一手原因。现列全 15 daemon 服务 +
# airy_cli + bootstrap；并对全部发布包断言"完整能力"（TUI/config/Python
# 运行时），任一缺失即中止，杜绝半成品出库。
REQUIRED_BIN="airy_cli agentrt-bootstrap.sh gateway_d llm_d think_d sched_d tool_d mem_d agent_d market_d monit_d notify_d channel_d a2a_d cupolas_d maths_d hook_d"
# 完整能力清单（tar.gz 与 zip 通用；Windows 侧二进制带 .exe 后缀，匹配
# 逻辑对 "bin/$b" 与 "bin/$b.exe" 双态容忍）。config/* 由 lf-package 统一
# 注入，lib/{airymax_agents,airymax_agents_rs,orchestration,agentrt} 由
# 各腿构建期拷贝——此前均为 `|| true` 容忍拷贝，缺失即静默漏件。
REQUIRED_SUBTREE="bin/agentrt-tui config/agentrt.yaml config/model.yaml config/secrets.env.example config/permission_rules.yaml lib/airymax_agents lib/airymax_agents_rs lib/orchestration lib/agentrt"
for f in "${ARTIFACTS[@]}"; do
    listing="$(tar -tzf "$f" 2>/dev/null || true)"
    # zip 制品：GNU tar 无法读 zip（listing 空），改用 python 标准库枚举
    if [ -z "$listing" ] && [[ "$f" == *.zip ]]; then
        listing="$(python3 - "$f" <<'PYEOF'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        print("\n".join(z.namelist()))
except Exception:
    pass
PYEOF
)"
    fi
    miss=""
    for b in $REQUIRED_BIN; do
        case "$listing" in
            *"bin/$b"*|*"bin/$b.exe"*) ;;
            *) miss="$miss $b" ;;
        esac
    done
    if [ -n "$miss" ]; then
        log_fail "包内缺少关键组件（漏件）: $(basename "$f"):$miss"; PREFAIL=1
    fi
    # 完整能力断言：缺失即 fail（读完整发布包的组件目录层级）
    miss2=""
    for c in $REQUIRED_SUBTREE; do
        # config 模板在 tar 内位于 config/ 顶目录；zip 内同名
        case "$listing" in
            *"$c"*) ;;
            *) miss2="$miss2 $c" ;;
        esac
    done
    if [ -n "$miss2" ]; then
        log_fail "包内缺少能力组件（半成品）: $(basename "$f"):$miss2"; PREFAIL=1
    fi
    tmpext="$(mktemp -d)"
    if echo "$listing" | grep -q 'bin/agentrt-bootstrap.sh'; then
        if tar -xzf "$f" -C "$tmpext" --wildcards '*/bin/agentrt-bootstrap.sh' 2>/dev/null; then
            script="$(find "$tmpext" -name 'agentrt-bootstrap.sh' -type f | head -1)"
            if [ -n "$script" ] && ! bash -n "$script" 2>/dev/null; then
                log_fail "包内 agentrt-bootstrap.sh 语法预检失败: $(basename "$f")"; PREFAIL=1
            fi
        fi
    fi
    rm -rf "$tmpext"
done
[ "$PREFAIL" = "0" ] || { log_fail "发布预检未通过（${PREFAIL} 项），中止"; exit 1; }
log_ok "发布预检通过: ${#ARTIFACTS[@]} 个制品（sha256 一致 + 大小正常 + 关键二进制齐 + 能力组件齐 + 启动器语法 OK）"

# ─── 阶段 1：cosign 签名每个制品 ──────────────────────────────────────────
if [ "$SKIP_SIGN" = "1" ] || [ "$SKIP_COSIGN" = "1" ]; then
    log_warn "跳过 cosign 制品签名（SKIP_SIGN/SKIP_COSIGN）"
else
    command -v cosign >/dev/null 2>&1 || { log_fail "cosign 未安装"; exit 1; }
    COSIGN_KEY_FILE="${COSIGN_PRIVATE_KEY:-}"
    if [ -n "$COSIGN_KEY_FILE" ] && [ ! -f "$COSIGN_KEY_FILE" ]; then
        COSIGN_KEY_FILE="$TMP/cosign.key"
        printf '%s' "${COSIGN_PRIVATE_KEY}" | base64 -d > "$COSIGN_KEY_FILE" 2>/dev/null || \
            printf '%s\n' "${COSIGN_PRIVATE_KEY}" > "$COSIGN_KEY_FILE"
        chmod 600 "$COSIGN_KEY_FILE"
    fi
    [ -n "$COSIGN_KEY_FILE" ] || { log_fail "缺少 COSIGN_PRIVATE_KEY"; exit 1; }
    for f in "${ARTIFACTS[@]}"; do
        if [ -s "${f}.sig" ]; then
            log_ok "cosign 签名已存在: $(basename "$f").sig"
            continue
        fi
        log_info "cosign 签名: $(basename "$f")…"
        # --tlog-upload=false：静态密钥签名无需透明日志（避免交互确认与
        # 公网 tlog 依赖，企业/离线场景更友好）；--yes 跳过 cosign 确认提示。
        run env COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign-blob \
            --key "$COSIGN_KEY_FILE" --tlog-upload=false --yes \
            --output-signature "${f}.sig" "$f" >/dev/null
        [ "$DRY_RUN" = "1" ] || [ -s "${f}.sig" ] || { log_fail "签名失败: $f"; exit 1; }
        log_ok "cosign 签名: $(basename "$f").sig"
    done
fi

# ─── 阶段 2：生成 manifest.<channel>.json ─────────────────────────────────
MANIFEST="$DIST_DIR/manifest.${CHANNEL}.json"
RELEASE_BASE="https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}"
NOTES="${RELEASE_NOTES:-}"
if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi
log_info "生成 manifest（${CHANNEL}）…"
# 幂等保护：manifest 已存在则不重生成——updated_at 漂移会使既有 .asc 签名
# 失配（GPG 对整文件签名），断点重跑场景下绝不能静默漂移已签名内容。
# 需强制重建时删除旧 manifest 再跑。
if [ -s "$MANIFEST" ]; then
    log_ok "manifest 已存在，跳过重生成（保护既有签名一致性）: $(basename "$MANIFEST")"
else
python3 - "$VERSION" "$CHANNEL" "$DIST_DIR" "$RELEASE_BASE" "$NOTES" "$MANIFEST" <<'PYEOF'
import json, os, sys, datetime

version, channel, dist_dir, release_base, notes, out = sys.argv[1:7]
artifacts = {}
for fn in sorted(os.listdir(dist_dir)):
    # 匹配 agentrt-<version>-<os>-<arch>.{tar.gz,zip}
    prefix = f"agentrt-{version}-"
    if not fn.startswith(prefix):
        continue
    suffix = fn[len(prefix):]
    if not (suffix.endswith(".tar.gz") or suffix.endswith(".zip")):
        continue
    plat = suffix[: -len(".tar.gz")] if suffix.endswith(".tar.gz") else suffix[: -len(".zip")]
    path = os.path.join(dist_dir, fn)
    sha = ""
    sha_file = path + ".sha256"
    if os.path.exists(sha_file):
        sha = open(sha_file).read().strip().split()[0]
    if not sha:
        import hashlib
        sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    artifacts[plat] = {
        "url": f"{release_base}/{fn}",
        "sha256": sha,
        "size": os.path.getsize(path),
    }

# 平台命名规范（0.1.10 起，用户定案）：OS-架构族-位宽（linux-x86-64 /
# macos-arm-64 / windows-x86-64 …），弃用 i686/armv7l/x64/arm64 行话。
# manifest 主键即文件名平台段；此处为存量客户端补两代旧命名别名（同一
# url/sha256/size），一次发布惠及全部旧安装器/更新器：
#   gen2（0.1.6e~0.1.10）：linux-x64/x86/arm64/arm32、macos-x64/arm64、
#     windows-x64/win-x64 …（win- 前缀仅历史存在，未曾实际发布）
#   gen1（≤0.1.6d）：uname 原始名 linux-x86_64/i686/aarch64/armv7l …
# 与 install.sh / airymaxrt plat_legacy_name 同口径（SSoT）。
ALIAS = {
    "linux-x86-64":   ["linux-x64", "linux-x86_64"],
    "linux-x86-32":   ["linux-x86", "linux-i686"],
    "linux-arm-64":   ["linux-arm64", "linux-aarch64"],
    "linux-arm-32":   ["linux-arm32", "linux-armv7l"],
    "linux-riscv-64": ["linux-riscv64"],
    "linux-riscv-32": ["linux-riscv32"],
    "macos-x86-64":   ["macos-x64", "macos-x86_64"],
    "macos-arm-64":   ["macos-arm64", "macos-aarch64"],
    "windows-x86-64": ["windows-x64", "windows-x86_64", "win-x64", "win-x86_64"],
    "windows-x86-32": ["windows-x86", "windows-i686", "win-x86", "win-i686"],
    "windows-arm-64": ["windows-arm64", "windows-aarch64", "win-arm64", "win-aarch64"],
}
for plat in list(artifacts):
    for alias in ALIAS.get(plat, ()):
        artifacts.setdefault(alias, artifacts[plat])

manifest = {
    "schema": 1,
    "channel": channel,
    "latest": version,
    "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "releases": {
        version: {
            "yanked": False,
            "notes": notes,
            "artifacts": artifacts,
        }
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"manifest 已生成: {out}（{len(artifacts)} 平台键，含旧命名别名）")
PYEOF
fi
log_ok "manifest: $(basename "$MANIFEST")"

# ─── 阶段 3：GPG 签名 manifest（权威） ───────────────────────────────────
if [ "$SKIP_SIGN" = "1" ] || [ "$SKIP_GPG" = "1" ]; then
    log_warn "跳过 manifest GPG 签名（SKIP_SIGN/SKIP_GPG）"
else
    command -v gpg >/dev/null 2>&1 || { log_fail "gpg 未安装"; exit 1; }
    if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
        printf '%s' "${GPG_PRIVATE_KEY}" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null || \
            printf '%s\n' "${GPG_PRIVATE_KEY}" | gpg --batch --import 2>/dev/null
    fi
    # 校验公钥指纹与仓库内置一致（防私钥张冠李戴）：取导入私钥的真实指纹
    # 与 keys/agentrt.fingerprint 硬比对，不符立即失败，杜绝签出客户端
    # 无法验证的 manifest。
    BUILTIN_FPR="$(cat "$KEYS_DIR/agentrt.fingerprint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$BUILTIN_FPR" ]; then
        IMPORTED_FPR="$(gpg --batch --list-keys --with-colons 2>/dev/null | \
            awk -F: '$1=="fpr" {print $10}' | head -1)"
        if [ -n "$IMPORTED_FPR" ] && [ "$(echo "$IMPORTED_FPR" | tr -d '[:space:]')" != "$BUILTIN_FPR" ]; then
            log_fail "GPG 指纹不匹配：导入私钥 ${IMPORTED_FPR} != 内置基线 ${BUILTIN_FPR}"
            exit 1
        fi
        log_info "公钥指纹基线: ${BUILTIN_FPR}（与导入私钥一致）"
    fi
    if [ -f "$MANIFEST.asc" ]; then
        log_warn "已存在签名，跳过: $(basename "$MANIFEST").asc"
    else
        run gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${GPG_PASSPHRASE:-}" --armor --detach-sign \
            -o "$MANIFEST.asc" "$MANIFEST"
        [ "$DRY_RUN" = "1" ] || [ -s "$MANIFEST.asc" ] || { log_fail "GPG 签名失败"; exit 1; }
        log_ok "GPG 签名: $(basename "$MANIFEST").asc"
    fi
fi

# ─── 阶段 4：上传 atomgit Release ─────────────────────────────────────────
if [ "$SKIP_UPLOAD" = "1" ] || [ -z "${ATOMGIT_TOKEN:-}" ]; then
    log_warn "跳过上传（SKIP_UPLOAD=1 或未配置 ATOMGIT_TOKEN）；产物保留在 ${DIST_DIR}/"
    ls -la "$DIST_DIR" | grep -E "agentrt-${VERSION}|manifest" || true
    exit 0
fi

API="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}/releases"
RELEASE_BODY="${NOTES:-AgentRT ${VERSION}}"
log_info "创建/更新 Release ${VERSION}…"
# atomgit API v5（Gitee 兼容，Base api.atomgit.com）：PRIVATE-TOKEN 认证。
# release 对象无 id 字段，以 tag_name 存在性探测（幂等），不存在则创建。
TAG_EXISTS="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    "${API}/tags/${VERSION}" 2>/dev/null | python3 -c "import sys,json;print(1 if (json.load(sys.stdin) or {}).get('tag_name') else '')" 2>/dev/null || true)"
if [ -z "$TAG_EXISTS" ]; then
    curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary "$(python3 -c "import json,sys;print(json.dumps({'tag_name':sys.argv[1],'name':'AgentRT '+sys.argv[1],'body':sys.argv[2],'prerelease':sys.argv[3]}))" "$VERSION" "$RELEASE_BODY" "$PRERELEASE")" \
        "${API}" >/dev/null 2>&1 || { log_fail "Release 创建失败（检查 ATOMGIT_TOKEN 与 ${ATOMGIT_REPO} 权限）"; exit 1; }
fi
log_ok "Release 就绪: ${VERSION}（${ATOMGIT_REPO}）"

# 附件上传走预签名两步流（POST /releases/{tag}/attach_files 端点不存在，
# 服务端 404）：GET /releases/{tag}/upload_url?file_name=X 返回 OBS 预签名
# {url, headers}，再 PUT 文件体到预签名 URL。
# 同名附件已存在则跳过（重跑幂等续传）；任一失败累计后 fail-closed，
# 绝不假报成功——自更新链依赖附件与 manifest 一致。
# 0.1.10 修复发布实证（2026-09-05）：同名附件"覆盖"上传不可靠——atomgit
# upload_url 每次签发全新 OBS key，PUT 到新对象后 release 附件记录未切绑，
# 下载仍返回旧文件（tar.gz 新旧大小差即暴露，sha256/sig 恒长假绿）。因此
# AIRY_FORCE_UPLOAD=1 的正确语义 = 先 DELETE 同名附件（全新 key 绑定）再 PUT。
UP_FAILED=0
# 拉取现有附件 {name<TAB>id}（attach 有数字 id，source 源码包无 id）
EXISTING_ASSETS="$(curl -fsSL --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    "${API}/tags/${VERSION}" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(f\"{a.get('name','')}\t{a.get('id') or ''}\" for a in (json.load(sys.stdin).get('assets') or [])))" 2>/dev/null || true)"

# 删除远端同名附件（AIRY_FORCE_UPLOAD=1 先删后传；DELETE 失败仅告警不阻断，
# PUT 本身带幂等，残留旧附件会再暴露于上传后校验并 fail-closed）。
delete_existing_asset() {
    local b="$1" aid
    aid="$(awk -F '\t' -v n="$b" '$1==n{print $2;exit}' <<<"$EXISTING_ASSETS")"
    [ -n "$aid" ] || return 0
    if curl -fsS --connect-timeout 20 -X DELETE -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        "${API}/${VERSION}/attach_files/${aid}" >/dev/null 2>&1; then
        log_ok "已删除远端同名附件（先删后传）: ${b} (asset ${aid})"
    else
        log_warn "远端附件删除失败（upload_url 将签发新 key，残留风险由校验兜底）: ${b}"
    fi
}

# 远端是否已存在同名附件（精确匹配，防文件名含 . 触发的正则误判）
asset_exists() {
    awk -F '\t' -v n="$1" '$1==n{found=1} END{exit !found}' <<<"$EXISTING_ASSETS"
}

upload_asset() {
    local f="$1" b upjson upurl
    b="$(basename "$f")"
    # 幂等跳过：同名附件已存在且未强制 → 跳过（重跑续传）。同版本修复重发
    # 必须 AIRY_FORCE_UPLOAD=1：先删后传（delete_existing_asset），否则 OBS
    # 覆盖不生效、下载仍是旧文件（0.1.10 同 tag 重发实证）。
    if asset_exists "$b"; then
        if [ "${AIRY_FORCE_UPLOAD:-0}" != "1" ]; then
            log_warn "跳过（远端已存在同名附件，AIRY_FORCE_UPLOAD=1 可先删后传）: ${b}"
            return 0
        fi
        delete_existing_asset "$b"
    fi
    log_info "上传: ${b}…"
    upjson="$(curl -fsSG --connect-timeout 20 -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        --data-urlencode "file_name=${b}" "${API}/${VERSION}/upload_url")" \
        || { log_fail "upload_url 获取失败: ${b}"; return 1; }
    upurl="$(python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("url",""))' <<<"$upjson")"
    [ -n "$upurl" ] || { log_fail "upload_url 为空: ${b}"; return 1; }
    local -a uphdr=()
    mapfile -t uphdr < <(python3 -c 'import json,sys
for k, v in ((json.load(sys.stdin) or {}).get("headers") or {}).items():
    print("-H"); print(f"{k}: {v}")' <<<"$upjson")
    # PUT 超时 3600s（0.2.0 加固，v0.1.9 R16 实证）：GitHub 美东 runner →
    # atomgit/OBS 上传 ~20MB 需 ~15min，原 --max-time 900 恰在临界掐断大包
    # （arm64/x64 两包同时在 900s 处失败）。上传在本地（大陆 → OBS）通常
    # 数秒级，3600s 为远端/弱网环境留足余量。
    if curl -fsS --connect-timeout 20 --max-time 3600 -X PUT \
        "${uphdr[@]}" --upload-file "$f" "$upurl" >/dev/null; then
        # 上传后完整性校验（0.1.6f 强化，fail-closed）：GET 实际下载
        # 大小必须等于本地大小，防 OBS 截断/静默失败。0.1.10 实证补强：
        # 仅比大小会漏 sha256/sig/manifest 等恒长小文件的覆盖失败（新旧
        # 内容等长），故对非 tar.gz 附件追加 sha256 内容比对（大包受
        # --max-time 300 下载约束，维持大小校验 + 文件名可判别覆盖与否）。
        local local_size dl
        local_size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)"
        dl="$(curl -fsSL --connect-timeout 20 --max-time 300 -o /dev/null -w '%{size_download}' \
            "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}/${b}" 2>/dev/null || echo 0)"
        if [ "$dl" = "$local_size" ] && [ "$dl" != "0" ]; then
            case "$b" in
              *.tar.gz|*.zip)
                log_ok "已上传并校验: ${b}（${dl} 字节）" ;;
              *)
                # 恒长小文件（sha256/sig/asc/install.*/manifest）做 sha256 内容
                # 比对，杜绝"等长旧文件假绿"（0.1.10 同 tag 覆盖未生效实证）。
                # 下载走临时文件（set -euo pipefail 下 curl|sha256sum 管道
                # 失败会直接中止脚本而非走失败分支，临时文件 + if 可兜底）。
                local local_sha dl_sha dlf
                local_sha="$(sha256sum "$f" | awk '{print $1}')"
                dlf="$(mktemp)"
                dl_sha=""
                if curl -fsSL --connect-timeout 20 --max-time 120 \
                    "https://atomgit.com/${ATOMGIT_REPO}/releases/download/${VERSION}/${b}" \
                    -o "$dlf" 2>/dev/null; then
                    dl_sha="$(sha256sum "$dlf" | awk '{print $1}')"
                fi
                rm -f "$dlf"
                if [ "$dl_sha" = "$local_sha" ]; then
                    log_ok "已上传并校验: ${b}（sha256 一致）"
                else
                    log_fail "上传完整性校验失败: ${b}（sha256 不一致，疑似覆盖未生效）"
                    return 1
                fi ;;
            esac
        else
            log_fail "上传完整性校验失败: ${b}（远端 ${dl:-0} != 本地 ${local_size:-0} 字节）"
            return 1
        fi
    else
        log_fail "上传失败: ${b}"
        return 1
    fi
}

# ─── 阶段 4.5：并行上传所有附件 ────────────────────────────────────────

# 上传制品 + sha256 校验件 + cosign 签名（*.sig）+ manifest + manifest GPG 签名。
# cosign 签名必须随制品发布，客户端方可校验供应链完整性（防断链）；
# sha256 校验件同步发布，供手动完整性核验（sha256sum -c）。
# 安装器一并随附件发布（releases/download/<tag>/install.sh）：AtomGit raw
# 域对 .sh 返回 HTML 预览页不可直连，contents API 拉取需 curl+python3 三段
# 管道，社区用户体验差；release 附件域匿名 GET 直连可用（2026-08-28 实测，
# HEAD 会被 WAF 拒 401，GET 正常），一键安装命令缩短为一行 curl | bash。
INSTALLER_SRC="${AIRY_INSTALLER_SRC:-${SCRIPT_DIR}/../../../../agent-workload/agentrt/scripts/install.sh}"
INSTALLER_PS1_SRC="${AIRY_INSTALLER_PS1_SRC:-${SCRIPT_DIR}/../../../../agent-workload/agentrt/scripts/install.ps1}"
INSTALLER=""
if [ -f "$INSTALLER_SRC" ]; then
    INSTALLER="$INSTALLER_SRC"
else
    log_warn "未找到安装器源: ${INSTALLER_SRC}（一键安装短链将不可用）"
fi
# Windows 安装器随附件一并发布（raw 域对 .ps1 返回 HTML 不可直连，
# release 附件域匿名 GET 直连可用，PowerShell 一键安装命令缩短为一行）。
INSTALLER_PS1=""
if [ -f "$INSTALLER_PS1_SRC" ]; then
    INSTALLER_PS1="$INSTALLER_PS1_SRC"
else
    log_warn "未找到 Windows 安装器源: ${INSTALLER_PS1_SRC}（PowerShell 一键安装将不可用）"
fi
# 安装器快照同步（SSoT → developbuild 离线归档快照，0.1.6 根治历史漂移）：
# agentrt/scripts/install.{sh,ps1} 是安装器唯一权威源（SSoT）；发布时必须
# 同步到 developbuild/agentrt/scripts 快照（离线介质 install-offline.sh 的
# 自包含依赖），否则两处脚本再次分叉（历史教训：0.1.5 快照残留旧公钥与
# 旧版本号，导致离线安装与在线安装行为不一致）。
SNAPSHOT_DIR="${AIRY_DEVELOPBUILD_SNAPSHOT_DIR:-${SCRIPT_DIR}/../../../../developbuild/agentrt/scripts}"
if [ -d "$SNAPSHOT_DIR" ] && [ -f "$INSTALLER_SRC" ] && [ -f "$INSTALLER_PS1_SRC" ]; then
    cp -f "$INSTALLER_SRC" "$SNAPSHOT_DIR/install.sh"
    cp -f "$INSTALLER_PS1_SRC" "$SNAPSHOT_DIR/install.ps1"
    log_ok "安装器快照已同步: ${SNAPSHOT_DIR}"
fi
# 并行上传（0.1.6f 强化）：6 架构 × 3 附件 + manifest/installer 约 24 文件，
# 串行 PUT 大包（35-45MB）耗时显著；限 3 并发（避免打爆 atomgit API 限流），
# 任一失败记入失败清单，全部结束后 fail-closed 中止。
# I-upload（0.1.13）：并发数参数化（UPLOAD_PAR 环境可调）。2026-09-06 正式
# run 34031064018 实证：3 并发下总吞吐 ~80KB/s（178MB/37min，单流 23-64KB/s），
# 疑似单连接级限流 → 提高并发或可线性增益；边界由 upload-speed-probe.sh 在
# runner 侧 A/B 实测（PAR=3/6/8）定界后再调默认值。
UPLOAD_PAR="${UPLOAD_PAR:-3}"
UP_FAIL_LOG="$TMP/upfailed.txt"
rm -f "$UP_FAIL_LOG"
for f in "${ARTIFACTS[@]}" "${ARTIFACTS[@]/%/.sha256}" "${ARTIFACTS[@]/%/.sig}" "$MANIFEST" "$MANIFEST.asc" "$INSTALLER" "$INSTALLER_PS1"; do
    [ -e "$f" ] || continue
    ( upload_asset "$f" || echo "$(basename "$f")" >> "$UP_FAIL_LOG" ) &
    while [ "$(jobs -rp | wc -l)" -ge "$UPLOAD_PAR" ]; do wait -n 2>/dev/null || break; done
done
wait 2>/dev/null || true
if [ -s "$UP_FAIL_LOG" ]; then
    log_fail "存在上传失败附件（$(wc -l < "$UP_FAIL_LOG") 个），中止发布（修复后重跑可续传，已成功附件自动跳过）:"
    sed 's/^/  /' "$UP_FAIL_LOG" | head -10
    exit 1
fi

# ─── 阶段 5：更新 latest/ 固定入口（更新器轮询） ─────────────────────────
if [ "${SKIP_LATEST:-0}" != "1" ]; then
    log_info "更新 latest/ 固定入口…"
    LATEST_DIR="$TMP/agentrt-latest"
    run git clone --depth 1 "https://oauth2:${ATOMGIT_TOKEN}@atomgit.com/${ATOMGIT_REPO}.git" "$LATEST_DIR"
    if [ "$DRY_RUN" != "1" ]; then
        mkdir -p "$LATEST_DIR/latest/keys"
        cp -f "$MANIFEST" "$MANIFEST.asc" "$LATEST_DIR/latest/" 2>/dev/null || true
        # 公钥随 latest/ 发布（latest/keys/），客户端安装器/自更新器在线拉取，
        # 支持密钥轮换同步（问题 13）。与 install.sh / airymaxrt 拉取路径一致。
        cp -f "$KEYS_DIR/agentrt.asc" "$KEYS_DIR/cosign.pub" "$LATEST_DIR/latest/keys/" 2>/dev/null || true
        # 完整更新器随 latest/ 发布（latest/airymaxrt）：二进制模式轻量启动器
        # 的 update 自举源。sdk 仓私有，匿名 contents API 不可达，自举源必须
        # 在公开 agentrt 仓内（与 manifest 同路径域，无需额外凭据）。
        LAUNCHER_SRC="${AIRY_LAUNCHER_SRC:-${SCRIPT_DIR}/../../../../agent-workload/sdk/tui/scripts/airymaxrt}"
        if [ -f "$LAUNCHER_SRC" ]; then
            cp -f "$LAUNCHER_SRC" "$LATEST_DIR/latest/airymaxrt"
        else
            log_warn "未找到更新器源: ${LAUNCHER_SRC}（二进制模式 update 自举将不可用）"
        fi
        # 仓库 .gitignore 为白名单制（默认忽略一切），latest/ 天然被忽略，
        # 必须 -f 强制加入，否则 add 静默失败且 set -e 中止整个发布。
        git -C "$LATEST_DIR" add -A -f latest/
        git -C "$LATEST_DIR" -c user.name="agentrt-bot" -c user.email="release@agentrt.airymax.io" \
            commit -m "release: update manifest.${CHANNEL}.json for ${VERSION}" >/dev/null 2>&1 || \
            log_warn "latest/ 无变更或提交失败"
        git -C "$LATEST_DIR" push origin HEAD:main >/dev/null 2>&1 || \
            log_warn "latest/ push 失败（可手动同步）"
        # P23 根修：manifest commit 双端同步。历史缺陷（6186a5cd1 实证）：
        # 本阶段只 clone/push atomgit，GitHub main 永远收不到 manifest 更新
        # commit，双端分叉只能手动 merge（cef8f277 补丁）。两仓为同一提交图
        # 的镜像，此处向 GitHub main 补推同一 commit（fail-soft：失败仅告警，
        # 不阻断 atomgit 发布主链路）。
        if [ -n "${GITHUB_REPO:-}" ] && [ -n "${GITHUB_PAT:-}" ]; then
            if git -C "$LATEST_DIR" push \
                "https://x-access-token:${GITHUB_PAT}@github.com/${GITHUB_REPO}.git" \
                HEAD:main >/dev/null 2>&1; then
                log_ok "latest/ manifest 已同步 GitHub main"
            else
                log_warn "latest/ manifest 同步 GitHub 失败（双端分叉时 non-fast-forward，需手动 merge）"
            fi
        else
            log_warn "GITHUB_REPO/GITHUB_PAT 未设置，跳过 GitHub manifest 同步"
        fi
        log_ok "latest/manifest.${CHANNEL}.json 已更新"
    fi
fi

log_ok "发布完成: ${VERSION}（${CHANNEL}）"
