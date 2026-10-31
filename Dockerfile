# syntax=docker/dockerfile:1

ARG BUN_VERSION=1.4.2
ARG HERDR_WEB_UI_VERSION=0.4.11
ARG HERDR_WEB_UI_COMMIT=6de77101b2fafda044054e8f7195f3573b624b72

FROM ghcr.io/astral-sh/uv:0.13.1 AS uv

FROM oven/bun:${BUN_VERSION} AS bun

# herdr-web-ui, built from a pinned tag whose commit is checked, with every dependency from its lockfile.
FROM oven/bun:${BUN_VERSION} AS web-ui

ARG HERDR_WEB_UI_VERSION
ARG HERDR_WEB_UI_COMMIT

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

WORKDIR /opt/herdr-web-ui
RUN set -eux; \
  git clone --quiet --depth 1 --branch "v${HERDR_WEB_UI_VERSION}" https://github.com/devswha/herdr-web-ui.git .; \
  test "$(git rev-parse HEAD)" = "${HERDR_WEB_UI_COMMIT}"; \
  rm -rf .git
# The build needs the dev dependencies (Vite); the server runs on the production ones alone.
RUN set -eux; \
  bun install --frozen-lockfile; \
  bun run build; \
  rm -rf node_modules; \
  bun install --frozen-lockfile --production; \
  rm -rf /root/.bun/install/cache

FROM node:24-trixie-slim

ARG USER_UID=1000
ARG USER_GID=1000
ARG BITBANG_VERSION=0.5.1
ARG CLAUDE_CODE_VERSION=2.1.302
ARG CODEX_VERSION=0.163.0
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256_AMD64=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
ARG HERDR_SHA256_ARM64=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c
ARG CURSOR_AGENT_VERSION=2026.10.16-e3cb207
ARG CURSOR_AGENT_SHA256_AMD64=3aa3f48cd7a3909a98c9b3f2a4085f0c021088bf826690b22c61f424c843e552
ARG CURSOR_AGENT_SHA256_ARM64=4cf077f150eb8d1e270bf1dea69700184c39a4847fe192d523f5bb34d4b62597
ARG DPRINT_VERSION=0.63.0
ARG SHFMT_VERSION=3.14.1
ARG SHFMT_SHA256_AMD64=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
ARG SHFMT_SHA256_ARM64=5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489
ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256_AMD64=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
ARG SHELLCHECK_SHA256_ARM64=68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc
ARG MBAKE_VERSION=1.4.6
ARG BUN_VERSION
ARG HERDR_WEB_UI_VERSION
ARG TARGETARCH

# Claude Code and Bun send no usage data, error or crash reports, or surveys, and Claude Code never updates itself.
ENV LANG=C.UTF-8 \
    TERM=xterm-256color \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    DO_NOT_TRACK=1 \
    HERDR_CONFIG_PATH=/usr/local/share/go-remote/herdr.toml

# Corporate TLS-inspection roots (exported into certs/ by `make build`) must be trusted before any HTTPS fetch.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN set -eux; \
  install -d -m 0755 /etc/apt/keyrings; \
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
  chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  gh git jq less make procps python3 ripgrep tmux unzip vim-tiny; \
  rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

RUN npm install -g --omit=dev "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
  && npm cache clean --force

RUN set -eux; \
  base="https://github.com/richlegrand/bitbang-cli/releases/download/${BITBANG_VERSION}"; \
  asset="bitbang-linux-${TARGETARCH}"; \
  cd /tmp; \
  curl -fsSLO "${base}/${asset}"; \
  curl -fsSLO "${base}/checksums.txt"; \
  grep " ${asset}\$" checksums.txt | sha256sum -c -; \
  install -m 0755 "${asset}" /usr/local/bin/bitbang; \
  rm -f "${asset}" checksums.txt

# Herdr publishes no checksum file, so the digests GitHub reports for the release assets are pinned here.
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) asset=herdr-linux-x86_64; sha256="${HERDR_SHA256_AMD64}" ;; \
  arm64) asset=herdr-linux-aarch64; sha256="${HERDR_SHA256_ARM64}" ;; \
  *) echo "Herdr has no Linux build for ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/herdr "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${asset}"; \
  echo "${sha256}  /tmp/herdr" | sha256sum -c -; \
  install -m 0755 /tmp/herdr /usr/local/bin/herdr; \
  rm -f /tmp/herdr

# The official Cursor Agent CLI release is a platform archive. Verify its pinned digest before unpacking it;
# Herdr invokes it as `cursor-agent` for `herdr agent start --kind cursor`.
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) arch=x64; sha256="${CURSOR_AGENT_SHA256_AMD64}" ;; \
  arm64) arch=arm64; sha256="${CURSOR_AGENT_SHA256_ARM64}" ;; \
  *) echo "Cursor Agent has no Linux build for ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/cursor-agent.tar.gz \
    "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${arch}/agent-cli-package.tar.gz"; \
  echo "${sha256}  /tmp/cursor-agent.tar.gz" | sha256sum -c -; \
  tar -xzf /tmp/cursor-agent.tar.gz -C /opt; \
  mv /opt/dist-package /opt/cursor-agent; \
  ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/cursor-agent; \
  ln -s cursor-agent /usr/local/bin/agent; \
  rm -f /tmp/cursor-agent.tar.gz

# The formatters and linters `make lint` runs, so an agent can check its work before it commits. dprint fetches the
# plugins a repo's dprint.json pins on first use, into the home volume.
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) asset=dprint-x86_64-unknown-linux-gnu.zip ;; \
  arm64) asset=dprint-aarch64-unknown-linux-gnu.zip ;; \
  *) echo "dprint has no Linux build for ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  base="https://github.com/dprint/dprint/releases/download/${DPRINT_VERSION}"; \
  cd /tmp; \
  curl -fsSLO "${base}/${asset}"; \
  curl -fsSLO "${base}/SHASUMS256.txt"; \
  grep " ${asset}\$" SHASUMS256.txt | sha256sum -c -; \
  unzip -q "${asset}" dprint; \
  install -m 0755 dprint /usr/local/bin/dprint; \
  rm -f "${asset}" SHASUMS256.txt dprint

# shfmt and ShellCheck publish no checksum file, so the digests GitHub reports for the release assets are pinned here.
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) arch=x86_64; shfmt_sha256="${SHFMT_SHA256_AMD64}"; shellcheck_sha256="${SHELLCHECK_SHA256_AMD64}" ;; \
  arm64) arch=aarch64; shfmt_sha256="${SHFMT_SHA256_ARM64}"; shellcheck_sha256="${SHELLCHECK_SHA256_ARM64}" ;; \
  *) echo "shfmt and ShellCheck have no Linux build for ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/shfmt \
    "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${TARGETARCH}"; \
  echo "${shfmt_sha256}  /tmp/shfmt" | sha256sum -c -; \
  install -m 0755 /tmp/shfmt /usr/local/bin/shfmt; \
  curl -fsSL -o /tmp/shellcheck.tar.gz \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${arch}.tar.gz"; \
  echo "${shellcheck_sha256}  /tmp/shellcheck.tar.gz" | sha256sum -c -; \
  tar -xzf /tmp/shellcheck.tar.gz -C /tmp; \
  install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
  rm -rf /tmp/shfmt /tmp/shellcheck.tar.gz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"

# mbake and every package it needs come from PyPI pinned with hashes, into their own environment. mbake looks for a
# newer release only for `--version` and `mbake update`, and cannot update itself on the read-only filesystem.
COPY docker/mbake-requirements.txt /tmp/mbake-requirements.txt
RUN set -eux; \
  grep -q "^mbake==${MBAKE_VERSION} " /tmp/mbake-requirements.txt; \
  UV_PYTHON_DOWNLOADS=never uv venv --quiet --python /usr/bin/python3 /opt/mbake; \
  UV_CACHE_DIR=/tmp/uv-cache uv pip install --quiet --python /opt/mbake/bin/python --require-hashes \
    -r /tmp/mbake-requirements.txt; \
  ln -s /opt/mbake/bin/mbake /usr/local/bin/mbake; \
  rm -rf /tmp/uv-cache /tmp/mbake-requirements.txt

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=web-ui /opt/herdr-web-ui /opt/herdr-web-ui

# The stock node user would hold UID 1000; replace it with agent at the host's UID/GID.
# /workspace points at the repo's host path, which the entrypoint links into tmpfs at start.
RUN set -eux; \
  userdel -r node; \
  getent group "${USER_GID}" >/dev/null || groupadd -g "${USER_GID}" agent; \
  useradd -l -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash agent; \
  ln -s /tmp/go-remote/workspace /workspace

COPY VERSION /usr/local/share/go-remote/VERSION
COPY third_party/ /usr/local/share/doc/go-remote/third_party/
COPY scripts/log.bash /usr/local/lib/go-remote/log.bash
COPY ingress/server.ts ingress/rewrite.ts ingress/compat.js ingress/alerts.ts /opt/go-remote/ingress/
COPY docker/herdr.toml /usr/local/share/go-remote/herdr.toml
COPY docker/codex.toml /etc/codex/config.toml
COPY docker/tmux.conf /etc/tmux.conf
COPY docker/entrypoint.bash /usr/local/bin/go-remote-entrypoint
COPY docker/session.bash /usr/local/bin/go-remote-session
COPY docker/herdr.bash /usr/local/bin/go-remote-herdr
COPY docker/attach.bash /usr/local/bin/go-remote-attach
COPY docker/pair.bash /usr/local/bin/go-remote-pair
COPY docker/agent.bash /usr/local/bin/go-remote-agent
COPY docker/bashrc /usr/local/share/go-remote/bashrc
RUN printf '\n. /usr/local/share/go-remote/bashrc\n' >>/etc/bash.bashrc

# Read by go-remote doctor and the session handoff, which warn when the laptop's agent CLIs differ.
LABEL go-remote.version.bitbang="${BITBANG_VERSION}" \
      go-remote.version.bun="${BUN_VERSION}" \
      go-remote.version.claude-code="${CLAUDE_CODE_VERSION}" \
      go-remote.version.codex="${CODEX_VERSION}" \
      go-remote.version.cursor-agent="${CURSOR_AGENT_VERSION}" \
      go-remote.version.dprint="${DPRINT_VERSION}" \
      go-remote.version.herdr="${HERDR_VERSION}" \
      go-remote.version.herdr-web-ui="${HERDR_WEB_UI_VERSION}" \
      go-remote.version.mbake="${MBAKE_VERSION}" \
      go-remote.version.shellcheck="${SHELLCHECK_VERSION}" \
      go-remote.version.shfmt="${SHFMT_VERSION}"

USER agent
WORKDIR /home/agent
ENTRYPOINT ["go-remote-entrypoint"]
