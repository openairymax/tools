#!/usr/bin/env bash
# upload-speed-probe.sh — atomgit 附件上传并发 A/B 探针（0.1.13 I-upload）
#
# 背景（一手证据）：正式 run 34031064018 publish 段 37m07s/178MB（~80KB/s
# 聚合），publish-release.sh UPLOAD_PAR=3 下每流 23-64KB/s——疑似单连接级
# 限流，并发提高或线性增益，但上限未知（可能为 OBS 聚合限流/跨太平洋链路）。
# 本脚本在 GitHub runner（美东→atomgit/OBS，复现发布真实链路）上以合成文件
# 对 UPLOAD_PAR ∈ {3,6,8} 各上传相同字节量，实测各并发档聚合吞吐，为
# publish-release.sh 默认并发取值提供数据定界。
#
# 安全性：专用探针 tag（v0.1.13-uploadprobe-<ts>）+ 专用 release；结束删除该
# tag（防 sync-mirror 镜像到 GitHub 触发 echo Release run）。atomgit/Gitee API
# 不支持删除 release 对象（DELETE releases/{id} 405 实证），tag 删除后其行在
# Releases 页呈 inert（无附件下载入口），可后续 UI 清理；KEEP=1 保留现场复核。
#
# 用法（GitHub runner 或具备公网+ATOMGIT_TOKEN 的机器）：
#   ATOMGIT_TOKEN=... ATOMGIT_REPO=openairymax/agentrt \
#     ./upload-speed-probe.sh [per_group_bytes_MB] [files_per_group] [par_list]
#   默认：64MB/组、4 文件、并发档 "3 6 8"。
set -euo pipefail

: "${ATOMGIT_TOKEN:?ATOMGIT_TOKEN required}"
: "${ATOMGIT_REPO:=openairymax/agentrt}"
API="https://api.atomgit.com/api/v5/repos/${ATOMGIT_REPO}"
PER_GROUP_MB="${1:-64}"
FILES_N="${2:-4}"
PAR_LIST="${3:-3 6 8}"

TS="$(date +%Y%m%d-%H%M%S)"
TAG="v0.1.13-uploadprobe-${TS}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ "${KEEP:-0}" = 1 ] || cleanup' EXIT

cleanup() {
    # tag 删除是唯一 API 可做的清理（防 GitHub echo run）；release 行 inert
    curl -s -o /dev/null -w "delete tag: HTTP %{http_code}\n" \
        -X DELETE -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        "${API}/tags/${TAG}" || true
}

echo "== 上传速度探针 == repo=${ATOMGIT_REPO} tag=${TAG} 组大小=${PER_GROUP_MB}MB×${FILES_N}/组 并发档=[${PAR_LIST}]"

# 1) 建探针 release（服务端自动补 tag + 源归档，与发布同路径）。
# body 必须非空（atomgit 实证：body 为空 → HTTP 400 "body不能为空"）。
code=$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\":\"${TAG}\",\"name\":\"${TAG} (upload probe)\",\"body\":\"upload speed probe (0.1.13 I-upload); cleans up tag on exit\",\"prerelease\":true}" \
    "${API}/releases")
echo "create release: HTTP ${code}"
[ "$code" = "201" ] || [ "$code" = "200" ] || { echo "release 创建失败"; exit 1; }

gen_file() { # $1 path  $2 size_bytes
    dd if=/dev/urandom of="$1" bs=1M count="$2" status=none
}

put_one() { # $1 file  -> rc; 打印耗时
    local f="$1" b upjson upurl rc t0 t1
    b="$(basename "$f")"
    upjson="$(curl -fsSG -H "PRIVATE-TOKEN: ${ATOMGIT_TOKEN}" \
        --data-urlencode "file_name=${b}" "${API}/releases/tags/${TAG}/upload_url" 2>/dev/null)" \
        || return 1
    upurl="$(python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get("url",""))' <<<"$upjson" 2>/dev/null)" || return 1
    [ -n "$upurl" ] || return 1
    t0="$(date +%s.%N)"
    if curl -fsS --connect-timeout 20 --max-time 1200 -X PUT --upload-file "$f" "$upurl" >/dev/null 2>&1; then
        t1="$(date +%s.%N)"
        python3 -c "print(f'${b} {float('$t1')-float('$t0'):.1f}s')"
        return 0
    fi
    return 1
}

BYTES=$((PER_GROUP_MB * 1024 * 1024))
CHUNK_MB=$((PER_GROUP_MB / FILES_N))
echo "== 合成数据（不可压缩，防服务端压缩干扰度量）=="
GROUP_FILES=()
for i in $(seq 1 "$FILES_N"); do
    f="${TMP}/data-${i}.bin"
    gen_file "$f" "$CHUNK_MB"
    GROUP_FILES+=("$f")
done
SIZE_B="$(stat -c%s "${GROUP_FILES[0]}")"
TOTAL_B=$((SIZE_B * FILES_N))

for PAR in $PAR_LIST; do
    echo "== PAR=${PAR} =="
    t0="$(date +%s.%N)"
    OK=0 FAIL=0
    pidlist=()
    i=0
    for f in "${GROUP_FILES[@]}"; do
        # 每个并发档用独立远端文件名，避免附件去重/覆盖干扰
        rname="probe-par${PAR}-$((i+1)).bin"
        cp "$f" "${TMP}/${rname}"
        ( put_one "${TMP}/${rname}" >"${TMP}/out-${PAR}-${i}.log" 2>&1 && echo OK >>"${TMP}/rc-${PAR}-${i}" || echo FAIL >>"${TMP}/rc-${PAR}-${i}" ) &
        pidlist+=($!)
        i=$((i+1))
        while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do wait -n 2>/dev/null || true; done
    done
    for p in "${pidlist[@]}"; do wait "$p" 2>/dev/null || true; done
    t1="$(date +%s.%N)"
    OK="$(cat "${TMP}"/rc-${PAR}-* 2>/dev/null | grep -c '^OK' || true)"
    FAIL="$(cat "${TMP}"/rc-${PAR}-* 2>/dev/null | grep -c '^FAIL' || true)"
    python3 - <<EOF
t0=$t0; t1=$t1; total=$TOTAL_B; ok=$OK; fail=$FAIL
dur=t1-t0
print(f"  files ok={ok} fail={fail} wall={dur:.1f}s 吞吐={total/1024/dur:.1f}KB/s")
EOF
    rm -f "${TMP}"/rc-${PAR}-* "${TMP}"/out-${PAR}-*
done

echo "== 探针完成（现场清理由 trap 执行）=="
