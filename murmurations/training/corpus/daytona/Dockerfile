FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_VERSION=0.15.0

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
        ninja-build \
        nodejs \
        npm \
        openjdk-21-jdk-headless \
        pkg-config \
        python3 \
        python3-pip \
        python3-pytest \
        python3-venv \
        rustc \
        xz-utils \
    && python3 -m pip install --break-system-packages --no-cache-dir "pip>=25.1,<27" \
    && npm install -g pnpm@10.34.5 \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) zig_arch="x86_64" ;; \
         arm64) zig_arch="aarch64" ;; \
         *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt \
    && ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["/bin/bash"]
