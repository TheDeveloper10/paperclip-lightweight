# paperclip-lightweight

A single `Dockerfile` that takes the official Paperclip image
(`ghcr.io/paperclipai/paperclip`) and slims it down to the two agent harnesses
actually in use, then adds Go, Podman and Deno on top.

Nothing here is built or run automatically. This repo is just the recipe.

## What changes versus upstream

| Area | Upstream image | This image |
| --- | --- | --- |
| AI CLIs | Claude Code, Codex, OpenCode, Gemini CLI, Kimi Code | **Claude Code, OpenCode** only |
| System packages | ca-certificates, gosu, curl, gh, git, wget, ripgrep, python3, tini, openssh-client, jq | python3 and wget removed; rest kept |
| Added toolchains | none | Go, Podman (+ crun, fuse-overlayfs, uidmap, pasta), Deno |
| Docs / man pages / apt lists / npm caches / source maps in node_modules | present | removed |
| Entrypoint, CMD, port, user, `/paperclip` home | tini + `docker-entrypoint.sh`, port 3100, user `node` | **unchanged** |

The Paperclip server, its built UI and the Rust runner are left untouched.
Only things around them are cut.

## Build

```bash
docker build -t paperclip-lightweight .
```

Build arguments (all optional):

| Arg | Default | Purpose |
| --- | --- | --- |
| `PAPERCLIP_TAG` | `latest` | Upstream tag to start from. Pin a release, e.g. `2026.1012.0`, for reproducible builds. |
| `GO_VERSION` | `1.26.1` | Go release pulled from go.dev. |
| `DENO_VERSION` | `latest` | Deno release from GitHub. Set to a bare version like `2.5.0` to pin. |
| `USER_NAME` | `node` | Service user that gets subuid/subgid ranges for rootless Podman. Matches upstream. |

Example with pins:

```bash
docker build \
  --build-arg PAPERCLIP_TAG=2026.1012.0 \
  --build-arg GO_VERSION=1.26.1 \
  --build-arg DENO_VERSION=2.5.0 \
  -t paperclip-lightweight .
```

Multi-arch works the same way as upstream (`amd64` and `arm64`), because the
Go and Deno download steps key off `TARGETARCH`.

## Run

Plain Paperclip, same as upstream:

```bash
docker run -d --name paperclip \
  -p 3100:3100 \
  -v paperclip-home:/paperclip \
  paperclip-lightweight
```

If agents inside the container need to use Podman, the outer container has to
allow nested user namespaces and FUSE. The simplest form:

```bash
docker run -d --name paperclip \
  --privileged \
  -p 3100:3100 \
  -v paperclip-home:/paperclip \
  -v paperclip-containers:/var/lib/containers \
  paperclip-lightweight
```

A less broad alternative that usually works on a modern kernel:

```bash
docker run -d --name paperclip \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --security-opt label=disable \
  --device /dev/fuse \
  --cap-add SYS_ADMIN --cap-add MKNOD --cap-add SETUID --cap-add SETGID \
  -p 3100:3100 \
  -v paperclip-home:/paperclip \
  -v paperclip-containers:/var/lib/containers \
  paperclip-lightweight
```

Podman is configured for `cgroupfs`, `crun`, `fuse-overlayfs` storage and
`pasta` networking, which is the standard combination for running Podman
inside another container. Rootless storage for the `node` user lives under
`/paperclip/.local/share/containers`, so it persists with the Paperclip home
volume.

## Where tools live

| Tool | Binary | Caches / state (all under the `/paperclip` volume) |
| --- | --- | --- |
| Claude Code | `claude` | `/paperclip/.claude` |
| OpenCode | `opencode` | `/paperclip/.config/opencode`, `/paperclip/.local/share/opencode` |
| Go | `/usr/local/go/bin/go` | `GOPATH=/paperclip/go`, `GOCACHE=/paperclip/.cache/go-build` |
| Deno | `/usr/local/bin/deno` | `DENO_DIR=/paperclip/.cache/deno`, installs to `/paperclip/.deno/bin` |
| Podman | `podman` | `/paperclip/.local/share/containers` (rootless), `/var/lib/containers` (root) |

`GOTOOLCHAIN=local` is set so Go never silently downloads a different
toolchain at build time. Override it in the environment if you want that
behaviour back.

## Verifying the image

After a build, these should all succeed:

```bash
docker run --rm paperclip-lightweight claude --version
docker run --rm paperclip-lightweight opencode --version
docker run --rm paperclip-lightweight go version
docker run --rm paperclip-lightweight deno --version
docker run --rm paperclip-lightweight podman --version
docker run --rm paperclip-lightweight sh -c '! command -v codex && ! command -v gemini && ! command -v python3'
```

## Notes and caveats

- The upstream image tag list is not documented in the repo. `latest` is
  assumed to exist. If the pull fails, pin `PAPERCLIP_TAG` to a release or to
  `sha-<commit>`, which upstream CI publishes on every master push.
- `python3` is purged. If a future upstream entrypoint or a tool you add
  needs it, remove that line from the `apt-get purge` step.
- The uninstall step for Codex, Gemini and Kimi is tolerant: if upstream
  renames or drops a package, the build still succeeds.
- Rootless Podman inside Docker depends on the host kernel allowing
  unprivileged user namespaces (`sysctl kernel.unprivileged_userns_clone=1`
  on some distros, and `user.max_user_namespaces` above zero).
