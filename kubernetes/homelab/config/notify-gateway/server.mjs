// notify-gateway: plain HTTP for services in the cluster (Time's focus nudges,
// ...) to notify Erik on his phone. Same delivery as agents' `notify` (dotfiles
// modules/home-manager/notify): a native push in his T3 Code app through the
// T3 server on his PC, and a copy in #notifications of his private Discord
// server "Agents" (silent when the push went out). It only ever reaches Erik:
// the Discord copy never mentions anyone. Docs: docs/notifications.md.
//
//   POST /v1/notify   Authorization: Bearer <source token>
//   { "title": "...", "message": "...", "priority": "normal" | "low",
//     "url": "https://...",            // tap target (or "thread" below)
//     "thread": { "environmentId": "...", "threadId": "..." },
//     "tag": "focus-nudge" }           // same tag replaces the earlier one
//   -> 200 { sent: true, app, discordMessageId } | 429 { sent: false, reason }
//
// Sources and their limits come from NOTIFY_SOURCES (secret notify-gateway):
//   { "time": { "token": "...", "perHour": 3, "perDay": 8 } }
// Limits and tag state live in memory; a restart forgets them.
import http from "node:http";
import crypto from "node:crypto";

const PORT = 8080;
const T3_PUSH = process.env.T3_PUSH_URL ?? "http://192.168.50.232:3773/api/push/send";
const DISCORD = process.env.DISCORD_WEBHOOK_URL;
const SOURCES = JSON.parse(process.env.NOTIFY_SOURCES ?? "{}");
const APP_SCHEME = "t3code-preview";
const T3_WEB = "https://t3code.erikfrankling.duckdns.org";
const HOUR = 3_600_000;
const REPEAT_WINDOW = 15 * 60_000;

const sends = new Map(); // source -> [{ at, digest }]
const tags = new Map(); // `${source}:${tag}` -> discord message id

const log = (event, fields = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), event, ...fields }));

function sourceFor(req) {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  for (const [name, config] of Object.entries(SOURCES)) {
    const a = Buffer.from(token);
    const b = Buffer.from(config.token);
    if (a.length === b.length && crypto.timingSafeEqual(a, b)) return { name, config };
  }
  return null;
}

function checkLimits(source, config, digest, now) {
  const list = (sends.get(source) ?? []).filter((s) => s.at > now - 24 * HOUR);
  sends.set(source, list);
  if (list.some((s) => s.digest === digest && s.at > now - REPEAT_WINDOW)) {
    return "the same notification was sent in the last 15 minutes";
  }
  const perHour = config.perHour ?? 3;
  const perDay = config.perDay ?? 8;
  if (list.filter((s) => s.at > now - HOUR).length >= perHour) return `${perHour} in the last hour`;
  if (list.length >= perDay) return `${perDay} in the last 24 hours`;
  return null;
}

async function deliver(source, input) {
  const tagKey = input.tag ? `${source}:${input.tag}` : null;
  const path = input.thread
    ? `/threads/${encodeURIComponent(input.thread.environmentId)}/${encodeURIComponent(input.thread.threadId)}`
    : null;
  const web = path ? `${T3_WEB}${path.replace(/^\/threads/, "")}` : input.url;

  // Native push. The app replaces a notification with the same id, so a tag
  // maps to a stable id.
  let app = false;
  try {
    const response = await fetch(T3_PUSH, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        title: input.title,
        message: input.message,
        class: input.priority,
        ...(path ? { path } : input.url ? { url: input.url } : {}),
        ...(tagKey ? { id: tagKey } : {}),
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (response.ok) app = ((await response.json()).delivered ?? 0) > 0;
  } catch (error) {
    log("push_failed", { source, error: String(error) });
  }

  // Discord copy: replaces the previous message with the same tag. Silent if
  // the native push went out or the priority is low; it never @mentions.
  if (tagKey && tags.has(tagKey)) {
    await fetch(`${DISCORD}/messages/${tags.get(tagKey)}`, { method: "DELETE" }).catch(() => {});
    tags.delete(tagKey);
  }
  let discordMessageId = null;
  try {
    const response = await fetch(`${DISCORD}?wait=true`, {
      method: "POST",
      headers: { "content-type": "application/json", "user-agent": "notify-gateway (homelab, 1.0)" },
      body: JSON.stringify({
        username: "Agents",
        content:
          `**${input.title}**\n${input.message}` +
          (web ? `\n[Open](${web})` : "") +
          `\n-# from ${source}`,
        allowed_mentions: { parse: [] },
        flags: 4 + (app || input.priority === "low" ? 4096 : 0),
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`Discord answered ${response.status}`);
    discordMessageId = (await response.json()).id;
    if (tagKey) tags.set(tagKey, discordMessageId);
  } catch (error) {
    if (!app) throw error;
    log("discord_failed", { source, error: String(error) });
  }
  return { app, discordMessageId };
}

function reply(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function parse(raw) {
  const body = JSON.parse(raw);
  const str = (v, max) => (typeof v === "string" && v.length > 0 && v.length <= max ? v : null);
  const title = str(body.title, 120);
  const message = str(body.message ?? body.body, 1000);
  if (!title || !message) throw new Error("title (≤120) and message (≤1000) are required");
  const priority = body.priority ?? "normal";
  // Sources get no urgent/high/code: those are for agents and alerts.
  if (!["normal", "low"].includes(priority)) throw new Error('priority must be "normal" or "low"');
  if (body.url !== undefined && !/^https?:\/\//.test(body.url ?? "")) throw new Error("url must be http(s)");
  const thread =
    body.thread && str(body.thread.environmentId, 100) && str(body.thread.threadId, 200)
      ? { environmentId: body.thread.environmentId, threadId: body.thread.threadId }
      : undefined;
  const tag = body.tag === undefined ? undefined : str(body.tag, 64);
  if (body.tag !== undefined && !tag) throw new Error("tag must be a string of at most 64 characters");
  return { title, message, priority, url: body.url, thread, tag };
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    return reply(res, DISCORD && Object.keys(SOURCES).length ? 200 : 500, { ok: Boolean(DISCORD) });
  }
  if (req.method !== "POST" || req.url !== "/v1/notify") return reply(res, 404, { error: "not found" });
  const source = sourceFor(req);
  if (!source) return reply(res, 401, { error: "unknown or missing bearer token" });
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 16_384) return reply(res, 413, { error: "body too large" });
  }
  let input;
  try {
    input = parse(raw);
  } catch (error) {
    return reply(res, 400, { error: error.message });
  }
  const now = Date.now();
  const digest = crypto.createHash("sha256").update(`${input.title}\n${input.message}`).digest("hex");
  const refusal = checkLimits(source.name, source.config, digest, now);
  if (refusal) {
    log("refused", { source: source.name, reason: refusal });
    return reply(res, 429, { sent: false, reason: refusal, advice: "Not sent. Do not retry." });
  }
  sends.get(source.name).push({ at: now, digest });
  try {
    const result = await deliver(source.name, input);
    log("sent", { source: source.name, tag: input.tag, ...result });
    return reply(res, 200, { sent: true, ...result });
  } catch (error) {
    // A failed delivery does not use up the budget.
    sends.set(source.name, sends.get(source.name).filter((s) => s.at !== now));
    log("failed", { source: source.name, error: String(error) });
    return reply(res, 502, { sent: false, reason: "delivery failed; try again later" });
  }
});

server.listen(PORT, () => log("listening", { port: PORT, sources: Object.keys(SOURCES) }));
