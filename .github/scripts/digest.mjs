// Weekly digest: posts this week's bass shows to a Discord channel and/or a GroupMe group.
// Reads data.json. Configure with repo secrets DISCORD_WEBHOOK_URL and/or GROUPME_BOT_ID.
import { readFileSync } from "node:fs";

const SITE = "https://jeedus.github.io/BassCalendar/";
const data = JSON.parse(readFileSync("data.json", "utf8"));
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
const addDays = (s, n) => { const [y, m, d] = s.split("-").map(Number); return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10); };
const end = addDays(today, 6);
const label = s => { const [y, m, d] = s.split("-").map(Number); return DOW[new Date(Date.UTC(y, m - 1, d)).getUTCDay()] + " " + MON[m - 1] + " " + d; };
const time = t => { if (!t) return "time TBA"; let [h, mi] = t.split(":").map(Number); const ap = h >= 12 ? "PM" : "AM"; h = h % 12 || 12; return h + ":" + String(mi).padStart(2, "0") + " " + ap; };

const shows = data.shows.filter(s => s.date >= today && s.date <= end)
  .sort((a, b) => a.date.localeCompare(b.date) || (a.doors || "99").localeCompare(b.doors || "99"));
const fests = (data.festivals || []).filter(f => f.start && f.start <= end && f.end >= today);

if (!shows.length && !fests.length) { console.log("No shows this week, nothing posted."); process.exit(0); }

const lines = [];
for (const f of fests) lines.push(`FESTIVAL: ${f.name} (${label(f.start)}${f.end !== f.start ? " to " + label(f.end) : ""}) in ${f.city}`);
let day = "";
for (const s of shows) {
  if (s.date !== day) { day = s.date; lines.push(""); lines.push(label(s.date)); }
  const extra = [s.status === "sold-out" ? "SOLD OUT" : s.status === "low" ? "low tickets" : "", s.price || ""].filter(Boolean).join(", ");
  lines.push(`- ${s.title}${s.tag ? " (" + s.tag + ")" : ""} @ ${s.venue}${s.city !== "Chicago" ? ", " + s.city : ""}, ${time(s.doors)}${extra ? " [" + extra + "]" : ""}`);
}
const header = `Bass shows this week, ${label(today)} to ${label(end)}`;
const footer = `\nFull calendar: ${SITE}`;

function build(limit) {
  let body = header + "\n";
  let used = 0;
  for (const l of lines) {
    if ((body + l + "\n" + footer).length > limit - 40) break;
    body += l + "\n"; used++;
  }
  const left = lines.filter(l => l.startsWith("- ")).length - lines.slice(0, used).filter(l => l.startsWith("- ")).length;
  if (left > 0) body += `+${left} more on the site\n`;
  return body + footer;
}

let failed = false;
const discord = process.env.DISCORD_WEBHOOK_URL;
if (discord) {
  const r = await fetch(discord, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ content: build(2000), allowed_mentions: { parse: [] } }) });
  console.log("Discord:", r.status); if (!r.ok) failed = true;
}
const groupme = process.env.GROUPME_BOT_ID;
if (groupme) {
  const r = await fetch("https://api.groupme.com/v3/bots/post", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ bot_id: groupme, text: build(1000) }) });
  console.log("GroupMe:", r.status); if (!r.ok) failed = true;
}
if (!discord && !groupme) { console.log("No DISCORD_WEBHOOK_URL or GROUPME_BOT_ID secret set. Preview:\n\n" + build(2000)); }
if (failed) process.exit(1);
