# Upstream drops Claude's limits[] (Fable). Keep its server/UI and patch parsing only.
FROM node:24.22.1-alpine AS web
RUN apk add --no-cache curl
WORKDIR /src
RUN curl -fsSL https://github.com/Willxup/cpa-usage-keeper/archive/41b34f12dbef209292765415b860583aad5afc09.tar.gz | tar xz --strip-components=1
WORKDIR /src/web
RUN npm ci && npm run build
FROM golang:1.26.10-alpine AS build
RUN apk add --no-cache build-base patch
WORKDIR /src
COPY --from=web /src /src
COPY scoped-limits.patch /src/
RUN patch -p1 < scoped-limits.patch
COPY scoped_limits_test.go /src/internal/quota/
RUN go test ./internal/quota -run TestScopedLimits && CGO_ENABLED=1 go build -ldflags='-s -w -X cpa-usage-keeper/internal/version.Version=2.1.0-scoped1' -o /out/keeper ./cmd/server/main.go
FROM ghcr.io/willxup/cpa-usage-keeper:v2.1.0@sha256:c071c6326e95601988e011ef38f0fe4cfd2bd50dcebf18848cd10cc1a01edb84
COPY --from=build /out/keeper /app/cpa-usage-keeper
