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

// toglie spazi, virgolette o testo incollato per sbaglio intorno a una chiave
export function pulisciChiave(v) {
  const pezzi = String(v || "").replace(/["'\s]+/g, " ").trim().split(" ");
  return pezzi[pezzi.length - 1] || "";
}

if (typeof Deno !== "undefined") {
  const { createClient } = await import("jsr:@supabase/supabase-js@2");
  const webpush = (await import("npm:web-push@3.6.7")).default;
  let chiaviOk = "";
  try {
    webpush.setVapidDetails("mailto:ordini@profumodipane.it", pulisciChiave(Deno.env.get("VAPID_PUBLICA")), pulisciChiave(Deno.env.get("VAPID_PRIVATA")));
    chiaviOk = "si";
  } catch (e) {
    chiaviOk = String(e && e.message || e);
    console.log("notifiche: chiavi VAPID non valide:", chiaviOk);
  }
  // chiavi del progetto: quelle nuove se ci sono, altrimenti quelle vecchie
  function chiaveDa(nomeNuove, nomeVecchia) {
    const grezzo = Deno.env.get(nomeNuove) || "";
    try {
      const d = JSON.parse(grezzo || "{}");
      const v = typeof d === "string" ? d : (d.default || Object.values(d)[0]);
      if (v) return String(v);
    } catch (_) { if (grezzo && !grezzo.trim().startsWith("{")) return grezzo.trim(); }
    return Deno.env.get(nomeVecchia) || "";
  }
  const URL_PROGETTO = Deno.env.get("SUPABASE_URL");
  const chiave = chiaveDa("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  const pubblica = chiaveDa("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
  console.log("notifiche: chiavi", chiave.slice(0, 9) || "nessuna", pubblica.slice(0, 14) || "nessuna");
  const db = createClient(URL_PROGETTO, chiave, { auth: { persistSession: false } });

  // chi sta chiamando: lo chiede al servizio di accesso con il suo "lasciapassare"
  async function chiEntra(token) {
    if (!token) return { errore: "manca il lasciapassare" };
    const res = await fetch(URL_PROGETTO + "/auth/v1/user", { headers: { apikey: pubblica || chiave, Authorization: "Bearer " + token } });
    if (!res.ok) return { errore: "accesso rifiutato (" + res.status + ")" };
    const u = await res.json().catch(() => null);
    return u && u.id ? { id: u.id } : { errore: "utente non trovato" };
  }

  async function manda(m) {
    try {
      await webpush.sendNotification(
        { endpoint: m.isc.endpoint, keys: { p256dh: m.isc.p256dh, auth: m.isc.auth } },
        JSON.stringify({ titolo: m.titolo, testo: m.testo, tag: m.tag }),
        { TTL: 6 * 3600, urgency: m.urgente ? "high" : "normal" },
      );
      return "";
    } catch (e) {
      const stato = e && e.statusCode;
      console.log("notifiche: invio non riuscito", stato, e && (e.body || e.message));
      // telefono che non c'è più (app tolta, notifiche spente): si cancella l'iscrizione
      if (stato === 404 || stato === 410) await db.from("iscrizioni").delete().eq("endpoint", m.isc.endpoint);
      return String(stato || (e && e.message) || "errore");
    }
  }

  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    try {
      if (chiaviOk !== "si") return risposta({ errore: "Chiavi delle notifiche non valide: " + chiaviOk }, 500);
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const chi = await chiEntra(token);
      if (!chi.id) { console.log("notifiche: non autorizzato,", chi.errore); return risposta({ errore: "Non autorizzato: " + chi.errore }, 401); }
      const mittente = chi.id;
      const { data: io, error: eProf } = await db.from("profili").select("attivo").eq("id", mittente).maybeSingle();
      if (eProf) { console.log("notifiche: database non raggiungibile,", eProf.message); return risposta({ errore: "Database: " + eProf.message }, 500); }
      if (!io || io.attivo === false) return risposta({ errore: "Non autorizzato: profilo non trovato" }, 401);

      const corpo = await req.json().catch(() => ({}));

      // prova: una notifica ai telefoni di chi la chiede
      if (corpo.prova === true) {
        const { data: miei } = await db.from("iscrizioni").select("endpoint,p256dh,auth").eq("utente", mittente);
        const errori = [];
        let inviate = 0;
        for (const isc of miei || []) {
          const e = await manda({ isc, titolo: "Prova riuscita ✓", testo: "Le notifiche arrivano su questo telefono.", tag: "prova-" + Date.now() });
          if (e) errori.push(e); else inviate++;
        }
        console.log("notifiche: prova", JSON.stringify({ telefoni: (miei || []).length, inviate, errori }));
        return risposta({ prova: true, telefoni: (miei || []).length, inviate, errori });
      }

      const eventi = await leggiEventi(db, Array.isArray(corpo.eventi) ? corpo.eventi : [], mittente, Date.now());
      if (!eventi.length) {
        console.log("notifiche: nessun evento valido", JSON.stringify(corpo.eventi || []));
        return risposta({ inviate: 0, motivo: "nessun evento" });
      }

      const [{ data: isc }, { data: prof }] = await Promise.all([
        db.from("iscrizioni").select("endpoint,p256dh,auth,utente,preferenze"),
        db.from("profili").select("id,ruolo,attivo"),
      ]);
      const ruoli = new Map((prof || []).filter((p) => p.attivo !== false).map((p) => [p.id, p.ruolo]));
      const iscrizioni = (isc || []).filter((i) => ruoli.has(i.utente)).map((i) => ({ ...i, ruolo: ruoli.get(i.utente) }));
      const messaggi = componi(eventi, iscrizioni, mittente);

      const esiti = await Promise.all(messaggi.map(manda));
      const inviate = esiti.filter((e) => !e).length;
      console.log("notifiche:", JSON.stringify({
        eventi: eventi.map((e) => e.tipo + ":" + e.voci.length), telefoni: iscrizioni.length,
        messaggi: messaggi.length, inviate, errori: esiti.filter(Boolean),
      }));
      return risposta({ inviate, messaggi: messaggi.length, telefoni: iscrizioni.length });
    } catch (e) {
      console.log("notifiche: errore", String(e && e.message || e));
      return risposta({ errore: String(e && e.message || e) }, 500);
    }
  });
}
