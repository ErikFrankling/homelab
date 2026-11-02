// School calendar (apps/school.yaml): every deadline in Erik's KTH courses,
// with a done toggle. The PC builds the item list from its Canvas archive
// after the daily refresh and POSTs it to /api/ingest (dotfiles
// modules/home-manager/school-sync). This server never talks to Canvas.
//
// State is one JSON file on the PVC: the latest items, one-off items added by
// hand or by an agent (POST /api/custom; ingests leave them alone), Erik's done
// toggles, when each item was first seen and last changed, and an ingest log.
import { createServer } from "node:http";
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { timingSafeEqual, createHash } from "node:crypto";
import { status, stockholm, windowDays, windowLabel, openings, today } from "./logic.mjs";

const PORT = Number(process.env.PORT || 8080);
const DATA = process.env.DATA_FILE || "/data/state.json";
const TOKEN = process.env.INGEST_TOKEN || "";
const PAGE = readFileSync(new URL("./index.html", import.meta.url), "utf8");
const FONT = readFileSync(new URL("./inter.woff2", import.meta.url));
const LOGIC = readFileSync(new URL("./logic.mjs", import.meta.url));

// The page arrives with its data inlined, so it renders complete on first
// paint instead of empty-then-filled.
function page() {
  const json = JSON.stringify(view()).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
  return PAGE.replace("<!--DATA-->", `<script>window.__DATA__=${json}</script>`);
}

let state = { items: [], custom: [], meta: {}, done: {}, seen: {}, log: [] };
if (existsSync(DATA)) state = { ...state, ...JSON.parse(readFileSync(DATA, "utf8")) };

function save() {
  writeFileSync(DATA + ".tmp", JSON.stringify(state));
  renameSync(DATA + ".tmp", DATA);
}

const everything = () => [...state.items, ...state.custom];

function view() {
  const items = everything().map((it) => {
    const full = {
      ...it,
      first_seen: state.seen[it.id]?.first_seen ?? null,
      changed_at: state.seen[it.id]?.changed_at ?? null,
      initial: state.seen[it.id]?.initial ?? false,
      done_override: state.done[it.id]?.done ?? null,
      done_at: state.done[it.id]?.at ?? null,
    };
    return { ...full, status: status(full), window_days: windowDays(full), window: windowLabel(full) };
  });
  return { meta: state.meta, log: state.log.slice(-14), no_opening: state.no_opening ?? [], items };
}

const SITE = "https://school.erikfrankling.duckdns.org";

// The list a reminder job needs, without each item's page of text.
function brief() {
  const short = (it) => ({ id: it.id, course: it.course, title: it.title, kind: it.kind, status: it.status, due: it.due, due_source: it.due_source, opens: it.opens, opens_source: it.opens_source, window_days: it.window_days, url: `${SITE}/#/item/${encodeURIComponent(it.id)}` });
  const t = today(view().items);
  const open = (o) => ({ ...o, url: `${SITE}/#/item/${encodeURIComponent(o.id)}`, source_url: o.url });
  return { date: t.date, opened_today: t.opened_today.map(open), be_ready: t.be_ready.map(open), closing_soon: t.closing_soon.map(short), due_today: t.due_today.map(short), overdue: t.overdue.map(short) };
}

// A date as an agent or the form writes it: "2026-11-05" (a whole day), "2026-11-05T15:30"
// (Stockholm time) or a full ISO time with an offset.
function parseWhen(v, endOfDay) {
  const s = String(v);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return { at: stockholm(`${s}T${endOfDay ? "23:59" : "00:00"}`), allDay: true };
  const at = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s) ? stockholm(s) : new Date(s);
  if (Number.isNaN(at.getTime())) throw new Error(`bad date: ${s}`);
  return { at, allDay: false };
}

const KINDS = new Set(["action", "assignment", "quiz", "lab", "seminar", "exam", "peer review", "event"]);

function addCustom(b) {
  const title = String(b.title ?? "").trim();
  if (!title || title.length > 200) throw new Error("title is required, at most 200 characters");
  if (!b.due) throw new Error("due is required");
  const kind = b.kind ?? "action";
  if (!KINDS.has(kind)) throw new Error(`kind must be one of ${[...KINDS].join(", ")}`);
  const due = parseWhen(b.due, true), opens = b.opens ? parseWhen(b.opens, false) : null;
  if (opens && opens.at >= due.at) throw new Error("opens must be before due");
  const url = b.url ? String(b.url) : null;
  if (url && !/^https?:\/\//.test(url)) throw new Error("url must be http(s)");
  const course = String(b.course ?? "KTH").trim().toUpperCase().slice(0, 12);
  const known = everything().find((i) => i.course === course);
  const note = String(b.note ?? "").slice(0, 4000);
  const now = new Date().toISOString();
  const it = {
    id: `manual-${Date.now().toString(36)}`, origin: "manual", course, course_name: known?.course_name ?? course, course_id: known?.course_id ?? null,
    title, kind, due: due.at.toISOString(), due_source: "manual", all_day: due.allDay, start: null, lock_at: null,
    opens: opens ? opens.at.toISOString() : null, opens_source: opens ? "manual" : null, opens_url: url, opens_all_day: opens?.allDay ?? false, opens_group: opens ? title : null,
    canvas: null, auto_done: false, auto_reason: null, deferred: null, markdown: note,
    detail: { facts: [], notes: [], body: note, related: [] }, sources: url ? [{ label: "Link", url }] : [], added_by: String(b.added_by ?? "").slice(0, 60) || null,
  };
  state.custom.push(it);
  state.seen[it.id] = { first_seen: now, hash: null, changed_at: null, initial: false };
  save();
  return it;
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
  state.no_opening = body.no_opening ?? [];
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
  const items = everything().map((it) => ({ ...it, done_override: state.done[it.id]?.done ?? null }));
  for (const o of openings(items)) {
    out.push("BEGIN:VEVENT", `UID:opens-${o.id}@school.erikfrankling.duckdns.org`, `DTSTAMP:${now}`);
    if (o.all_day) out.push(`DTSTART;VALUE=DATE:${day(o.opens)}`);
    else out.push(`DTSTART:${stamp(new Date(o.opens).toISOString())}`, `DTEND:${stamp(new Date(new Date(o.opens).getTime() + 30 * 60000).toISOString())}`);
    out.push(`SUMMARY:${esc(`${o.course}: Opens: ${o.title}`)}`, `URL:https://school.erikfrankling.duckdns.org/#/item/${encodeURIComponent(o.id)}`, "END:VEVENT");
  }
  for (const it of items) {
    const done = it.done_override ?? it.auto_done;
    out.push("BEGIN:VEVENT", `UID:${it.id}@school.erikfrankling.duckdns.org`, `DTSTAMP:${now}`);
    if (it.all_day) {
      out.push(`DTSTART;VALUE=DATE:${day(it.due)}`);
    } else {
      const end = new Date(it.due);
      const start = it.start ? new Date(it.start) : new Date(end.getTime() - 30 * 60000);
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

const ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#0e0f11"/><rect x="14" y="17" width="36" height="32" rx="5" fill="none" stroke="#ececee" stroke-width="3"/><path d="M14 27h36" stroke="#ececee" stroke-width="3"/><path d="M24 12v9M40 12v9" stroke="#ececee" stroke-width="3" stroke-linecap="round"/><circle cx="40" cy="38" r="3.5" fill="#7b83eb"/></svg>`;
const MANIFEST = { name: "School", short_name: "School", start_url: "/", display: "standalone", background_color: "#0e0f11", theme_color: "#0e0f11", icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml" }] };

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    const p = url.pathname;
    if (p === "/healthz") return send(res, 200, "ok", "text/plain");
    if (req.method === "GET" && p === "/api/items") return send(res, 200, view());
    if (req.method === "GET" && p === "/api/today") return send(res, 200, brief());
    if (req.method === "GET" && p === "/logic.mjs") return send(res, 200, LOGIC, "text/javascript; charset=utf-8");
    if (req.method === "POST" && p === "/api/custom") return send(res, 201, addCustom(JSON.parse(await readBody(req, 64 * 1024))));
    const custom = p.match(/^\/api\/custom\/([^/]+)$/);
    if (req.method === "DELETE" && custom) {
      const id = decodeURIComponent(custom[1]);
      if (!state.custom.some((i) => i.id === id)) return send(res, 404, { error: "no such one-off item" });
      state.custom = state.custom.filter((i) => i.id !== id);
      delete state.done[id];
      delete state.seen[id];
      save();
      return send(res, 200, { removed: id });
    }
    if (req.method === "GET" && p === "/calendar.ics") return send(res, 200, ics(), "text/calendar; charset=utf-8");
    if (req.method === "GET" && p === "/inter.woff2") return send(res, 200, FONT, "font/woff2", { "Cache-Control": "public, max-age=31536000, immutable" });
    if (req.method === "GET" && p === "/icon.svg") return send(res, 200, ICON, "image/svg+xml", { "Cache-Control": "max-age=86400" });
    if (req.method === "GET" && p === "/manifest.webmanifest") return send(res, 200, MANIFEST, "application/manifest+json");
    if (req.method === "POST" && p === "/api/ingest") {
      if (!authorized(req)) return send(res, 401, { error: "unauthorized" });
      return send(res, 200, ingest(JSON.parse(await readBody(req))));
    }
    const m = p.match(/^\/api\/items\/([^/]+)\/done$/);
    if (req.method === "POST" && m) {
      const id = decodeURIComponent(m[1]);
      if (!everything().some((i) => i.id === id)) return send(res, 404, { error: "no such item" });
      const { done } = JSON.parse((await readBody(req, 4096)) || "{}");
      if (done === null || done === undefined) delete state.done[id];
      else state.done[id] = { done: !!done, at: new Date().toISOString() };
      save();
      return send(res, 200, { id, done_override: state.done[id]?.done ?? null });
    }
    if (req.method === "GET" && (p === "/" || p === "/index.html")) return send(res, 200, page(), "text/html; charset=utf-8");
    send(res, 404, { error: "not found" });
  } catch (e) {
    send(res, 400, { error: String(e.message || e) });
  }
}).listen(PORT, () => console.log(`school listening on :${PORT}, ${state.items.length} items`));
