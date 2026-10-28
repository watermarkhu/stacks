# openchamber-devbox

A long-lived dev container for the home server. It runs [OpenChamber](https://openchamber.dev), the web UI for the [OpenCode](https://opencode.ai) agent. Its toolchain is declared in `mise.toml`, and VS Code can attach to it as a devcontainer.

- Reachable over the LAN/VPN only: via Traefik at `https://openchamber.local.watermarkhu.nl`, or directly on `BIND_ADDR:HOST_PORT`.
- Tools, OpenCode logins and sessions, SSH keys and dotfiles live in the `home` volume. They survive restarts and image rebuilds.
- Projects live in `WORKSPACE_DIR` on the host, mounted at `/workspace`, and are owned by your host user.

## Layout

| Path | Purpose |
| --- | --- |
| `Dockerfile` | `debian:trixie-slim` with OS packages, system-wide mise and the `dev` user (UID/GID from build args) |
| `entrypoint.sh` | Sets git identity, runs `mise install`, then starts OpenChamber (or `exec`s the given command) |
| `mise.toml` | The toolchain. Mounted as `/etc/mise/config.toml` |
| `compose.yaml` | Stack `openchamber`, service `devbox`. Traefik labels, `home` volume, workspace bind mount |
| `.env.example` | Template for `.env`, which holds the password, bind address, UID/GID and git identity |
| `.devcontainer/devcontainer.json` | Lets VS Code attach to the running service without ever stopping it |
| `workspace/` | Default `WORKSPACE_DIR` (git-ignored). On the server, `.env` points elsewhere |

Renovate is configured in the repository's root `renovate.json5`.

## First run

```sh
cd openchamber-devbox
cp .env.example .env
$EDITOR .env                 # OPENCHAMBER_UI_PASSWORD, UID/GID (id -u / id -g), WORKSPACE_DIR, git identity
mkdir -p workspace           # or the WORKSPACE_DIR you set, owned by your user
docker compose up -d --build
docker compose logs -f       # first start installs the toolchain (a minute or two)
```

The container is `healthy` once OpenChamber answers on port 3000. If `OPENCHAMBER_UI_PASSWORD` is missing, the container exits with an error rather than serving an unprotected UI.

The stack joins the external `proxy` network like the other stacks, so Traefik serves it at `https://openchamber.local.watermarkhu.nl`. It needs no host port for that. For direct VPN access, set `BIND_ADDR` to the server's Tailscale IP (`tailscale ip -4`). Ports 3000 and 3001 are taken by ha-wa-bridge and Dockhand, so `HOST_PORT` defaults to 3002.

Traefik needs no special configuration: it proxies WebSockets and streams SSE unbuffered by default.

### Dockhand

Dockhand runs `docker compose` inside its own container. Relative bind mounts (`./mise.toml`, `./workspace`) then rely on Dockhand's host-path translation. To match the other stacks, set an absolute `WORKSPACE_DIR` under `/mnt/NVME/docker/...`. If `./mise.toml` ever shows up as an empty directory inside the container, the path was not translated. In that case, replace the mount source with the absolute host path of this directory.

## Git access

Generate a dedicated key inside the container. It lives in the `home` volume, so you only need to do this once:

```sh
docker compose exec devbox ssh-keygen -t ed25519 -C "openchamber-devbox" -f /home/dev/.ssh/id_ed25519 -N ""
docker compose exec devbox cat /home/dev/.ssh/id_ed25519.pub
```

Add the public key to GitHub, either as an account SSH key or, to limit it to one repository, as a deploy key. Then:

```sh
docker compose exec devbox ssh -T git@github.com
docker compose exec devbox git clone git@github.com:you/project.git /workspace/project
```

For the GitHub CLI (PRs, issues), log in once. The token is stored in `~/.config/gh` in the `home` volume:

```sh
docker compose exec -it devbox gh auth login
```

The entrypoint writes `GIT_USER_NAME` and `GIT_USER_EMAIL` to the global git config. It also marks `/workspace/*` as a `safe.directory`.

## Day to day

```sh
docker compose exec devbox bash             # shell as dev (mise activated)
docker compose exec devbox opencode auth login
docker compose run --rm devbox bash         # one-off container with the same volumes
docker compose logs -f devbox
docker compose restart devbox
docker compose ps                           # health status
```

VS Code: open this directory and run **Dev Containers: Reopen in Container**, or use Remote-SSH to the server first. VS Code attaches to the running `devbox` service and never stops it (`shutdownAction: none`).

## Updating

- **Add or change a tool:** edit `mise.toml`, then `docker compose restart devbox`. The file is bind-mounted, so no rebuild is needed, and the entrypoint installs whatever is missing.
- **Newer tool versions:** run `docker compose exec devbox mise outdated --bump` to see what is available, then put those versions in `mise.toml` and restart. Usually you just merge the Renovate PR. Versions are pinned, so `mise upgrade` alone does nothing. The config is mounted read-only, so `mise upgrade --bump` can't write it from inside the container.
- **npm tools with install scripts:** mise's npm backend skips dependency scripts unless they are listed in `allow_builds`. `@opencode/cli` needs its own scripts, and `@openchamber/web` needs `node-pty`'s. After changing `allow_builds` on a version that is already installed, run `docker compose exec devbox mise install -f <tool>`.
- **Base image and OS packages:** `docker compose build --pull && docker compose up -d`.
- **Clean slate:** `docker compose down && docker volume rm openchamber_home && docker compose up -d --build`.
  > **Warning:** this wipes OpenCode/provider logins, OpenCode sessions, OpenChamber settings, the SSH key and all dotfiles. Projects in `WORKSPACE_DIR` are not touched.

## Renovate

The root `renovate.json5` covers this directory:

- **`dockerfile`** manager: updates the `debian:trixie-slim` digest. Patch and digest updates automerge, as they do for the compose stacks.
- **`mise`** manager: bumps the pinned versions in `mise.toml`. It only handles exact versions, which is why nothing says `latest`/`lts`. Tool updates are grouped into a single "openchamber devbox toolchain" PR. Node majors get their own PR, labelled `major-update`. `@openchamber/web` needs node >= 24.14.
- **Regex custom manager**: bumps `ARG MISE_VERSION` in the Dockerfile via its `# renovate:` comment.

Toolchain PRs take effect on the next `docker compose restart devbox` after Dockhand pulls the change. Dockerfile PRs need a rebuild.

## Security notes

- `dev` has passwordless `sudo` inside the container, so the agent can `apt-get install` things. Treat the container as fully controlled by the agent. To remove sudo, delete the marked line in the `Dockerfile` and rebuild.
- **Never mount the Docker socket** into this container. That would give the agent root on the host.
- Keep the UI off the public internet. Use Traefik on the `*.local` domain, `127.0.0.1` or the Tailscale IP, and never bind to `0.0.0.0` or add a public route or tunnel. The UI password is the only lock on a shell that holds your provider credentials.
- Provider keys in `.env` are visible to every process in the container, including the agent. Prefer `opencode auth login` with scoped keys.
