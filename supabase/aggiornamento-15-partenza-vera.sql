-- =====================================================================
--  Aggiornamento 15 · partenza vera (28 ottobre 2026 sera)
--  Incollare in Supabase → SQL Editor → Run, con la manutenzione accesa.
--  Deciso dal proprietario: NON si cancellano richieste, prenotazioni, cose segnate,
--  guasti, correzioni dei nomi. Le statistiche contano solo dal 29 ottobre (STAT_DAL nell'app).
--  Questo script fa solo due cose:
--   1. rimette a 0 il contatore «quante volte è stato chiesto» di tutti i biscotti
--      (volte, volteFiniti): è l'unico numero delle statistiche che non guarda il giorno di partenza.
--      Stato, negozio, nome, chi l'ha chiesto e quando restano come sono.
--   2. toglie «Prova Claude», la persona di prova (non ha mai scritto niente) e il suo codice.
--  Per tornare indietro: aggiornamento-15-torna-indietro.sql (con i numeri di prima).
-- =====================================================================

update public.biscotti
   set dati = dati || jsonb_build_object('volte', 0, 'volteFiniti', 0)
 where coalesce((dati->>'volte')::int, 0) <> 0 or coalesce((dati->>'volteFiniti')::int, 0) <> 0;

delete from public.codici_persona where persona = '1d720083-53c6-4cbf-87b4-0361ebba1e67';
delete from public.profili where id = '1d720083-53c6-4cbf-87b4-0361ebba1e67' and nome = 'Prova Claude';

-- Fatto. Deve comparire "Success. No rows returned".
