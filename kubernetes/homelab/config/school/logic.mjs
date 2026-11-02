// What the dates mean, shared by the page (imports /logic.mjs) and the server
// (/api/items, /api/today), so the two can never disagree. All calendar days are
// Stockholm days. No DOM and no node: only Intl and Date.
export const TZ = "Europe/Stockholm";
const fmtParts = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
export const parts = (d) => Object.fromEntries(fmtParts.formatToParts(d).map((p) => [p.type, p.value]));
export const dayKey = (d) => { const p = parts(d); return `${p.year}-${p.month}-${p.day}`; };
export const keyDate = (k) => new Date(k + "T12:00:00Z");
export const addDays = (k, n) => { const d = keyDate(k); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const daysBetween = (a, b) => Math.round((keyDate(b) - keyDate(a)) / 86400000);
export const hm = (d) => { const p = parts(d); return `${p.hour}:${p.minute}`; };

// "2026-11-05T15:30" or "2026-11-05" written in Stockholm time, as a Date.
export function stockholm(local) {
  const [date, time = "00:00"] = local.split("T");
  const guess = new Date(`${date}T${time}:00Z`), p = parts(guess);
  const shown = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
  return new Date(guess.getTime() - (shown - guess.getTime()));
}

// open, done, deferred ("not due this round"), passed, or missed.
const PASSIVE = new Set(["exam", "seminar", "event", "action"]);
export function status(it, now = Date.now()) {
  if (it.done_override === true) return "done";
  if (it.deferred && it.done_override === null) return "deferred";
  if (it.auto_done && it.done_override !== false) return "done";
  if (new Date(it.due) > now) return "open";
  // Nothing to hand in and no way to tell if it happened: over is over, not missed.
  // A one-off somebody added is a promise, so it stays overdue until ticked.
  const handIn = it.canvas && (it.canvas.types || []).some((t) => !["none", "not_graded", "on_paper"].includes(t));
  if (PASSIVE.has(it.kind) && !handIn && it.origin !== "manual") return "passed";
  return "missed";
}
export const finished = (it, now = Date.now()) => ["done", "passed"].includes(status(it, now));
const closedAt = (it) => (it.lock_at && it.lock_at !== it.due ? new Date(it.lock_at) : null);
export const stillOpen = (it, now = Date.now()) => it.origin === "manual" || (it.canvas && (!closedAt(it) || closedAt(it) > now));

// Whole days between opening and deadline; the page also shows hours when under a day.
export const windowMs = (it) => (it.opens ? new Date(it.due) - new Date(it.opens) : null);
export const windowDays = (it) => (it.opens ? Math.max(0, daysBetween(dayKey(new Date(it.opens)), dayKey(new Date(it.due)))) : null);
export function windowLabel(it) {
  const ms = windowMs(it);
  if (ms === null) return "";
  if (ms < 86400000) return `open ${Math.max(1, Math.round(ms / 3600000))} h`;
  const n = windowDays(it);
  return `open for ${n} day${n === 1 ? "" : "s"}`;
}
export const SHORT_WINDOW_DAYS = 14;

// One calendar event per opening: the E, C and A levels of a task open together.
// Past openings only stay on the calendar while the thing is still open to do.
export function openings(items, now = Date.now()) {
  const seen = new Map();
  for (const it of items) {
    if (!it.opens) continue;
    const st = status(it, now);
    if (st === "deferred" || st === "done" || st === "passed" || st === "missed") continue;
    const k = `${it.course}|${it.opens}|${it.opens_group || it.id}`;
    if (!seen.has(k)) seen.set(k, { id: it.id, course: it.course, title: it.opens_group || it.title, kind: it.kind, opens: it.opens, all_day: !!it.opens_all_day, source: it.opens_source, url: it.opens_url, due: it.due, window_days: windowDays(it), window: windowLabel(it) });
  }
  return [...seen.values()].sort((a, b) => new Date(a.opens) - new Date(b.opens));
}

// "What should I look at today": the agenda and /api/today both read this.
export function today(items, now = Date.now()) {
  const t = dayKey(new Date(now)), week = addDays(t, 7), soon = now + 3 * 86400000;
  const opening = openings(items, now);
  const keyOf = (o) => dayKey(new Date(o.opens));
  const active = items.filter((it) => status(it, now) === "open");
  const byDue = (a, b) => new Date(a.due) - new Date(b.due);
  return {
    date: t,
    opened_today: opening.filter((o) => keyOf(o) === t),
    be_ready: opening.filter((o) => keyOf(o) > t && keyOf(o) <= week),
    closing_soon: active.filter((it) => it.opens && new Date(it.opens) <= now && windowDays(it) <= SHORT_WINDOW_DAYS && new Date(it.due) <= soon && dayKey(new Date(it.due)) !== t).sort(byDue),
    due_today: items.filter((it) => dayKey(new Date(it.due)) === t && ["open", "missed"].includes(status(it, now))).sort(byDue),
    overdue: items.filter((it) => status(it, now) === "missed" && dayKey(new Date(it.due)) < t && daysBetween(dayKey(new Date(it.due)), t) <= 21).sort(byDue).reverse(),
  };
}
