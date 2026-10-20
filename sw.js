const SHELL = "basschi-shell-2026-10-20-morepics";
const DATA = "basschi-data";
const FONTS = "basschi-fonts";
const SHELL_FILES = ["./", "index.html", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png", "share.png", "qr.js"];
self.addEventListener("install", e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k.startsWith("basschi-shell-") && k !== SHELL).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
const networkFirst = (req, cacheName) => fetch(req).then(res => {
  if (res.ok) { const copy = res.clone(); caches.open(cacheName).then(c => c.put(req, copy)); }
  return res;
}).catch(() => caches.match(req, { ignoreSearch: true }));
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  if (url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com") {
    e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request).then(res => { const copy = res.clone(); caches.open(FONTS).then(c => c.put(e.request, copy)); return res; })));
    return;
  }
  if (url.origin !== location.origin) return;
  if (url.pathname.endsWith("data.json")) { e.respondWith(networkFirst(e.request, DATA)); return; }
  if (e.request.mode === "navigate") { e.respondWith(networkFirst(e.request, SHELL).then(r => r || caches.match("index.html"))); return; }
  e.respondWith(caches.match(e.request).then(hit => hit || networkFirst(e.request, SHELL)));
});
