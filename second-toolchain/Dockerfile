# The opencode sandbox.
#
# Built on the published opencode image, which is Alpine plus the opencode
# binary and ripgrep. That base cannot run tests or commit anything, so this
# adds the language-neutral tooling the roles need and an unprivileged user.
#
# Pinned on purpose. Every claim in README.md under "What has been verified"
# was checked against this version.
ARG OPENCODE_VERSION=1.18.29
FROM ghcr.io/anomalyco/opencode:${OPENCODE_VERSION}

# The project's own toolchain, kept out of the image definition so the sandbox
# does not assume a language. Override per project without editing this file:
#
#   LANG_PACKAGES="go"                     in .env, or
#   docker compose build --build-arg LANG_PACKAGES="openjdk21 maven"
#
# Add build-base when native modules have to compile (node-gyp, C extensions).
ARG LANG_PACKAGES="nodejs npm python3"

# git is required by the workflow itself, not by the project. The assignment
# asks for changes as commits or reviewable diffs, and the base image has no git.
RUN apk add --no-cache \
      git \
      bash \
      curl \
      ca-certificates \
      ${LANG_PACKAGES}

# The compose file runs as 1000:1000 and mounts named volumes on /home/dev.
# Without a real passwd entry HOME falls back to /, which uid 1000 cannot write,
# and the volumes would sit on a path opencode never reads. Creating the
# directories here also gives the named volumes their ownership on first run,
# because Docker seeds an empty volume from the image path it covers.
RUN adduser -D -u 1000 -h /home/dev dev \
 && mkdir -p /home/dev/.config/opencode /home/dev/.local/share/opencode \
 && chown -R dev:dev /home/dev

USER dev
WORKDIR /workspace

# Inherited from the base image, restated so the image behaves the same when
# run directly with docker run.
ENTRYPOINT ["opencode"]
