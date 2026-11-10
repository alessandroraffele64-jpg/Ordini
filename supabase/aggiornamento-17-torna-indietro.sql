-- Torna indietro dall'aggiornamento 17: toglie le due funzioni e la colonna delle notifiche spente da sole.
-- L'app continua a funzionare: semplicemente il titolare non vede più la scritta rossa.
drop function if exists public.notifiche_perse_persone();
drop function if exists public.segna_notifiche_perse(boolean);
alter table public.profili drop column if exists notifiche_perse;
