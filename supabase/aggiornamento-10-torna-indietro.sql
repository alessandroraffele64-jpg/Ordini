-- =====================================================================
--  Torna indietro dall'aggiornamento 10 (registro con i nomi)
--  Da usare SOLO se l'aggiornamento 10 dà problemi.
--  Rimette la funzione «registra» com'era prima (solo «Persona 1», «Persona 2»…).
--  Le colonne «nome» e «posto» restano (vuote nelle righe nuove): togliendole
--  si perderebbero i nomi già salvati, quindi non si tolgono.
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
-- =====================================================================

create or replace function public.registra(eventi jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  r text;
  e jsonb;
  mesi integer;
begin
  if not public.ha_profilo() then return; end if;
  if jsonb_typeof(eventi) <> 'array' then return; end if;
  insert into public.registro_persone (utente) values (auth.uid()) on conflict (utente) do nothing;
  select numero into n from public.registro_persone where utente = auth.uid();
  select case ruolo when 'consegne' then 'giro' else ruolo end into r from public.profili where id = auth.uid();
  for e in select * from jsonb_array_elements(eventi) limit 200 loop
    insert into public.registro (quando, persona, ruolo, evento, schermata, dati)
    values (
      case when (e->>'t') ~ '^[0-9]{10,14}$' then to_timestamp((e->>'t')::bigint / 1000.0) else now() end,
      'Persona ' || n, coalesce(r, '?'),
      left(coalesce(e->>'e', '?'), 40),
      left(e->>'s', 40),
      case when jsonb_typeof(e->'d') = 'object' and length((e->'d')::text) <= 2000 then e->'d' else '{}'::jsonb end
    );
  end loop;
  -- dopo i mesi scelti (di partenza 6) si cancella da solo
  select case when (dati->>'registroMesi') ~ '^[0-9]{1,2}$' then least(24, greatest(1, (dati->>'registroMesi')::integer)) end
    into mesi from public.impostazioni where chiave = 'numeri';
  delete from public.registro where creato < now() - make_interval(months => coalesce(mesi, 6));
end $$;
revoke all on function public.registra(jsonb) from public, anon;
grant execute on function public.registra(jsonb) to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
