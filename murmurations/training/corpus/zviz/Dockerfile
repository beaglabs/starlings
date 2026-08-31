FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_VERSION=0.16.0

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
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/work
