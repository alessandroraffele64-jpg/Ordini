# Ordini · Profumo di Pane

App interna per le richieste dei negozi (Corso, Piazza Nenni), il panificio e magazzino, il giro consegne e i biscotti.

- **Sito:** `index.html` e le icone, pubblicati con GitHub Pages.
- **Dati e accessi:** Supabase. Le regole di accesso sono in `supabase/setup.sql`: ognuno entra con nome e PIN, si registra con il codice del suo negozio e può cambiare solo le richieste che ha fatto lui.
- **Sorgente:** `sorgente/app.html` è l'app vera e propria; `sorgente/build.py` la trasforma nel sito.

Il codice è pubblico, i dati no: ordini, nomi e PIN stanno solo nel database e si vedono solo dopo l'accesso. I codici per registrarsi non sono in questo repository.

## Aggiornare

1. Modificare `sorgente/app.html`.
2. `python3 sorgente/build.py`
3. Caricare le modifiche: il sito si aggiorna da solo in circa un minuto.
