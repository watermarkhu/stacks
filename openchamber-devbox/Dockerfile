# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Tag + digest pin, kept current by Renovate (dockerfile manager + docker:pinDigests).
FROM debian:trixie-slim@sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31

# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=2026.10.21
ARG UID=1000
ARG GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client sudo gnupg build-essential pkg-config \
        unzip xz-utils zstd jq ripgrep fd-find less procps nano \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# mise, system-wide. Leave MISE_VERSION empty (--build-arg MISE_VERSION=) for the latest release.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise MISE_VERSION="${MISE_VERSION}" sh \
    && mise --version

# Non-root user whose UID/GID match the host user, so bind-mounted files keep the right owner.
# If a group with GID already exists in the base image, reuse it.
RUN if ! getent group "${GID}" >/dev/null; then groupadd --gid "${GID}" dev; fi \
    && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash dev \
    && mkdir -p /workspace /home/dev/.local/share/mise /home/dev/.cache/mise /home/dev/.local/bin \
    && chown -R "${UID}:${GID}" /workspace /home/dev

# Passwordless sudo for dev (apt-get install etc.). To remove it, delete this line; then also drop
# the `sudo chown` fallback in entrypoint.sh and pre-create WORKSPACE_DIR on the host as your user.
RUN echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev && chmod 0440 /etc/sudoers.d/dev

ENV MISE_DATA_DIR=/home/dev/.local/share/mise \
    MISE_CACHE_DIR=/home/dev/.cache/mise \
    MISE_YES=1 \
    MISE_TRUSTED_CONFIG_PATHS=/workspace \
    PATH=/home/dev/.local/share/mise/shims:/home/dev/.local/bin:${PATH}

# Shims on PATH cover non-interactive processes (OpenChamber, OpenCode, agent tool calls);
# activation gives interactive shells the full mise experience. Login shells (`bash -l`, ssh)
# get PATH reset by /etc/profile, so put the shims back via profile.d.
RUN echo 'eval "$(mise activate bash)"' >> /etc/bash.bashrc \
    && echo 'export PATH="/home/dev/.local/share/mise/shims:/home/dev/.local/bin:$PATH"' > /etc/profile.d/mise.sh

COPY mise.toml /etc/mise/config.toml
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /workspace
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
