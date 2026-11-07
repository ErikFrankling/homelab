# Pinned upstream source; update the source and validate network-login.mjs together.
FROM oven/bun:1.4.3@sha256:ec06c3b6cea04192ae6770c434f668ca41d343ad19fa6472216c7b48be39c598 AS build
WORKDIR /src
ADD https://github.com/router-for-me/Cli-Proxy-API-Management-Center/archive/953fb2444350c6c36052dda46cac0abce6b23ea6.tar.gz source.tar.gz
RUN tar -xzf source.tar.gz --strip-components=1 && rm source.tar.gz
COPY network-login.mjs /src/network-login.mjs
RUN bun network-login.mjs && bun install --frozen-lockfile && bun run build
FROM nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
COPY --from=build /src/dist/index.html /usr/share/nginx/html/management.html
# Run nginx directly; no entrypoint rewrites of the read-only secret config.
ENTRYPOINT ["nginx", "-g", "daemon off;"]
