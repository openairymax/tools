#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 SPHARX Ltd.
# SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
# ============================================================================
# AgentRT Linux 构建依赖自编译（SSoT 唯一来源）
#
# 0.1.6e 根治修复（社区用户 Ubuntu 24.04 启动失败根因）：
#   ubuntu:20.04 的 apt 预编译 libcurl/libwebsockets 链接系统 libssl.so.1.1，
#   而 llm_d/think_d/tool_d 直接链接自编译 OpenSSL 3.0.17（libssl.so.3）——
#   同一进程加载两套 OpenSSL ABI；宿主（如 Ubuntu 24.04，仅 libssl.so.3）
#   缺 libssl.so.1.1 时 libcurl.so.4 传递依赖即崩（"cannot open shared
#   object file"）。根治：自编译 libcurl 8.5.0 + libwebsockets 4.3.3，统一
#   链接 /usr/local 的 OpenSSL 3.0.17（libssl.so.3 单一链路）。
#
# 幂等：产物已存在于 /usr/local 即跳过（断点续传/重跑安全）。
# 离线缓存优先：/deps/curl-8.5.0.tar.gz、/deps/lws-4.3.3.tar.gz、
# /deps/openssl-3.0.17.tar.gz 存在则免网络下载。
#
# 调用方（容器内执行，root）：
#   build.sh build_qemu（CONTAINER_EOF 内）
#   .github/workflows/release.yml 各 Linux 构建 job
#
# 环境：DEBIAN_FRONTEND 已设置；apt 基础依赖已装（build-essential、
# libsqlite3-dev、libyaml-dev、zlib1g-dev、libzstd-dev、libevent-dev、
# libnghttp2-dev、cmake（3.29.6 源码）、python3、rust 工具链）。
# ============================================================================
set -euo pipefail

# 内层失败自报（容器外层 ERR trap 只能看到本脚本整体退出码；此 trap 把
# 具体失败命令以 ::error:: 上报，随合并 stdout/stderr 被 GH 解析为
# annotation，匿名 API 可读）。
trap 'echo "::error::[builddeps] FAILED rc=$? cmd: ${BASH_COMMAND:-?}" >&2' ERR

# 并行度可覆盖：32 位容器（i686/armv7l）下 -j$(nproc) 大并行可能撞上
# 32 位用户态地址空间/资源限制导致 make 失败（rc=2），回退小并行。
# 调用方经 AIRY_JOBS 传入（如 release.yml qemu 矩阵 -e AIRY_JOBS=2）。
JOBS="${AIRY_JOBS:-$(nproc 2>/dev/null || echo 2)}"
export JOBS

# ── cmake ≥3.20（20.04 自带 3.16 不满足最低要求）────────────────────
# 快路径优先级：
#   ① pip wheel：amd64/aarch64/i686 有 3.29.6 wheel；armv7l 需 cmake≥3.31
#      （manylinux_2_31_armv7l），且 focal pip 20.3 不认识 2_31 tag——
#      先升级 pip 再装 3.29.6，失败则回退 3.31.6。
#   ② Kitware 官方二进制 tarball（linux-x86_64/aarch64/riscv64）。
#   ③ Kitware APT（ubuntu armhf/riscv64 等无官方 tarball 场景）。
#   ④ 源码自编译兜底（最后手段，qemu 32 位下慢且脆弱）。
cmake_ge320() {
    command -v cmake >/dev/null 2>&1 || return 1
    local ver
    ver="$(cmake --version | head -1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    [ -n "$ver" ] && [ "$(printf '%s\n3.20.0' "$ver" | sort -V | head -1)" = "3.20.0" ]
}
if ! cmake_ge320; then
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install -q -U pip >/dev/null 2>&1 || true
        pip3 install --no-cache-dir "cmake==3.29.6" >/dev/null 2>&1 || \
        pip3 install --no-cache-dir "cmake==3.31.6" >/dev/null 2>&1 || true
        hash -r
    fi
    if cmake_ge320; then
        echo "[builddeps] cmake 已由 pip wheel 安装: $(cmake --version | head -1)"
    else
        CM_PLAT=""
        case "$(uname -m)" in
            x86_64)  CM_PLAT=linux-x86_64 ;;
            aarch64) CM_PLAT=linux-aarch64 ;;
            riscv64) CM_PLAT=linux-riscv64 ;;
        esac
        if [ -n "$CM_PLAT" ] && \
           curl -fsSL --retry 2 -o /tmp/cmake-bin.tar.gz \
               "https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6-${CM_PLAT}.tar.gz" \
           && tar -xzf /tmp/cmake-bin.tar.gz -C /usr/local --strip-components=1; then
            hash -r
            echo "[builddeps] cmake 3.29.6 由 Kitware 官方二进制就位: $(cmake --version | head -1)"
        elif [ -f /etc/os-release ] && grep -q '^ID=ubuntu' /etc/os-release && \
             curl -fsSL --retry 2 https://apt.kitware.com/keys/kitware-archive-latest.asc | apt-key add - >/dev/null 2>&1 && \
             printf 'deb https://apt.kitware.com/ubuntu/ focal main\n' > /etc/apt/sources.list.d/kitware.list && \
             apt-get update -qq && apt-get install -y -qq --no-install-recommends cmake; then
            echo "[builddeps] cmake 由 Kitware APT 安装: $(cmake --version | head -1)"
        else
            echo "[builddeps] pip/二进制/APT 均不可用，自编译 cmake 3.29.6 …"
            if [ -f /deps/cmake-v3.29.6.tar.gz ]; then
                tar -xzf /deps/cmake-v3.29.6.tar.gz -C /tmp
            else
                curl -fsSL --retry 3 --retry-delay 5 -o /tmp/cmake.tar.gz \
                    https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6.tar.gz
                tar -xzf /tmp/cmake.tar.gz -C /tmp
            fi
            # Kitware 源码包顶层目录为 cmake-3.29.6（无 v 前缀；/deps 缓存
            # 文件名带 v 仅为命名习惯）。目录名错配曾致 armv7 构建在下载
            # 解包均成功后 cd 失败（0.1.11 arm32 镜像 run 33973729963 实
            # 证）。此处 fail-fast：目录缺失立即报错，不留到 bootstrap。
            [ -d /tmp/cmake-3.29.6 ] || {
                echo "::error::[builddeps] /tmp/cmake-3.29.6 不存在（下载/解包失败）" >&2
                exit 1
            }
            (cd /tmp/cmake-3.29.6 && ./bootstrap --parallel="$JOBS" --no-qt-gui --no-debugger \
                -- -DBUILD_TESTING=OFF -DBUILD_CursesDialog:BOOL=OFF \
                && make -j"$JOBS" && make install)
        fi
    fi
fi
unset -f cmake_ge320 2>/dev/null || true

# ── cJSON 1.7.18（20.04 的 1.7.10 缺 cJSON_GetNumberValue）─────────────
if [ ! -f /usr/local/lib/libcjson.so ] && [ ! -f /usr/local/lib64/libcjson.so ]; then
    echo "[builddeps] 自编译 cJSON 1.7.18 …"
    if [ -f /deps/cJSON-1.7.18.tar.gz ]; then
        cp -f /deps/cJSON-1.7.18.tar.gz /tmp/cjson.tar.gz
    else
        curl -fsSL -o /tmp/cjson.tar.gz \
            https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.18.tar.gz
    fi
    tar -xzf /tmp/cjson.tar.gz -C /tmp
    CJSON_DIR="$(ls -d /tmp/cJSON-* 2>/dev/null | head -1)"
    cmake -S "$CJSON_DIR" -B /tmp/cjson-build \
        -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=ON
    cmake --build /tmp/cjson-build --parallel "$JOBS"
    cmake --install /tmp/cjson-build
fi

# ── OpenSSL 3.0.17 自编译（libssl.so.3 基线 + lib64 残留自愈）──────────
# 历史 bug：64 位主机默认 Configure 把 libdir 解析为 lib64，而 CMake
# FindOpenSSL/pkg-config 默认不搜 /usr/local/lib64 → 错解析到系统
# 1.1.1f（不导出 EVP_DigestSignUpdate@@OPENSSL_3.0.0）→ license_sign
# 链接失败。lib64 有残留即清理重装（幂等）。
if [ ! -f /usr/local/lib/libcrypto.a ] || [ -f /usr/local/lib64/libcrypto.a ] || \
   [ -f /usr/local/lib64/libssl.so ]; then
    echo "[builddeps] 自编译 OpenSSL 3.0.17 …"
    rm -rf /usr/local/lib64/libcrypto* /usr/local/lib64/libssl* \
        /usr/local/lib64/pkgconfig/libcrypto.pc /usr/local/lib64/pkgconfig/libssl.pc \
        /usr/local/include/openssl /usr/local/ssl
    if [ -f /deps/openssl-3.0.17.tar.gz ]; then
        cp -f /deps/openssl-3.0.17.tar.gz /tmp/openssl.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/openssl.tar.gz \
            https://github.com/openssl/openssl/releases/download/openssl-3.0.17/openssl-3.0.17.tar.gz
    fi
    tar -xzf /tmp/openssl.tar.gz -C /tmp
    OPENSSL_DIR="$(ls -d /tmp/openssl-* 2>/dev/null | head -1)"
    # i686 原生容器陷阱（v0.1.9 run #8/#9 实证）：OpenSSL ./config 检测到
    # 32 位 x86 会选 linux-x86 目标并强制 -m32，而 Debian i386 镜像无
    # multilib 头文件搜索路径 → "bits/libc-header-start.h: No such file"。
    # 注意 uname -m 在 32 位容器里返回宿主内核架构（x86_64），必须用
    # gcc -dumpmachine 判定真实工具链；linux-generic32 走原生 32 位编译、
    # 不加 -m32。
    case "$(gcc -dumpmachine 2>/dev/null)" in
        i[3-6]86-*)
            (cd "$OPENSSL_DIR" && perl Configure linux-generic32 \
                --prefix=/usr/local --openssldir=/usr/local/ssl shared --libdir=lib \
                && make -j"$JOBS" build_sw && make install_sw) ;;
        arm-*)
            # armhf 32 位（原生 AArch32 compat 或 qemu-armv7）：必须显式
            # linux-armv4。./config 内部信 uname -m，而 AArch32 compat 下
            # uname 返回宿主 aarch64（内核报告硬件架构；0.1.12 build-
            # toolchain-images run #11 实证：openssl 据此选 linux-aarch64
            # 目标并启用 AArch64 汇编，armv7 汇编器报 bad instruction
            # `ldp x21,x22,[sp,#48]'）。编译器 -dumpmachine（arm-*-gnuea-
            # bihf）才是事实标准。linux-armv4 与 qemu 路径下 ./config 所
            # 选目标一致，无行为漂移。
            (cd "$OPENSSL_DIR" && perl Configure linux-armv4 \
                --prefix=/usr/local --openssldir=/usr/local/ssl shared --libdir=lib \
                && make -j"$JOBS" build_sw && make install_sw) ;;
        *)
            (cd "$OPENSSL_DIR" && ./config --prefix=/usr/local \
                --openssldir=/usr/local/ssl shared --libdir=lib \
                && make -j"$JOBS" build_sw && make install_sw) ;;
    esac
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] OpenSSL 已就位（跳过）"
fi

# ── libcurl 8.5.0 自编译（裁剪非必需依赖）──────────────────────────────
if [ ! -f /usr/local/lib/libcurl.so ]; then
    echo "[builddeps] 自编译 libcurl 8.5.0 …"
    if [ -f /deps/curl-8.5.0.tar.gz ]; then
        cp -f /deps/curl-8.5.0.tar.gz /tmp/curl.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/curl.tar.gz \
            https://github.com/curl/curl/releases/download/curl-8_5_0/curl-8.5.0.tar.gz
    fi
    tar -xzf /tmp/curl.tar.gz -C /tmp
    CURL_DIR="$(ls -d /tmp/curl-* 2>/dev/null | head -1)"
    (cd "$CURL_DIR" && ./configure --prefix=/usr/local \
        --with-openssl=/usr/local \
        --without-nghttp2 --without-nghttp3 --without-libpsl --without-libidn2 \
        --without-brotli --without-zstd --without-librtmp --without-libssh2 \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smtp --disable-gopher --disable-manual --disable-debug \
        --enable-http --enable-https --enable-ftp --enable-file --with-zlib \
        && make -j"$JOBS" && make install)
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] libcurl 已就位（跳过）"
fi

# ── curl 命令行工具防遮蔽（无条件执行，幂等）──────────────────────────
# 0.1.12 工具链镜像 arm64/arm32 实证（release #47/#48，本地镜像复现）：
#   本脚本自编译 libcurl 8.5.0 时 `make install` 连带把命令行工具装进
#   /usr/local/bin/curl（PATH 先于 apt 的 /usr/bin/curl 7.68 生效）。该
#   二进制引用 curl_easy_header（curl ≥7.83 新增符号），而 ld.so.cache
#   对同 soname 双条目（/usr/local/lib/libcurl.so.4 与系统 libcurl.so.4）
#   的取舍取决于 ld.so.conf.d 的 include 字母序：aarch64-linux-gnu.conf
#   （arm64）、arm-linux-gnueabihf.conf（armv7）按字母排在 libc.conf
#   （/usr/local/lib）之前 → 旧系统 libcurl（7.68，无 curl_easy_header）
#   先入 cache 胜出 → "curl: symbol lookup error"（exit 127）；amd64 因
#   x86_64-linux-gnu.conf 字母序在后而侥幸存活——同一雷区按架构表现
#   不同，非 flaky。
#   后果（单一根因三处受害，release #46/#47/#48 实证）：arm-32 腿
#   TUI 交叉构建硬失败（set -euo pipefail）；arm-64/riscv-64 腿 rustup
#   安装失败降级 → 发布包静默缺失 agentrt-tui。
#   修复：无条件摘除 /usr/local/bin/curl(-config)（覆盖"已就位跳过"
#   与旧镜像残留两种场景），curl 命令回退 apt 7.68 + 系统 libcurl
#   （完全自洽）；库文件不受影响（产物经 pkg-config/-L 显式链接
#   /usr/local/lib/libcurl.so.4，与命令行工具的 cache 解析序无关）。
rm -f /usr/local/bin/curl /usr/local/bin/curl-config
hash -r 2>/dev/null || true

# ── libwebsockets 4.3.3 自编译（gateway_d websocket 组件，libssl.so.3）───
if [ ! -f /usr/local/lib/libwebsockets.so ]; then
    echo "[builddeps] 自编译 libwebsockets 4.3.3 …"
    if [ -f /deps/lws-4.3.3.tar.gz ]; then
        cp -f /deps/lws-4.3.3.tar.gz /tmp/lws.tar.gz
    else
        curl -fsSL --retry 3 -o /tmp/lws.tar.gz \
            https://github.com/warmcat/libwebsockets/archive/refs/tags/v4.3.3.tar.gz
    fi
    tar -xzf /tmp/lws.tar.gz -C /tmp
    LWS_DIR="$(ls -d /tmp/libwebsockets-* 2>/dev/null | head -1)"
    # CMAKE_POLICY_VERSION_MINIMUM=3.5：lws 4.3.3 的 CMakeLists 声明
    # cmake_minimum_required < 3.5，而新版 CMake（≥3.27，pip/Kitware 供给
    # 的 3.29/3.31）已移除 <3.5 兼容并直接报错——arm-32 腿因 cmake 供给
    # 到位到新版而失败（x86-64 回退 apt 3.16 未触发，2026-09-05 run 实证）。
    # cJSON 已同款处理，此处为 SSoT 补齐。
    cmake -S "$LWS_DIR" -B /tmp/lws-build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DOPENSSL_ROOT_DIR=/usr/local \
        -DLWS_WITH_SSL=ON -DLWS_WITH_SHARED=ON -DLWS_WITH_STATIC=OFF \
        -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITHOUT_TEST_SERVER=ON \
        -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON -DLWS_WITHOUT_TEST_CLIENT=ON \
        -DLWS_WITH_HTTP2=OFF -DLWS_WITH_MINIMAL_EXAMPLES=OFF
    cmake --build /tmp/lws-build --parallel "$JOBS"
    cmake --install /tmp/lws-build
    ldconfig 2>/dev/null || true
else
    echo "[builddeps] libwebsockets 已就位（跳过）"
fi

# 统一 pkg-config 解析到自编译库（后续 configure/cmake 依赖此环境）
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
echo "[builddeps] 完成：OpenSSL 3.0.17 + libcurl 8.5.0 + libwebsockets 4.3.3"

# ── 出口门：curl 命令行工具必须可用（fail-fast）───────────────────────
# 在镜像构建期即拦截 curl 断链，避免坏镜像发布到 GHCR 后才在 release
# 各腿炸出（arm-32 硬失败 / arm-64+riscv TUI 静默缺失，release
# #46/#47/#48 实证）。lws 段的下载 curl 在此之前必须已可用。
if ! curl --version >/dev/null 2>&1; then
    echo "::error::[builddeps] 出口门失败：curl 命令行工具不可用（command -v curl=$(command -v curl 2>/dev/null || echo none)）" >&2
    exit 1
fi
echo "[builddeps] 出口门通过：$(curl --version | head -1)"
