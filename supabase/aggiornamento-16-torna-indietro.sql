-- Torna indietro dall'aggiornamento 16: toglie le due funzioni e la colonna delle notifiche bloccate.
-- Si perde solo l'elenco di chi le aveva bloccate (si rifà da solo quando l'app si apre di nuovo).
drop function if exists public.notifiche_bloccate_persone();
drop function if exists public.segna_notifiche_bloccate(boolean);
alter table public.profili drop column if exists notifiche_bloccate;
