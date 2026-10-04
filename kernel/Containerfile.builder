# Build environment for build.sh, mirroring Kata's kernel builder
# (tools/packaging/static-build/kernel/Dockerfile) without yq.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates curl debhelper flex git \
      iptables kmod libdw-dev libelf-dev libssl-dev gettext rsync cpio patch \
      python3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
