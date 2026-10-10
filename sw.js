/* Copia dell'app sul telefono: si apre anche senza campo.
   La pagina si prende sempre dalla rete se c'è (così gli aggiornamenti arrivano subito);
   senza rete si usa la copia. I dati di Supabase non passano mai di qui. */
const VERSIONE = "1bcdacc42b";
const CACHE = "ordini-" + VERSIONE;
const BASE = ["./", "manifest.webmanifest", "icone/icona-180.png", "icone/icona-192.png"];

self.addEventListener("install", function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(BASE); }).then(function(){ return self.skipWaiting(); }));
});
self.addEventListener("activate", function(e){
  e.waitUntil(caches.keys().then(function(nomi){
    return Promise.all(nomi.filter(function(n){ return n.indexOf("ordini-") === 0 && n !== CACHE; }).map(function(n){ return caches.delete(n); }));
  }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener("fetch", function(e){
  const r = e.request;
  if (r.method !== "GET") return;
  const u = new URL(r.url);
  if (/supabase\.co$/.test(u.hostname)) return;
  if (r.mode === "navigate"){
    e.respondWith(fetch(r).then(function(res){
      if (res.ok){ const copia = res.clone(); caches.open(CACHE).then(function(c){ c.put("./", copia); }); }
      return res;
    }).catch(function(){ return caches.match("./"); }));
    return;
  }
  const esterno = u.origin !== self.location.origin;
  if (esterno && !/cdn\.jsdelivr\.net$|fonts\.googleapis\.com$|fonts\.gstatic\.com$/.test(u.hostname)) return;
  e.respondWith(caches.match(r).then(function(c){
    if (c) return c;
    return fetch(r).then(function(res){
      if (res.ok || res.type === "opaque"){ const copia = res.clone(); caches.open(CACHE).then(function(cc){ cc.put(r, copia); }); }
      return res;
    });
  }));
});

/* notifiche: arrivano anche con l'app chiusa */
self.addEventListener("push", function(e){
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch(x){ d = { titolo: "Ordini", testo: e.data ? e.data.text() : "" }; }
  const vai = /^[a-z]+$/.test(d.vai || "") ? d.vai : "richieste";
  e.waitUntil(self.registration.showNotification(d.titolo || "Ordini · Profumo di Pane", {
    body: d.testo || "", tag: d.tag || undefined, icon: "icone/icona-192.png", badge: "icone/icona-192.png", data: { vai: vai }
  }));
});
/* toccando la notifica si apre l'app nella sezione giusta */
self.addEventListener("notificationclick", function(e){
  e.notification.close();
  const vai = (e.notification.data && e.notification.data.vai) || "richieste";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function(finestre){
    for (const f of finestre){
      if ("focus" in f){ f.postMessage({ vai: vai }); return f.focus(); }
    }
    return self.clients.openWindow("./?vai=" + vai);
  }));
});
