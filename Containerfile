# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        gh \
        git \
        jq \
        openssh-client \
        python3 \
    && rm -rf /var/lib/apt/lists/*

COPY NONO_VERSION PI_VERSION /tmp/versions/

RUN set -eu; \
    nono_version="$(tr -d '\n' < /tmp/versions/NONO_VERSION)"; \
    architecture="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$architecture" in \
      amd64) nono_target=x86_64-unknown-linux-gnu ;; \
      arm64) nono_target=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture: $architecture" >&2; exit 1 ;; \
    esac; \
    asset="nono-v${nono_version}-${nono_target}.tar.gz"; \
    release="https://github.com/nolabs-ai/nono/releases/download/v${nono_version}"; \
    work="$(mktemp -d)"; \
    curl -fsSL "$release/$asset" -o "$work/$asset"; \
    curl -fsSL "$release/SHA256SUMS.txt" -o "$work/SHA256SUMS.txt"; \
    cd "$work"; \
    grep "  $asset$" SHA256SUMS.txt | sha256sum -c -; \
    tar -xzf "$asset"; \
    install -m 0755 nono /usr/local/bin/nono; \
    rm -rf "$work"

RUN set -eu; \
    pi_version="$(tr -d '\n' < /tmp/versions/PI_VERSION)"; \
    npm install --global --ignore-scripts \
      "@earendil-works/pi-coding-agent@${pi_version}"; \
    pi --version; \
    npm cache clean --force; \
    rm -rf /tmp/versions

RUN install -d -o node -g node /demo /workspace /home/node/.local/state/nono \
    && install -d -m 0755 /etc/nono

COPY config/github_known_hosts /etc/nono/github_known_hosts
COPY --chown=node:node bin /demo/bin
COPY --chown=node:node demo_app /demo/demo_app
COPY --chown=node:node profiles /demo/profiles
COPY --chown=node:node prompts /demo/prompts
COPY --chown=node:node scenario /demo/scenario

RUN chmod 0444 /etc/nono/github_known_hosts \
    && find /demo/bin -type f ! -name .gitkeep -exec chmod 0755 {} +

ENV HOME=/home/node

USER node
WORKDIR /workspace

CMD ["pi", "--version"]
