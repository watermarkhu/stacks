# openchamber-devbox

A long-lived dev container for the home server. It runs [OpenChamber](https://openchamber.dev), the web UI for the [OpenCode](https://opencode.ai) agent, and code-server for browser-based editing. Its toolchain is declared in `mise.toml`, and VS Code can attach to it as a devcontainer.

- Reachable over the LAN/VPN only: via Traefik at `https://openchamber.local.watermarkhu.nl`, or directly on `BIND_ADDR:HOST_PORT`.
- code-server is available at `https://code.local.watermarkhu.nl` and shares the devbox home/workspace dataset.
- The `home` volume is backed by `WORKSPACE_DIR` and mounted at both `/home/dev` and `/workspace` in the devbox and code-server. Tools, OpenCode logins/sessions, SSH keys, dotfiles and projects all persist on that external dataset.

## Layout

| Path | Purpose |
| --- | --- |
| `Dockerfile` | `debian:trixie-slim` with OS packages, system-wide mise and the `dev` user (UID/GID from build args) |
| `entrypoint.sh` | Sets git identity, installs mise tools and the matching Playwright Chromium, then starts OpenChamber (or `exec`s the given command) |
| `mise.toml` | The toolchain. Mounted as `/etc/mise/config.toml` |
| `compose.yaml` | Stack `openchamber`, services `openchamber` and `code`. Traefik labels and a dataset-backed home volume shared with code-server |
| `.env.example` | Template for `.env`, which holds both UI passwords, bind address, UID/GID and git identity |
| `.devcontainer/devcontainer.json` | Lets VS Code attach to the running service without ever stopping it |
| `WORKSPACE_DIR` | Host path for the external dataset backing the shared home/workspace volume |

Renovate is configured in the repository's root `renovate.json5`.

## First run

```sh
cd openchamber-devbox
cp .env.example .env
$EDITOR .env                 # both UI passwords, UID/GID (id -u / id -g), WORKSPACE_DIR, git identity
mkdir -p /mnt/NVME/openchamber-workspace
chown "$(id -u):$(id -g)" /mnt/NVME/openchamber-workspace
# For an existing deployment, migrate the old named home volume before starting.
docker compose up -d --build
docker compose logs -f       # first start installs the toolchain (a minute or two)
```

OpenChamber is `healthy` once it answers on port 3000. Set both `OPENCHAMBER_UI_PASSWORD` and `CODE_SERVER_PASSWORD`; code-server requires its password at Compose startup, and OpenChamber exits rather than serving if its password is missing. Existing `.env` files must add `CODE_SERVER_PASSWORD` before starting the new service.

The stack joins the external `proxy` network like the other stacks, so Traefik serves OpenChamber at `https://openchamber.local.watermarkhu.nl` and code-server at `https://code.local.watermarkhu.nl`. Neither service needs a host port for that. For direct VPN access to OpenChamber, set `BIND_ADDR` to the server's Tailscale IP (`tailscale ip -4`). Ports 3000 and 3001 are taken by ha-wa-bridge and Dockhand, so `HOST_PORT` defaults to 3002.

Traefik needs no special configuration: it proxies WebSockets and streams SSE unbuffered by default.

### Dockhand

Dockhand runs `docker compose` inside its own container. The `WORKSPACE_DIR` local-volume device must be the absolute Docker-host path `/mnt/NVME/openchamber-workspace`; make sure the directory exists and is owned by the configured UID/GID. The `./mise.toml` mount still relies on Dockhand's path translation. If it shows up as an empty directory inside the container, replace that mount source with the absolute host path of this directory.

## Git access

Generate a dedicated key inside the container. It lives in the shared external home dataset, so you only need to do this once:

```sh
docker compose exec openchamber ssh-keygen -t ed25519 -C "openchamber-devbox" -f /home/dev/.ssh/id_ed25519 -N ""
docker compose exec openchamber cat /home/dev/.ssh/id_ed25519.pub
```

Add the public key to GitHub, either as an account SSH key or, to limit it to one repository, as a deploy key. Then:

```sh
docker compose exec openchamber ssh -T git@github.com
docker compose exec openchamber git clone git@github.com:you/project.git /workspace/project
```

For the GitHub CLI (PRs, issues), log in once. The token is stored in `~/.config/gh` in the `home` volume:

```sh
docker compose exec -it openchamber gh auth login
```

The entrypoint writes `GIT_USER_NAME` and `GIT_USER_EMAIL` to the global git config. It also marks `/workspace/*` as a `safe.directory`.

## Day to day

```sh
docker compose exec openchamber bash       # shell as dev (mise activated)
docker compose exec openchamber opencode auth login
docker compose run --rm openchamber bash   # one-off container with the same volumes
docker compose logs -f openchamber
docker compose restart openchamber
docker compose ps                           # health status
```

### Playwright MCP

OpenCode uses `bunx` to fetch the Playwright MCP package and its JavaScript dependencies on demand; the package is not pinned in `mise.toml`. `bunx` does not install the browser binary, so the entrypoint separately installs Chromium and its Linux dependencies using the Playwright version required by the latest MCP package. The browser cache persists in the `home` volume. The first startup may take longer while Chromium is downloaded; later starts check for browser updates. Rebuild the image once when deploying this entrypoint change (`docker compose up -d --build`).

To enable it, add this to `/home/dev/.config/opencode/opencode.json` inside the container (or merge it into the existing config), then restart the OpenChamber service:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "playwright": {
      "type": "local",
      "command": ["bunx", "@playwright/mcp@latest", "--headless", "--no-sandbox"],
      "enabled": true
    }
  }
}
```

Playwright MCP can access websites and interact with authenticated sessions, so only enable it when needed.

VS Code: open this directory and run **Dev Containers: Reopen in Container**, or use Remote-SSH to the server first. VS Code attaches to the running `openchamber` service and never stops it (`shutdownAction: none`).

## Updating

- **Add or change a tool:** edit `mise.toml`, then `docker compose restart openchamber`. The file is bind-mounted, so no rebuild is needed, and the entrypoint installs whatever is missing.
- **Newer tool versions:** run `docker compose exec openchamber mise outdated --bump` to see what is available, then put those versions in `mise.toml` and restart. Usually you just merge the Renovate PR. Versions are pinned, so `mise upgrade` alone does nothing. The config is mounted read-only, so `mise upgrade --bump` can't write it from inside the container.
- **npm tools with install scripts:** mise's npm backend skips dependency scripts unless they are listed in `allow_builds`. `@opencode/cli` needs its own scripts, and `@openchamber/web` needs `node-pty`'s. After changing `allow_builds` on a version that is already installed, run `docker compose exec openchamber mise install -f <tool>`.
- **Base image and OS packages:** `docker compose build --pull && docker compose up -d`.
- **Reset the shared home:** back up `WORKSPACE_DIR` first; it contains OpenCode/provider logins, sessions, OpenChamber settings, SSH keys, dotfiles and projects. Removing the new named volume does not erase the bind-backed dataset, so reset its contents only when you intend to erase all of that data.

## Renovate

The root `renovate.json5` covers this directory:

- **`dockerfile`** manager: updates the `debian:trixie-slim` digest. Patch and digest updates automerge, as they do for the compose stacks.
- **`mise`** manager: bumps the pinned versions in `mise.toml`. It only handles exact versions, which is why nothing says `latest`/`lts`. Tool updates are grouped into a single "openchamber devbox toolchain" PR. Node majors get their own PR, labelled `major-update`. `@openchamber/web` needs node >= 24.14.
- **Regex custom manager**: bumps `ARG MISE_VERSION` in the Dockerfile via its `# renovate:` comment.

Toolchain PRs take effect on the next `docker compose restart openchamber` after Dockhand pulls the change. Dockerfile PRs need a rebuild.

## Security notes

- `dev` has passwordless `sudo` inside the container, so the agent can `apt-get install` things. Treat the container as fully controlled by the agent. To remove sudo, delete the marked line in the `Dockerfile` and rebuild.
- **Never mount the Docker socket** into this container. That would give the agent root on the host.
- code-server can edit and run code in the shared home, including accessing OpenCode/provider credentials and SSH keys. Keep it behind Traefik on the private `*.local` host and use a separate strong `CODE_SERVER_PASSWORD`.
- Keep the UI off the public internet. Use Traefik on the `*.local` domain, `127.0.0.1` or the Tailscale IP, and never bind to `0.0.0.0` or add a public route or tunnel. The UI password is the only lock on a shell that holds your provider credentials.
- Provider keys in `.env` are visible to every process in the container, including the agent. Prefer `opencode auth login` with scoped keys.
