# Note per chi lavora su questo repository

- La sorgente è `sorgente/app.html`: una sola pagina HTML (stile, markup e script insieme) che funziona in tre modi:
  1. come pagina pubblicata su Claude (`window.claude` presente: archivio di Claude);
  2. come sito con Supabase (`SB_URL`/`SB_KEY` riempiti da `sorgente/build.py` leggendo `sorgente/config.json`);
  3. in modalità prova (nessuno dei due: dati solo in memoria).
- Dopo ogni modifica: `python3 sorgente/build.py`, poi commit di `sorgente/` **e** dei file generati (`index.html`, `icone/`, `manifest.webmanifest`).
- Non mettere mai nel repository i codici per registrarsi, la password del database o la chiave `service_role`/secret di Supabase. La chiave in `config.json` è quella pubblica (publishable/anon) ed è protetta dalle regole RLS in `supabase/setup.sql`.
- Testi e commenti in italiano: l'app la usano i dipendenti di una panetteria, la lingua deve restare semplice.
- Il proprietario non è un programmatore: spiegare le cose in parole semplici, senza gergo tecnico.
