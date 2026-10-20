// Update server for Erik's T3 Code Android fork (expo-updates protocol v1,
// https://docs.expo.dev/technical-specs/expo-updates-1/). Stateless: the
// fork's CI publishes index.json to its rolling `android-ota` GitHub release
// with every update already signed (scripts/erik-updates.mjs in the fork), so
// this only picks the entry for the asking app's runtime version and sends it
// as the multipart manifest expo-updates wants. No secrets live here; the app
// rejects any manifest not signed by the fork's key.
import * as Http from "node:http";

const INDEX_URL =
  process.env.INDEX_URL ??
  "https://github.com/ErikFrankling/t3code/releases/download/android-ota/index.json";
const PORT = Number(process.env.PORT ?? 8080);
const REFRESH_MS = 15_000;

let index = null;
let fetchedAt = 0;
let refreshing;

async function refresh() {
  try {
    const response = await fetch(`${INDEX_URL}?t=${Date.now()}`, {
      headers: { "cache-control": "no-cache" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    index = await response.json();
    fetchedAt = Date.now();
  } catch (error) {
    // Keep serving the last good index; CI replaces the file non-atomically.
    console.warn(`index refresh failed: ${error.message}`);
  }
}

async function currentIndex() {
  if (Date.now() - fetchedAt > REFRESH_MS) {
    refreshing ??= refresh().finally(() => {
      refreshing = undefined;
    });
    await refreshing;
  }
  return index;
}

function noUpdate(response, protocol) {
  response.writeHead(protocol >= 1 ? 204 : 404, {
    "expo-protocol-version": String(protocol),
    "expo-sfv-version": "0",
    "cache-control": "private, max-age=0",
  });
  response.end();
}

async function manifest(request, response) {
  const protocol = Number(request.headers["expo-protocol-version"] ?? 0);
  const platform = request.headers["expo-platform"];
  const runtime = request.headers["expo-runtime-version"];
  const current = await currentIndex();
  const entry = platform === "android" && runtime ? current?.runtimes?.[runtime] : undefined;
  if (!entry) return noUpdate(response, protocol);

  const boundary = `t3-${entry.id}`;
  const body = [
    `--${boundary}`,
    'content-disposition: form-data; name="manifest"',
    "content-type: application/json; charset=utf-8",
    `expo-signature: ${entry.signature}`,
    "",
    entry.manifest,
    `--${boundary}`,
    'content-disposition: form-data; name="extensions"',
    "content-type: application/json",
    "",
    JSON.stringify({ assetRequestHeaders: {} }),
    `--${boundary}--`,
    "",
  ].join("\r\n");
  response.writeHead(200, {
    "expo-protocol-version": String(protocol),
    "expo-sfv-version": "0",
    "cache-control": "private, max-age=0",
    "content-type": `multipart/mixed; boundary=${boundary}`,
  });
  response.end(body);
}

async function health(response) {
  const current = await currentIndex();
  // 200 even before CI has published an index: readiness gates Flux.
  response.writeHead(200, { "content-type": "application/json" });
  response.end(
    JSON.stringify({
      ok: Boolean(current),
      indexAgeSeconds: current ? Math.round((Date.now() - fetchedAt) / 1000) : null,
      apk: current?.apk ? { versionName: current.apk.versionName, runtimeVersion: current.apk.runtimeVersion } : null,
      runtimes: Object.fromEntries(
        Object.entries(current?.runtimes ?? {}).map(([runtime, entry]) => [
          runtime,
          { id: entry.id, createdAt: entry.createdAt, commit: entry.commit },
        ]),
      ),
    }),
  );
}

Http.createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;
  const handler =
    request.method === "GET" && path === "/manifest"
      ? manifest(request, response)
      : request.method === "GET" && path === "/healthz"
        ? health(response)
        : Promise.resolve(response.writeHead(404).end());
  handler.catch((error) => {
    console.error(error);
    if (!response.headersSent) response.writeHead(500);
    response.end();
  });
}).listen(PORT, () => console.log(`t3-updates listening on ${PORT}`));
