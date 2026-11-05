# syntax=docker/dockerfile:1.7
#
# paperclip-lightweight
#
# Starts from the official Paperclip image (which bundles the Node server, the
# Rust runner, and five AI CLIs) and:
#   1. strips everything except the Claude Code and OpenCode harnesses,
#   2. drops packages the server does not need at runtime,
#   3. adds Go, Podman (rootless-capable) and Deno,
#   4. scrubs caches, docs, man pages and apt lists.
#
# The upstream ENTRYPOINT (tini + docker-entrypoint.sh), CMD, user, volume
# layout (/paperclip) and port (3100) are inherited unchanged.

ARG PAPERCLIP_TAG=latest
FROM ghcr.io/paperclipai/paperclip:${PAPERCLIP_TAG}

ARG TARGETARCH
ARG GO_VERSION=1.26.1
ARG DENO_VERSION=latest
ARG USER_NAME=node

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. Strip the AI harnesses we do not use. Only claude + opencode survive.
# ---------------------------------------------------------------------------
RUN <<'EOF'
set -eux
for pkg in @openai/codex @google/gemini-cli @moonshot-ai/kimi-code; do
  npm uninstall --global "$pkg" || true
done
# Belt and braces: remove any leftover binaries/symlinks.
rm -f /usr/local/bin/codex /usr/local/bin/gemini /usr/local/bin/kimi
rm -rf /usr/local/lib/node_modules/@openai \
       /usr/local/lib/node_modules/@google \
       /usr/local/lib/node_modules/@moonshot-ai
npm cache clean --force
EOF

# ---------------------------------------------------------------------------
# 2. Remove runtime fat, then install Podman + helpers in the same layer.
#    Kept on purpose: tini, gosu (entrypoint), ca-certificates, curl, git, gh,
#    ripgrep, jq, openssh-client (agents use these constantly).
#    Dropped: python3 (nothing left needs it), wget (curl covers it).
# ---------------------------------------------------------------------------
RUN <<'EOF'
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get purge -y --auto-remove python3 wget || true
apt-get install -y --no-install-recommends \
    podman \
    crun \
    uidmap \
    fuse-overlayfs \
    passt \
    unzip
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*
EOF

# ---------------------------------------------------------------------------
# 3. Podman: rootless-friendly config for running inside a container.
# ---------------------------------------------------------------------------
RUN <<'EOF'
set -eux
# Sub-UID/GID ranges so the unprivileged service user can run rootless podman.
grep -q "^${USER_NAME}:" /etc/subuid || echo "${USER_NAME}:100000:65536" >> /etc/subuid
grep -q "^${USER_NAME}:" /etc/subgid || echo "${USER_NAME}:100000:65536" >> /etc/subgid

mkdir -p /etc/containers /var/lib/containers /paperclip/.local/share/containers /paperclip/.config/containers

cat > /etc/containers/containers.conf <<'CONF'
[containers]
log_driver = "k8s-file"

[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
runtime = "crun"

[network]
default_rootless_network_cmd = "pasta"
CONF

cat > /etc/containers/storage.conf <<'CONF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
CONF

cat > /etc/containers/registries.conf <<'CONF'
unqualified-search-registries = ["docker.io"]
CONF

# Silence the "emulating docker" banner if someone symlinks docker -> podman.
touch /etc/containers/nodocker

chown -R "${USER_NAME}:${USER_NAME}" /paperclip/.local /paperclip/.config
chmod 755 /var/lib/containers
EOF

# ---------------------------------------------------------------------------
# 4. Go (official tarball, arch-aware).
# ---------------------------------------------------------------------------
ENV GOROOT=/usr/local/go \
    GOPATH=/paperclip/go \
    GOCACHE=/paperclip/.cache/go-build \
    GOMODCACHE=/paperclip/go/pkg/mod \
    GOTOOLCHAIN=local \
    PATH=/usr/local/go/bin:/paperclip/go/bin:${PATH}

RUN <<'EOF'
set -eux
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz
# Trim pieces nobody needs in a runtime image.
rm -rf /usr/local/go/test /usr/local/go/doc /usr/local/go/misc /usr/local/go/api
mkdir -p "${GOPATH}/bin" "${GOCACHE}" "${GOMODCACHE}"
chown -R "${USER_NAME}:${USER_NAME}" /paperclip/go /paperclip/.cache
/usr/local/go/bin/go version
EOF

# ---------------------------------------------------------------------------
# 5. Deno (TypeScript runtime), from GitHub releases, arch-aware.
# ---------------------------------------------------------------------------
ENV DENO_INSTALL_ROOT=/paperclip/.deno \
    DENO_DIR=/paperclip/.cache/deno \
    DENO_NO_UPDATE_CHECK=1 \
    PATH=/paperclip/.deno/bin:${PATH}

RUN <<'EOF'
set -eux
case "${TARGETARCH}" in
  amd64) triple="x86_64-unknown-linux-gnu" ;;
  arm64) triple="aarch64-unknown-linux-gnu" ;;
  *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
esac
if [ "${DENO_VERSION}" = "latest" ]; then
  url="https://github.com/denoland/deno/releases/latest/download/deno-${triple}.zip"
else
  url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${triple}.zip"
fi
curl -fsSL "$url" -o /tmp/deno.zip
unzip -q -o /tmp/deno.zip -d /usr/local/bin
chmod +x /usr/local/bin/deno
rm -f /tmp/deno.zip
mkdir -p "${DENO_INSTALL_ROOT}/bin" "${DENO_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" /paperclip/.deno /paperclip/.cache
deno --version
EOF

# ---------------------------------------------------------------------------
# 6. Final scrub: docs, man pages, caches, temp files. unzip was only needed
#    for the Deno step.
# ---------------------------------------------------------------------------
RUN <<'EOF'
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y --auto-remove unzip || true
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/* \
       /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
       /usr/share/lintian /usr/share/linda \
       /root/.npm /root/.cache /paperclip/.npm/_cacache \
       /tmp/* /var/tmp/*
find / -xdev \( -name "*.md" -path "*/node_modules/*" -o -name "*.map" -path "*/node_modules/*" \) -type f -delete 2>/dev/null || true
# Sanity check: the two harnesses we care about are still here.
command -v claude
command -v opencode
command -v podman
command -v go
command -v deno
EOF

# Persist podman storage along with the Paperclip home.
VOLUME ["/paperclip", "/var/lib/containers"]

# ENTRYPOINT, CMD, EXPOSE 3100 and the node user are inherited from upstream.
