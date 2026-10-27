#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*" >&2; }

# Docker creates a missing bind-mount source as root; hand it to dev.
if [[ ! -w /workspace ]]; then
  log "/workspace is not writable, fixing ownership"
  sudo -n chown "$(id -u):$(id -g)" /workspace
fi

if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi
if ! git config --global --get-all safe.directory | grep -qxF '/workspace/*'; then
  git config --global --add safe.directory '/workspace/*'
fi

# node first: the npm: backends need it. Both are no-ops once the tools sit in the home volume.
start=$SECONDS
log "mise install"
mise install node
mise install
mise reshim
log "mise install finished in $((SECONDS - start))s"

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

if [[ -z "${OPENCHAMBER_UI_PASSWORD:-}" ]]; then
  log "ERROR: OPENCHAMBER_UI_PASSWORD is not set. Set it in .env; refusing to start OpenChamber without a password."
  exit 1
fi

log "starting OpenChamber on 0.0.0.0:3000"
exec openchamber serve --host 0.0.0.0 --port 3000 --ui-password "$OPENCHAMBER_UI_PASSWORD" --foreground
