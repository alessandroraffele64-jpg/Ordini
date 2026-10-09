// @ts-nocheck
// Ordini · Profumo di Pane — funzione "notifiche" (Supabase Edge Function)
//
// L'app la chiama dopo aver salvato qualcosa (nuove richieste, "pronto", "non c'è",
// "partite", comande di biscotti). La funzione rilegge dal database cosa è successo
// davvero (non si fida di quello che le arriva), decide chi deve saperlo e manda
// UNA notifica per invio, raggruppando le cose.
//
// Segreti da impostare in Supabase (Edge Functions → Secrets):
//   VAPID_PUBLICA  e  VAPID_PRIVATA  (le chiavi delle notifiche)
// SUPABASE_URL e le chiavi segrete del progetto ci sono già, li mette Supabase.

const RECENTE = 15 * 60 * 1000; // si notifica solo quello che è successo da poco
const NEGOZIO_DI_RUOLO = { "corso": "Corso", "piazza-nenni": "Piazza Nenni", "panificio": "Panificio" };
const PREP = { "Corso": "al Corso", "Piazza Nenni": "a Piazza Nenni", "Panificio": "al Panificio" };

function nomeCosa(d) {
  return ((d.quantita ? d.quantita + " " : "") + (d.articolo || d.nome || "?")).trim();
}
function elenco(nomi) {
  if (nomi.length <= 3) return nomi.join(", ");
  return nomi.slice(0, 3).join(", ") + " e altre " + (nomi.length - 3);
}
function vuole(isc, chiave, normale) {
  const p = isc.preferenze || {};
  return p[chiave] === undefined ? normale : p[chiave] === true;
}
function perGruppo(voci, chiave) {
  const m = new Map();
  for (const v of voci) {
    const k = chiave(v);
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(v);
  }
  return m;
}
function contaCose(n, una, tante) { return n === 1 ? "1 " + una : n + " " + tante; }

// eventi: [{ tipo, voci: [{ id, autore, dati }] }]   iscrizioni: [{ endpoint, p256dh, auth, utente, ruolo, preferenze }]
// restituisce i messaggi da mandare: [{ isc, titolo, testo, tag, urgente }]
export function componi(eventi, iscrizioni, mittente) {
  const out = [];
  for (const isc of iscrizioni) {
    if (isc.utente === mittente) continue;
    const r = isc.ruolo;
    const tutto = r === "titolare" && vuole(isc, "tutto", false);
    for (const ev of eventi) {
      if (ev.tipo === "nuove") {
        const scelte = ev.voci.filter((v) => {
          const d = v.dati;
          if (d.per === "Promemoria" || d.tipo === "prenotazione") return false;
          if (r === "consegne") return d.urgente === true || vuole(isc, "nuove", true); // gli urgenti arrivano sempre
          if (r === "panificio") return d.da === "Panificio" && vuole(isc, "nuove", true);
          return tutto;
        });
        for (const [neg, vv] of perGruppo(scelte, (v) => v.dati.per)) {
          const n = vv.length;
          const urg = vv.filter((v) => v.dati.urgente === true).length;
          const ordinate = vv.slice().sort((a, b) => (b.dati.urgente ? 1 : 0) - (a.dati.urgente ? 1 : 0));
          const titolo = urg
            ? "⚠ URGENTE – " + neg + ", " + contaCose(n, "richiesta", "richieste") + (n > 1 ? " (" + contaCose(urg, "urgente", "urgenti") + ")" : "")
            : neg + " – " + contaCose(n, "nuova richiesta", "nuove richieste");
          out.push({ isc, titolo, testo: elenco(ordinate.map((v) => nomeCosa(v.dati))), tag: "nuove-" + neg + "-" + ev.quando, urgente: urg > 0 });
        }
      } else if (ev.tipo === "prenotazioni") {
        for (const v of ev.voci) {
          const d = v.dati;
          const ok = (r === "panificio" && vuole(isc, "prenotazioni", true)) ||
            (NEGOZIO_DI_RUOLO[r] === d.ritiro && r !== "panificio" && vuole(isc, "prenotazioni", true)) || tutto;
          if (!ok) continue;
          const cose = (Array.isArray(d.voci) ? d.voci : []).map((x) => nomeCosa(x));
          const quandoTesto = d.perIl ? new Intl.DateTimeFormat("it-IT", { weekday: "long", day: "numeric", month: "long", timeZone: "Europe/Rome" }).format(new Date(d.perIl + "T12:00:00Z")) : "";
          out.push({ isc, titolo: "Nuova prenotazione – " + (quandoTesto || "") + (d.ora ? " ore " + d.ora : ""),
            testo: elenco(cose) + " · ritiro " + (PREP[d.ritiro] || d.ritiro || "") + (d.cliente ? " · " + d.cliente : ""), tag: "pren-" + v.id });
        }
      } else if (ev.tipo === "pronto") {
        if (!((r === "consegne" && vuole(isc, "pronto", true)) || tutto)) continue;
        for (const [neg, vv] of perGruppo(ev.voci, (v) => v.dati.per)) {
          out.push({ isc, titolo: "Pronto da caricare – per " + neg, testo: elenco(vv.map((v) => nomeCosa(v.dati))), tag: "pronto-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "manca") {
        const scelte = ev.voci.filter((v) =>
          (NEGOZIO_DI_RUOLO[r] === v.dati.per && vuole(isc, "manca", true)) || v.autore === isc.utente || tutto);
        for (const [neg, vv] of perGruppo(scelte, (v) => v.dati.per)) {
          out.push({ isc, titolo: "Non c'è in magazzino – per " + neg, testo: elenco(vv.map((v) => nomeCosa(v.dati))), tag: "manca-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "partite") {
        const scelte = ev.voci.filter((v) => NEGOZIO_DI_RUOLO[r] === v.dati.per && vuole(isc, "partite", true));
        for (const [neg, vv] of perGruppo(scelte, (v) => v.dati.per)) {
          out.push({ isc, titolo: "In arrivo " + (PREP[neg] || "a " + neg), testo: elenco(vv.map((v) => nomeCosa(v.dati))), tag: "partite-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "biscotti") {
        if (!((r === "panificio" && vuole(isc, "biscotti", true)) || tutto)) continue;
        for (const [neg, vv] of perGruppo(ev.voci, (v) => v.dati.negozio)) {
          const finiti = vv.filter((v) => v.dati.livello === "finiti");
          const pochi = vv.filter((v) => v.dati.livello !== "finiti");
          const titolo = "Biscotti – " + neg + (finiti.length ? ": " + contaCose(finiti.length, "finito", "finiti") : "") + (pochi.length ? (finiti.length ? ", " : ": ") + pochi.length + " con pochi pacchi" : "");
          const nomi = finiti.concat(pochi).map((v) => v.dati.nome || "?");
          out.push({ isc, titolo, testo: elenco(nomi), tag: "biscotti-" + neg + "-" + ev.quando, urgente: finiti.length > 0 });
        }
      }
    }
  }
  return out;
}

function domaniRoma(ora) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Rome" }).format(new Date(ora + 86400000));
}

// rilegge dal database cosa è successo davvero
export async function leggiEventi(db, richiesti, mittente, ora) {
  const eventi = [];
  const recente = (t) => t && ora - new Date(t).getTime() < RECENTE;
  for (const e of richiesti.slice(0, 10)) {
    const ids = Array.from(new Set((e.ids || []).filter((x) => typeof x === "string"))).slice(0, 100);
    if (!ids.length) continue;
    if (e.tipo === "prenotazioni") {
      const { data } = await db.from("richieste").select("id,autore,dati,creato").in("id", ids).eq("autore", mittente);
      const voci = (data || []).filter((x) => recente(x.creato) && x.dati && x.dati.tipo === "prenotazione" && !x.dati.annullato)
        .map((x) => ({ id: x.id, autore: x.autore, dati: x.dati }));
      if (voci.length) eventi.push({ tipo: "prenotazioni", voci, quando: ora });
    } else if (e.tipo === "nuove") {
      const { data } = await db.from("richieste").select("id,autore,dati,creato").in("id", ids).eq("autore", mittente);
      const domani = domaniRoma(ora);
      const voci = (data || []).filter((x) => recente(x.creato) && !(x.dati && x.dati.annullato) && !(x.dati && x.dati.tipo === "prenotazione") && !(x.dati && x.dati.perIl && x.dati.perIl > domani))
        .map((x) => ({ id: x.id, autore: x.autore, dati: x.dati || {} }));
      if (voci.length) eventi.push({ tipo: "nuove", voci, quando: ora });
    } else if (e.tipo === "pronto" || e.tipo === "manca" || e.tipo === "partite") {
      const { data: st } = await db.from("stati").select("id,dati,aggiornato").in("id", ids);
      const ok = (st || []).filter((x) => {
        const d = x.dati || {};
        if (!recente(x.aggiornato)) return false;
        if (e.tipo === "pronto") return d.prep === "pronto";
        if (e.tipo === "manca") return d.prep === "manca";
        return d.stato === "caricato";
      });
      if (!ok.length) continue;
      const rids = ok.map((x) => x.id.split("~")[1]).filter(Boolean);
      const { data: rr } = await db.from("richieste").select("id,autore,dati").in("id", rids);
      const voci = (rr || []).filter((x) => !(x.dati && x.dati.annullato)).map((x) => ({ id: x.id, autore: x.autore, dati: x.dati || {} }));
      if (voci.length) eventi.push({ tipo: e.tipo, voci, quando: ora });
    } else if (e.tipo === "biscotti") {
      const { data } = await db.from("biscotti").select("id,dati,aggiornato").in("id", ids);
      const voci = (data || []).filter((x) => recente(x.aggiornato) && x.dati && x.dati.stato === "manca")
        .map((x) => ({ id: x.id, autore: x.dati.segnatoDa, dati: x.dati }));
      if (voci.length) eventi.push({ tipo: "biscotti", voci, quando: ora });
    }
  }
  return eventi;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function risposta(dati, stato = 200) {
  return new Response(JSON.stringify(dati), { status: stato, headers: { ...CORS, "Content-Type": "application/json" } });
}

if (typeof Deno !== "undefined") {
  const { createClient } = await import("jsr:@supabase/supabase-js@2");
  const webpush = (await import("npm:web-push@3.6.7")).default;
  webpush.setVapidDetails("mailto:ordini@profumodipane.it", Deno.env.get("VAPID_PUBLICA"), Deno.env.get("VAPID_PRIVATA"));
  // chiave segreta del progetto: quella nuova se c'è, altrimenti quella vecchia
  let chiave = "";
  try { const d = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"); chiave = d.default || Object.values(d)[0] || ""; } catch (_) { /* niente */ }
  if (!chiave) chiave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const db = createClient(Deno.env.get("SUPABASE_URL"), chiave, { auth: { persistSession: false } });

  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    try {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = await db.auth.getUser(token);
      const mittente = u && u.user && u.user.id;
      if (!mittente) return risposta({ errore: "Non autorizzato" }, 401);
      const { data: io } = await db.from("profili").select("attivo").eq("id", mittente).maybeSingle();
      if (!io || io.attivo === false) return risposta({ errore: "Non autorizzato" }, 401);

      const corpo = await req.json().catch(() => ({}));
      const eventi = await leggiEventi(db, Array.isArray(corpo.eventi) ? corpo.eventi : [], mittente, Date.now());
      if (!eventi.length) return risposta({ inviate: 0 });

      const [{ data: isc }, { data: prof }] = await Promise.all([
        db.from("iscrizioni").select("endpoint,p256dh,auth,utente,preferenze"),
        db.from("profili").select("id,ruolo,attivo"),
      ]);
      const ruoli = new Map((prof || []).filter((p) => p.attivo !== false).map((p) => [p.id, p.ruolo]));
      const iscrizioni = (isc || []).filter((i) => ruoli.has(i.utente)).map((i) => ({ ...i, ruolo: ruoli.get(i.utente) }));
      const messaggi = componi(eventi, iscrizioni, mittente);

      let inviate = 0;
      await Promise.all(messaggi.map(async (m) => {
        try {
          await webpush.sendNotification(
            { endpoint: m.isc.endpoint, keys: { p256dh: m.isc.p256dh, auth: m.isc.auth } },
            JSON.stringify({ titolo: m.titolo, testo: m.testo, tag: m.tag }),
            { TTL: 6 * 3600, urgency: m.urgente ? "high" : "normal" },
          );
          inviate++;
        } catch (e) {
          // telefono che non c'è più (app tolta, notifiche spente): si cancella l'iscrizione
          if (e && (e.statusCode === 404 || e.statusCode === 410)) await db.from("iscrizioni").delete().eq("endpoint", m.isc.endpoint);
        }
      }));
      return risposta({ inviate });
    } catch (e) {
      return risposta({ errore: String(e && e.message || e) }, 500);
    }
  });
}
