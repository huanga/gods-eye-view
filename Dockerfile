# syntax=docker/dockerfile:1
# God's Eye View — all-in-one image.
#
# The app is a single Node process: a Vite server whose middleware brokers
# API keys for every live-data layer. There is no standalone production
# server, so the image builds the static bundle and serves it with
# `vite preview`, which runs the same provider middleware as the dev server.
#
# Every runtime dependency is pure JavaScript or WASM (no native binaries),
# so the Alpine-based Node image is sufficient.
#
# Usage:
#   docker build -t gods-eye-view .
#   docker run -p 4173:4173 --env-file .env gods-eye-view
#
# See .env.docker.example for the supported environment variables and
# compose.yaml for a Traefik/Authentik-fronted example.

# ---------------------------------------------------------------------------
# Builder: install all dependencies and build the static client bundle.
# ---------------------------------------------------------------------------
FROM node:24-alpine AS builder

# Client-exposed keys, baked into the bundle at build time. These are visible
# in browser devtools by design — scope them at the provider for your origin.
# Pass real values with:
#   docker build --build-arg GOOGLE_MAPS_API_KEY=... -t gods-eye-view .
# or via compose `build.args`. Empty placeholders build a fully working app
# minus the Google 3D / Cesium ion / Mapillary layers.
ARG GOOGLE_MAPS_API_KEY=""
ARG CESIUM_ION_TOKEN=""
ARG MAPILLARY_CLIENT_TOKEN=""
ENV GOOGLE_MAPS_API_KEY=$GOOGLE_MAPS_API_KEY \
    CESIUM_ION_TOKEN=$CESIUM_ION_TOKEN \
    MAPILLARY_CLIENT_TOKEN=$MAPILLARY_CLIENT_TOKEN

WORKDIR /app

# devDependencies are required for the build (vite, vite-plugin-cesium, sharp).
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Build the static bundle (client-exposed keys come from the ARGs above).
RUN npm run build

# ---------------------------------------------------------------------------
# Runtime: production dependencies only, pre-built bundle.
# ---------------------------------------------------------------------------
FROM node:24-alpine AS runtime

WORKDIR /app

# NODE_ENV is deliberately NOT set: `vite preview` is the runtime server and
# needs the devDependencies (vite itself, vite-plugin-cesium, ws). Setting
# NODE_ENV=production would make npm skip dev deps and the server would not
# start. The app behaves identically; this only affects npm's install set.
ENV HOST=0.0.0.0 \
    PORT=4173

# Runtime deps. `vite preview` IS the server (no standalone production entry),
# and the config graph pulls in build-time plugins (vite-plugin-cesium, ws for
# the AISStream provider, etc.). NODE_ENV stays production; npm installs dev
# deps here because the runtime server needs them. The require() guard makes
# the build fail loudly if vite or ws ever go missing from this layer.
COPY package.json package-lock.json ./
RUN npm ci \
    && node -e "require.resolve('vite/package.json'); require.resolve('ws/package.json')"

COPY --from=builder /app/dist ./dist
COPY server ./server
COPY src ./src
COPY config ./config
COPY public ./public
# build/ holds allowedHosts.js, needed by the container config wrapper.
# scripts/ is imported by server config modules the wrapper pulls in.
COPY build ./build
COPY scripts ./scripts
# Container-only Vite config: loads the app config and adds preview.allowedHosts
# (see the file for why — the app's host-check reads preview.allowedHosts under
# `vite preview`, which the app config never sets). Not part of the app itself.
COPY deploy/vite.container.config.js ./deploy/vite.container.config.js

# Runtime state. Multiple providers write caches and logs under the working
# directory (.gev-cache/, .gev-logs/); the filesystem must be writable.
# Anonymous volumes keep this state across container replacements.
# Do NOT mount a host .env here unless you want it overwritten at runtime —
# pass configuration with `docker run --env-file` or compose `environment:`.
VOLUME ["/app/.gev-cache", "/app/.gev-logs"]

EXPOSE 4173

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:4173/ >/dev/null 2>&1 || exit 1

# Single long-running process: `vite preview` serves the built bundle plus
# the full key-brokering proxy middleware. The container config wrapper adds
# preview.allowedHosts from GEV_ALLOWED_HOSTS (see deploy/vite.container.config.js).
CMD ["npx", "vite", "preview", "--config", "deploy/vite.container.config.js", "--host", "0.0.0.0", "--port", "4173"]
