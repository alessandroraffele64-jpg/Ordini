// @ts-nocheck
// Ordini · Profumo di Pane — funzione "notifiche" (Supabase Edge Function)
//
// L'app la chiama dopo aver salvato qualcosa (nuove richieste, "pronto", "non c'è",
// richieste da prendere in un altro negozio, "arrivata in magazzino", comande di biscotti, prenotazioni nuove o disdette,
// guasti segnalati e sistemati). La funzione rilegge dal database cosa è successo
// davvero (non si fida di quello che le arriva), decide chi deve saperlo e manda
// UNA notifica per invio, raggruppando le cose.
//
// Segreti da impostare in Supabase (Edge Functions → Secrets):
//   VAPID_PUBLICA  e  VAPID_PRIVATA  (le chiavi delle notifiche)
// SUPABASE_URL e le chiavi segrete del progetto ci sono già, li mette Supabase.

const RECENTE = 15 * 60 * 1000; // si notifica solo quello che è successo da poco
const NEGOZIO_DI_RUOLO = { "corso": "Corso", "piazza-nenni": "Piazza Nenni", "panificio": "Panificio" };
const PREP = { "Corso": "al Corso", "Piazza Nenni": "a Piazza Nenni", "Panificio": "al Panificio" };
const CHI = { "Corso": "Il Corso", "Piazza Nenni": "Piazza Nenni", "Panificio": "Il Panificio" };

function nomeCosa(d) {
  // nelle prenotazioni c'è anche il nome giusto del prodotto ("Pitta china" invece di "pitte chine")
  return ((d.quantita ? d.quantita + " " : "") + (d.prodotto || d.articolo || d.nome || "?")).trim();
}
function elenco(nomi) {
  if (nomi.length <= 3) return nomi.join(", ");
  return nomi.slice(0, 3).join(", ") + " e altre " + (nomi.length - 3);
}
// Le notifiche che si possono ricevere di solito, per posto (uguale a NOTIFICHE_PERMESSI in sorgente/app.html).
// Il titolare può darle o toglierle a una persona (impostazioni "permessi" → persone → notifiche: true / false).
// I titolari di solito le possono ricevere tutte (tranne nuovePanif, che per loro è già in "nuove"), e le
// scelgono una per una come gli altri; quelle tra un negozio e l'altro per loro sono in "altroNegozio".
const NOTIFICHE_DI_SOLITO = {
  nuove: ["consegne"], nuovePanif: ["panificio"], altroNegozio: ["negozio"], manca: ["negozio"],
  pronto: ["consegne"], arrivata: ["consegne"], magazzino: [],
  prenotazioni: ["negozio", "panificio"], disdette: ["negozio", "panificio"], biscotti: ["panificio"],
  guasti: [], guastoFatto: ["negozio", "panificio", "consegne"],
};
function tipoPosto(r) { return r === "corso" || r === "piazza-nenni" ? "negozio" : r; }
// la persona può ricevere questa notifica nel posto dove è?
export function permessa(isc, chiave) {
  const e = isc.notifPermessi;
  if (isc.ruolo === "titolare") {
    if (chiave === "nuovePanif") return false;
    return e && typeof e[chiave] === "boolean" ? e[chiave] : true;
  }
  if (e && typeof e[chiave] === "boolean") return e[chiave];
  return (NOTIFICHE_DI_SOLITO[chiave] || []).indexOf(tipoPosto(isc.ruolo)) >= 0;
}
// ...e sul suo telefono è accesa? Le notifiche dei dipendenti le decide solo il titolare (21 ottobre):
// se gliel'ha data arriva sempre, le scelte fatte sul telefono non contano. I titolari scelgono le loro
// (se non l'hanno mai scelta: com'era «Ricevi tutto», di partenza spento).
function vuole(isc, chiave) {
  if (!permessa(isc, chiave)) return false;
  if (isc.ruolo !== "titolare") return true;
  const p = isc.preferenze || {};
  let v = p[chiave];
  // «Nuove richieste da prendere al Panificio» prima si chiamava «nuove» per il panificio
  if (v === undefined && chiave === "nuovePanif" && isc.ruolo === "panificio") v = p.nuove;
  // i guasti (24 ottobre): ai titolari arrivano se non li hanno spenti (si decide nei permessi)
  if (v === undefined && isc.ruolo === "titolare" && chiave === "guasti") return true;
  if (v === undefined && isc.ruolo === "titolare") return p.tutto === true;
  return v === undefined ? true : v === true;
}
// I posti di una persona: il suo e quelli dati dal titolare (impostazioni "permessi" → persone → luoghi).
// Tra i negozi e il Panificio vale quello dove è adesso (preferenze.luogo, lo sceglie nell'app);
// il giro consegne, se ce l'ha con un altro posto, vale sempre insieme (le notifiche di tutti e due).
// Prima di «Dove lavora» il giro si dava con «Vedere il giro consegne» (consegne: true): vale come il posto.
const LUOGHI_LAVORO = ["corso", "piazza-nenni", "panificio"];
export function postiDiIscrizione(isc, ruolo, permessi) {
  if (ruolo === "titolare") return ["titolare"];
  const e = (permessi && permessi[isc.utente]) || {};
  const extra = Array.isArray(e.luoghi) ? e.luoghi : [];
  const luoghi = LUOGHI_LAVORO.filter((l) => l === ruolo || extra.indexOf(l) >= 0);
  const giro = ruolo === "consegne" || extra.indexOf("consegne") >= 0 || e.consegne === true;
  const scelto = isc.preferenze && isc.preferenze.luogo;
  const qui = luoghi.indexOf(scelto) >= 0 ? scelto : (luoghi.indexOf(ruolo) >= 0 ? ruolo : luoghi[0]);
  // prima il giro: per le nuove richieste riceve di più (tutte, non solo quelle del Panificio)
  const out = [];
  if (giro) out.push("consegne");
  if (qui) out.push(qui);
  return out.length ? out : [ruolo];
}
const NOME_POSTO = { "corso": "Corso", "piazza-nenni": "Piazza Nenni", "panificio": "Panificio", "consegne": "Giro" };
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
function giornoTesto(perIl, ora) {
  if (!perIl) return "";
  const oggi = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Rome" }).format(new Date(ora));
  if (perIl === oggi) return "oggi";
  if (perIl === domaniRoma(ora)) return "domani";
  return new Intl.DateTimeFormat("it-IT", { weekday: "long", day: "numeric", month: "long", timeZone: "Europe/Rome" }).format(new Date(perIl + "T12:00:00Z"));
}

// eventi: [{ tipo, voci: [{ id, autore, dati }] }]   iscrizioni: [{ endpoint, p256dh, auth, utente, ruolo, preferenze }]
// restituisce i messaggi da mandare: [{ isc, titolo, testo, tag, urgente }]
export function componi(eventi, iscrizioni, mittente, ruoloMittente) {
  const out = [];
  for (const isc of iscrizioni) {
    if (isc.utente === mittente) continue;
    const r = isc.ruolo;
    const tit = r === "titolare";
    // il negozio dove è (Corso o Piazza Nenni); per gli altri posti le notifiche date dal titolare valgono per tutti
    const mioNegozio = tipoPosto(r) === "negozio" ? NEGOZIO_DI_RUOLO[r] : "";
    for (const ev of eventi) {
      if (ev.tipo === "nuove") {
        const scelte = ev.voci.filter((v) => {
          const d = v.dati;
          if (d.per === "Promemoria" || d.tipo === "prenotazione" || d.tipo === "magazzino") return false;
          // ai titolari: quelle tra un negozio e l'altro solo con «Un negozio chiede qualcosa all'altro»
          if (tit) return (d.da === "Corso" || d.da === "Piazza Nenni") && d.per !== d.da ? vuole(isc, "altroNegozio") : vuole(isc, "nuove");
          // a chi fa il giro le urgenti arrivano sempre (se il titolare non gliele ha tolte)
          if (r === "consegne" && d.urgente === true && permessa(isc, "nuove")) return true;
          if (vuole(isc, "nuove")) return true;
          if (d.da === "Panificio" && vuole(isc, "nuovePanif")) return true;
          return false;
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
        // al negozio da cui si prende la cosa: "Il Corso chiede a voi: 50 Vassoi"
        // (a chi non è di un negozio e ha avuto questa notifica: quando un negozio chiede all'altro)
        if (!tit && vuole(isc, "altroNegozio")) {
          const daNoi = ev.voci.filter((v) => (mioNegozio ? v.dati.da === mioNegozio : (v.dati.da === "Corso" || v.dati.da === "Piazza Nenni")) &&
            v.dati.per !== v.dati.da && v.dati.per !== "Promemoria" && v.dati.tipo !== "prenotazione" && v.dati.tipo !== "magazzino");
          for (const [chi, vv] of perGruppo(daNoi, (v) => v.dati.per)) {
            const urg = vv.some((v) => v.dati.urgente === true);
            const ordinate = vv.slice().sort((a, b) => (b.dati.urgente ? 1 : 0) - (a.dati.urgente ? 1 : 0));
            out.push({ isc, titolo: (urg ? "⚠ URGENTE – " : "") + (CHI[chi] || chi) + (mioNegozio ? " chiede a voi" : " chiede " + (PREP[vv[0].dati.da] || "a " + vv[0].dati.da)),
              testo: elenco(ordinate.map((v) => nomeCosa(v.dati))), tag: "altro-" + chi + "-" + ev.quando, urgente: urg, vai: "richieste" });
          }
        }
      } else if (ev.tipo === "prenotazioni") {
        for (const v of ev.voci) {
          const d = v.dati;
          // in un negozio: quelle che si ritirano lì; al panificio e agli altri: tutte
          const ok = vuole(isc, "prenotazioni") && (!mioNegozio || mioNegozio === d.ritiro);
          if (!ok) continue;
          const cose = (Array.isArray(d.voci) ? d.voci : []).map((x) => nomeCosa(x));
          const quandoTesto = d.perIl ? new Intl.DateTimeFormat("it-IT", { weekday: "long", day: "numeric", month: "long", timeZone: "Europe/Rome" }).format(new Date(d.perIl + "T12:00:00Z")) : "";
          out.push({ isc, titolo: "Nuova prenotazione – " + (quandoTesto || "") + (d.tuttoGiorno ? ", tutta la giornata" : (d.ora ? " ore " + d.ora : "")),
            testo: elenco(cose) + " · ritiro " + (PREP[d.ritiro] || d.ritiro || "") + (d.cliente ? " · " + d.cliente : ""), tag: "pren-" + v.id, vai: "prenotazioni" });
        }
      } else if (ev.tipo === "disdetta") {
        // al negozio dove si ritira, se a disdire è stato qualcun altro; ai titolari che la vogliono
        for (const v of ev.voci) {
          const d = v.dati, st = v.st || {};
          // vale anche per il panificio, quando il cliente ritira lì
          // nei negozi e al panificio: quelle che si ritirano lì, disdette da qualcun altro; agli altri: tutte
          const posto = NEGOZIO_DI_RUOLO[r];
          const negozio = vuole(isc, "disdette") && (posto ? posto === d.ritiro && ruoloMittente !== r : true);
          if (!negozio) continue;
          const cose = (Array.isArray(d.voci) ? d.voci : []).map((x) => nomeCosa(x));
          const g = giornoTesto(d.perIl, ev.quando);
          out.push({ isc, titolo: "Prenotazione disdetta – ritiro " + (PREP[d.ritiro] || d.ritiro || ""),
            testo: "Disdetta: " + elenco(cose) + (g ? " per " + g : "") + (d.cliente ? " · " + d.cliente : "") + (st.disdettaMotivo ? " · " + st.disdettaMotivo : ""),
            tag: "disd-" + v.id, vai: "prenotazioni" });
        }
      } else if (ev.tipo === "arrivata") {
        // una cosa che mancava è arrivata in magazzino: a chi fa il giro e ai titolari che la vogliono
        if (!vuole(isc, "arrivata")) continue;
        for (const [neg, vv] of perGruppo(ev.voci, (v) => v.dati.per)) {
          const nomi = vv.map((v) => v.dati.articolo || "?");
          const una = nomi.length === 1;
          out.push({ isc, titolo: (una ? "Arrivata" : "Arrivate") + " in magazzino – per " + neg,
            testo: elenco(nomi) + (una ? " è arrivata" : " sono arrivate") + " in magazzino: da portare " + (PREP[neg] || "a " + neg),
            tag: "arrivata-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "magazzino") {
        // cose segnate come finite in magazzino (da chi fa il giro o da un titolare): ai titolari che la vogliono
        if (!vuole(isc, "magazzino")) continue;
        const nomi = ev.voci.map((v) => v.dati.articolo || "?");
        out.push({ isc, titolo: "Finito in magazzino", testo: elenco(nomi) + (nomi.length === 1 ? " è finito" : " sono finiti") + " in magazzino: da ordinare",
          tag: "magazzino-" + ev.quando, vai: "mancanti" });
      } else if (ev.tipo === "pronto") {
        if (!vuole(isc, "pronto")) continue;
        for (const [neg, vv] of perGruppo(ev.voci, (v) => v.dati.per)) {
          out.push({ isc, titolo: "Pronto da caricare – per " + neg, testo: elenco(vv.map((v) => nomeCosa(v.dati))), tag: "pronto-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "manca") {
        const scelte = ev.voci.filter((v) =>
          (vuole(isc, "manca") && (!mioNegozio || mioNegozio === v.dati.per)) ||
          // le proprie richieste: sempre, se il titolare non gliel'ha tolta
          (v.autore === isc.utente && !tit && !(isc.notifPermessi && isc.notifPermessi.manca === false)));
        for (const [neg, vv] of perGruppo(scelte, (v) => v.dati.per)) {
          out.push({ isc, titolo: "Non c'è in magazzino – per " + neg, testo: elenco(vv.map((v) => nomeCosa(v.dati))), tag: "manca-" + neg + "-" + ev.quando });
        }
      } else if (ev.tipo === "guasti") {
        // un guasto segnalato: ai titolari (e a chi l'ha avuta dal titolare), un messaggio per guasto
        if (!vuole(isc, "guasti")) continue;
        for (const v of ev.voci) {
          const d = v.dati;
          const urg = d.urgenza === "subito";
          const testa = urg ? "🔴 URGENTE" : d.urgenza === "quando" ? "🟢 Guasto, quando si può" : "🟠 Guasto, da sistemare presto";
          out.push({ isc, titolo: testa + " · " + (d.dove || "?"), testo: String(d.articolo || "?").slice(0, 200), tag: "guasto-" + v.id, urgente: urg, vai: "guasti" });
        }
      } else if (ev.tipo === "guastoFatto") {
        // un guasto sistemato: solo a chi l'ha segnalato (se il titolare non gliel'ha tolta)
        for (const v of ev.voci) {
          if (v.autore !== isc.utente || tit || !permessa(isc, "guastoFatto")) continue;
          out.push({ isc, titolo: "Guasto sistemato ✓ · " + (v.dati.dove || ""), testo: String(v.dati.articolo || "?").slice(0, 200), tag: "guasto-fatto-" + v.id, vai: "guasti" });
        }
      // "partite" non si manda più (tolta l'11 ottobre)
      } else if (ev.tipo === "biscotti") {
        if (!vuole(isc, "biscotti")) continue;
        for (const [neg, vv] of perGruppo(ev.voci, (v) => v.dati.negozio)) {
          const finiti = vv.filter((v) => v.dati.livello === "finiti");
          const pochi = vv.filter((v) => v.dati.livello !== "finiti");
          const titolo = "Biscotti – " + neg + (finiti.length ? ": " + contaCose(finiti.length, "finito", "finiti") : "") + (pochi.length ? (finiti.length ? ", " : ": ") + pochi.length + " con pochi pacchi" : "");
          const nomi = finiti.concat(pochi).map((v) => v.dati.nome || "?");
          out.push({ isc, titolo, testo: elenco(nomi), tag: "biscotti-" + neg + "-" + ev.quando, urgente: finiti.length > 0, vai: "biscotti" });
        }
      }
    }
  }
  return out;
}

// chi lavora al giro e in un altro posto: le notifiche di tutti e due, ognuna una volta sola,
// con il nome del posto davanti ("Giro · …", "Panificio · …")
export function componiPerPosti(eventi, iscrizioni, mittente, ruoloMittente) {
  const out = [];
  const visti = new Set();
  for (const i of iscrizioni) {
    const posti = i.posti && i.posti.length ? i.posti : [i.ruolo];
    for (const ruolo of posti) {
      for (const m of componi(eventi, [{ ...i, ruolo }], mittente, ruoloMittente)) {
        const chiave = i.endpoint + "|" + m.tag;
        if (visti.has(chiave)) continue;
        visti.add(chiave);
        if (posti.length > 1) m.titolo = (NOME_POSTO[ruolo] || ruolo) + " · " + m.titolo;
        out.push(m);
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
    } else if (e.tipo === "magazzino") {
      const { data } = await db.from("richieste").select("id,autore,dati,creato").in("id", ids).eq("autore", mittente);
      const voci = (data || []).filter((x) => recente(x.creato) && x.dati && x.dati.tipo === "magazzino" && !x.dati.annullato)
        .map((x) => ({ id: x.id, autore: x.autore, dati: x.dati }));
      if (voci.length) eventi.push({ tipo: "magazzino", voci, quando: ora });
    } else if (e.tipo === "guasti") {
      const { data } = await db.from("richieste").select("id,autore,dati,creato").in("id", ids).eq("autore", mittente);
      const voci = (data || []).filter((x) => recente(x.creato) && x.dati && x.dati.tipo === "guasto" && !x.dati.annullato)
        .map((x) => ({ id: x.id, autore: x.autore, dati: x.dati }));
      if (voci.length) eventi.push({ tipo: "guasti", voci, quando: ora });
    } else if (e.tipo === "guastoFatto") {
      const { data: st } = await db.from("stati").select("id,dati,aggiornato").in("id", ids);
      const ok = (st || []).filter((x) => x.dati && Number(x.dati.sistematoAlle) > 0 && recente(x.aggiornato));
      if (!ok.length) continue;
      const rids = ok.map((x) => x.id.split("~")[1]).filter(Boolean);
      const { data: rr } = await db.from("richieste").select("id,autore,dati").in("id", rids);
      const voci = (rr || []).filter((x) => x.dati && x.dati.tipo === "guasto" && !x.dati.annullato).map((x) => ({ id: x.id, autore: x.autore, dati: x.dati }));
      if (voci.length) eventi.push({ tipo: "guastoFatto", voci, quando: ora });
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
    } else if (e.tipo === "arrivata") {
      const { data: st } = await db.from("stati").select("id,dati,aggiornato").in("id", ids);
      const ok = (st || []).filter((x) => x.dati && !x.dati.prep && x.dati.arrivatoAlle && recente(x.aggiornato) && recente(new Date(Number(x.dati.arrivatoAlle)).toISOString()));
      if (!ok.length) continue;
      const rids = ok.map((x) => x.id.split("~")[1]).filter(Boolean);
      const { data: rr } = await db.from("richieste").select("id,autore,dati").in("id", rids);
      const voci = (rr || []).filter((x) => !(x.dati && x.dati.annullato) && !(x.dati && x.dati.tipo === "magazzino")).map((x) => ({ id: x.id, autore: x.autore, dati: x.dati || {} }));
      if (voci.length) eventi.push({ tipo: "arrivata", voci, quando: ora });
    } else if (e.tipo === "disdetta") {
      const { data: st } = await db.from("stati").select("id,dati,aggiornato").in("id", ids);
      const ok = (st || []).filter((x) => x.dati && x.dati.disdetta === true && x.dati.disdettaDa === mittente && recente(x.aggiornato));
      if (!ok.length) continue;
      const perRid = new Map(ok.map((x) => [x.id.split("~")[1], x.dati]));
      const { data: rr } = await db.from("richieste").select("id,autore,dati").in("id", Array.from(perRid.keys()).filter(Boolean));
      const voci = (rr || []).filter((x) => x.dati && x.dati.tipo === "prenotazione" && !x.dati.annullato)
        .map((x) => ({ id: x.id, autore: x.autore, dati: x.dati, st: perRid.get(x.id) }));
      if (voci.length) eventi.push({ tipo: "disdetta", voci, quando: ora });
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

  // prova del 28 ottobre: tutte le notifiche partono «importanti» (i telefoni Android le consegnano subito
  // anche a schermo spento), tranne quelle di Massimo, per confrontare i ritardi. Dopo la prova si toglie.
  const SENZA_IMPORTANTI = new Set(["fcdd92b3-a4cb-4783-9966-6138da48da1d"]);

  async function manda(m) {
    const importante = m.urgente || !SENZA_IMPORTANTI.has(m.isc.utente);
    try {
      await webpush.sendNotification(
        { endpoint: m.isc.endpoint, keys: { p256dh: m.isc.p256dh, auth: m.isc.auth } },
        JSON.stringify({ titolo: m.titolo, testo: m.testo, tag: m.tag, vai: m.vai || "richieste" }),
        { TTL: 6 * 3600, urgency: importante ? "high" : "normal" },
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
      const { data: io, error: eProf } = await db.from("profili").select("*").eq("id", mittente).maybeSingle();
      if (eProf) { console.log("notifiche: database non raggiungibile,", eProf.message); return risposta({ errore: "Database: " + eProf.message }, 500); }
      if (!io || io.attivo === false || io.sospeso === true) return risposta({ errore: "Non autorizzato: profilo non trovato" }, 401);

      const corpo = await req.json().catch(() => ({}));

      // prova: una notifica ai telefoni di chi la chiede
      if (corpo.prova === true) {
        const { data: miei } = await db.from("iscrizioni").select("endpoint,p256dh,auth,utente").eq("utente", mittente);
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

      const [{ data: isc }, { data: prof }, { data: imp }] = await Promise.all([
        db.from("iscrizioni").select("endpoint,p256dh,auth,utente,preferenze"),
        db.from("profili").select("*"),
        db.from("impostazioni").select("dati").eq("chiave", "permessi"),
      ]);
      // chi è azzerato o sospeso non riceve niente
      const ruoli = new Map((prof || []).filter((p) => p.attivo !== false && p.sospeso !== true).map((p) => [p.id, p.ruolo]));
      const permessi = (imp && imp[0] && imp[0].dati && imp[0].dati.persone) || {};
      const iscrizioni = (isc || []).filter((i) => ruoli.has(i.utente)).map((i) => {
        const e = permessi[i.utente];
        return { ...i, posti: postiDiIscrizione(i, ruoli.get(i.utente), permessi), notifPermessi: (e && e.notifiche) || null };
      });
      const messaggi = componiPerPosti(eventi, iscrizioni, mittente, ruoli.get(mittente) || "");

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
