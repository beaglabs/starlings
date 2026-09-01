FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_DEFAULT_VERSION=0.16.0
ARG ZIG_ZLS_VERSION=0.17.0-dev.292+fc1c83a36
ARG ZIG_CLAP_VERSION=0.17.0-dev.813+2153f8143

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cargo \
        cmake \
        curl \
        git \
        golang-go \
        maven \
        meson \
        minisign \
        ninja-build \
        nodejs \
        npm \
        openjdk-21-jdk-headless \
        pkg-config \
        python3 \
        python3-pip \
        python3-pytest \
        python3-venv \
        redis-server \
        rustc \
        xz-utils \
    && python3 -m pip install --break-system-packages --no-cache-dir "pip>=25.1,<27" \
    && npm install -g pnpm@10.34.5 \
    && node -e "const [a,b]=process.versions.node.split('.').map(Number); if (a < 22 || (a === 22 && b < 12)) process.exit(1)" \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) zig_arch="x86_64" ;; \
         arm64) zig_arch="aarch64" ;; \
         *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
       esac \
    && { \
         zig_pubkey="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"; \
         install_zig() { \
           version="$1"; channel="$2"; \
           filename="zig-${zig_arch}-linux-$version.tar.xz"; \
           archive="/tmp/$filename"; \
           signature="$archive.minisig"; \
           mkdir -p "/opt/zig/$version"; \
           if [ "$channel" = stable ]; then \
             primary="https://ziglang.org/download/$version/$filename"; \
           else \
             primary="https://ziglang.org/builds/$filename"; \
           fi; \
           mirror="http://mirrors.nektro.net/zig/$version/$filename"; \
           if ! { \
             curl -fsSL --retry 3 -o "$archive" "$primary" \
               && curl -fsSL --retry 3 -o "$signature" "$primary.minisig"; \
           }; then \
             rm -f "$archive" "$signature"; \
             curl -fsSL --retry 3 -o "$archive" "$mirror"; \
             curl -fsSL --retry 3 -o "$signature" "$mirror.minisig"; \
           fi; \
           minisign -Vm "$archive" -P "$zig_pubkey"; \
           tar -xJf "$archive" --strip-components=1 -C "/opt/zig/$version"; \
           rm -f "$archive" "$signature"; \
         }; \
         install_zig "$ZIG_DEFAULT_VERSION" stable; \
         install_zig "$ZIG_ZLS_VERSION" builds; \
         install_zig "$ZIG_CLAP_VERSION" builds; \
       } \
    && ln -s "/opt/zig/${ZIG_DEFAULT_VERSION}/zig" /usr/local/bin/zig \
    && /opt/zig/${ZIG_DEFAULT_VERSION}/zig version \
    && /opt/zig/${ZIG_ZLS_VERSION}/zig version \
    && /opt/zig/${ZIG_CLAP_VERSION}/zig version \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["/bin/bash"]
