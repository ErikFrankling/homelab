// School calendar (apps/school.yaml): every deadline in Erik's KTH courses,
// with a done toggle. The PC builds the item list from its Canvas archive
// after the daily refresh and POSTs it to /api/ingest (dotfiles
// modules/home-manager/school-sync). This server never talks to Canvas.
//
// State is one JSON file on the PVC: the latest items, Erik's done toggles,
// when each item was first seen and last changed, and a short ingest log.
import { createServer } from "node:http";
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { timingSafeEqual, createHash } from "node:crypto";

const PORT = Number(process.env.PORT || 8080);
const DATA = process.env.DATA_FILE || "/data/state.json";
const TOKEN = process.env.INGEST_TOKEN || "";
const PAGE = readFileSync(new URL("./index.html", import.meta.url));

let state = { items: [], meta: {}, done: {}, seen: {}, log: [] };
if (existsSync(DATA)) state = { ...state, ...JSON.parse(readFileSync(DATA, "utf8")) };

function save() {
  writeFileSync(DATA + ".tmp", JSON.stringify(state));
  renameSync(DATA + ".tmp", DATA);
}

function view() {
  return {
    meta: state.meta,
    log: state.log.slice(-14),
    items: state.items.map((it) => ({
      ...it,
      first_seen: state.seen[it.id]?.first_seen ?? null,
      changed_at: state.seen[it.id]?.changed_at ?? null,
      initial: state.seen[it.id]?.initial ?? false,
      done_override: state.done[it.id]?.done ?? null,
      done_at: state.done[it.id]?.at ?? null,
    })),
  };
}

function ingest(body) {
  if (!Array.isArray(body.items)) throw new Error("items missing");
  const now = new Date().toISOString();
  const first = state.items.length === 0 && Object.keys(state.seen).length === 0;
  const before = new Set(state.items.map((i) => i.id));
  const added = [], changed = [];
  for (const it of body.items) {
    const s = state.seen[it.id];
    if (!s) {
      state.seen[it.id] = { first_seen: now, hash: it.hash, changed_at: null, initial: first };
      added.push(it.id);
    } else if (s.hash !== it.hash) {
      s.hash = it.hash;
      s.changed_at = now;
      changed.push(it.id);
    }
  }
  const ids = new Set(body.items.map((i) => i.id));
  const removed = [...before].filter((id) => !ids.has(id));
  state.items = body.items;
  state.meta = { generated_at: body.generated_at, archive_retrieved_at: body.archive_retrieved_at, ingested_at: now };
  state.log.push({ at: now, items: body.items.length, added: added.length, changed: changed.length, removed: removed.length });
  state.log = state.log.slice(-60);
  save();
  return { items: body.items.length, added: added.length, changed: changed.length, removed: removed.length };
}

// ---- iCalendar feed (subscribe from a phone calendar on the LAN/tailnet) ----
function ics() {
  const esc = (s) => String(s).replace(/[\\;,]/g, (c) => "\\" + c).replace(/\n/g, "\\n");
  const stamp = (iso) => iso.replace(/[-:]/g, "").replace(/\.\d+/, "").replace(/\+00:00$/, "Z");
  const day = (iso) => new Date(iso).toLocaleDateString("sv-SE", { timeZone: "Europe/Stockholm" }).replace(/-/g, "");
  const out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//homelab//school//EN", "X-WR-CALNAME:School", "X-WR-TIMEZONE:Europe/Stockholm"];
  const now = stamp(new Date().toISOString());
  for (const it of state.items) {
    const done = state.done[it.id]?.done ?? it.auto_done;
    out.push("BEGIN:VEVENT", `UID:${it.id}@school.erikfrankling.duckdns.org`, `DTSTAMP:${now}`);
    if (it.all_day) {
      out.push(`DTSTART;VALUE=DATE:${day(it.due)}`);
    } else {
      const end = new Date(it.due);
      const start = it.start && it.kind !== "registration" ? new Date(it.start) : new Date(end.getTime() - 30 * 60000);
      out.push(`DTSTART:${stamp(start.toISOString())}`, `DTEND:${stamp(end.toISOString())}`);
    }
    const tag = it.deferred ? " (not due this round)" : done ? " ✓" : "";
    out.push(`SUMMARY:${esc(`${it.course}: ${it.title}${tag}`)}`, `URL:https://school.erikfrankling.duckdns.org/#/item/${encodeURIComponent(it.id)}`);
    out.push(`DESCRIPTION:${esc(it.sources.map((s) => `${s.label}: ${s.url}`).join("\n"))}`, "END:VEVENT");
  }
  out.push("END:VCALENDAR");
  // Fold lines at 75 octets as RFC 5545 asks.
  return out.map((l) => l.match(/.{1,73}/gu)?.join("\r\n ") ?? l).join("\r\n") + "\r\n";
}

function send(res, code, body, type = "application/json; charset=utf-8", extra = {}) {
  const data = typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store", ...extra });
  res.end(data);
}

function readBody(req, limit = 20 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(new Error("too large")); req.destroy(); }
      else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function authorized(req) {
  const got = (req.headers.authorization || "").replace(/^Bearer /, "");
  if (!TOKEN || !got) return false;
  const a = createHash("sha256").update(got).digest(), b = createHash("sha256").update(TOKEN).digest();
  return timingSafeEqual(a, b);
}

const ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#14171f"/><rect x="12" y="16" width="40" height="36" rx="6" fill="none" stroke="#8ab4ff" stroke-width="4"/><path d="M12 26h40" stroke="#8ab4ff" stroke-width="4"/><path d="M22 10v10M42 10v10" stroke="#8ab4ff" stroke-width="4" stroke-linecap="round"/><path d="M24 39l6 6 11-12" fill="none" stroke="#7ee0a8" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const MANIFEST = { name: "School", short_name: "School", start_url: "/", display: "standalone", background_color: "#0c0e13", theme_color: "#0c0e13", icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }] };

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    const p = url.pathname;
    if (p === "/healthz") return send(res, 200, "ok", "text/plain");
    if (req.method === "GET" && p === "/api/items") return send(res, 200, view());
    if (req.method === "GET" && p === "/calendar.ics") return send(res, 200, ics(), "text/calendar; charset=utf-8");
    if (req.method === "GET" && p === "/icon.svg") return send(res, 200, ICON, "image/svg+xml", { "Cache-Control": "max-age=86400" });
    if (req.method === "GET" && p === "/manifest.webmanifest") return send(res, 200, MANIFEST, "application/manifest+json");
    if (req.method === "POST" && p === "/api/ingest") {
      if (!authorized(req)) return send(res, 401, { error: "unauthorized" });
      return send(res, 200, ingest(JSON.parse(await readBody(req))));
    }
    const m = p.match(/^\/api\/items\/([^/]+)\/done$/);
    if (req.method === "POST" && m) {
      const id = decodeURIComponent(m[1]);
      if (!state.items.some((i) => i.id === id)) return send(res, 404, { error: "no such item" });
      const { done } = JSON.parse((await readBody(req, 4096)) || "{}");
      if (done === null || done === undefined) delete state.done[id];
      else state.done[id] = { done: !!done, at: new Date().toISOString() };
      save();
      return send(res, 200, { id, done_override: state.done[id]?.done ?? null });
    }
    if (req.method === "GET" && (p === "/" || p === "/index.html")) return send(res, 200, PAGE, "text/html; charset=utf-8");
    send(res, 404, { error: "not found" });
  } catch (e) {
    send(res, 400, { error: String(e.message || e) });
  }
}).listen(PORT, () => console.log(`school listening on :${PORT}, ${state.items.length} items`));
