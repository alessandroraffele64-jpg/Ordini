-- =====================================================================
--  Aggiornamento 10 · registro con il nome di chi fa le cose
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati.
--  Va lanciato dopo l'aggiornamento 7.
--
--  Deciso dal proprietario il 19 ottobre: nel registro di come si usa l'app
--  c'è anche il NOME della persona (prima solo "Persona 1", "Persona 2"…)
--  e il posto dove era in quel momento (Corso, Piazza Nenni, Panificio…),
--  così si vede chi ha bisogno di aiuto per usare meglio l'app.
--  Si tiene almeno 3 mesi (di partenza 6, si sceglie nelle Impostazioni).
--  Lo leggono solo il proprietario (qui, dal database) e Claude: dall'app nessuno lo legge.
--  Come prima non registra mai quello che si scrive (clienti, telefoni, cose chieste, note).
--  L'app scrive qui solo quando REGISTRO_ATTIVO = true in sorgente/app.html (alla partenza vera).
--
--  Per leggerlo:  select quando, nome, posto, evento, schermata, dati from registro order by quando;
-- =====================================================================

alter table public.registro add column if not exists nome text;
alter table public.registro add column if not exists posto text;

create or replace function public.registra(eventi jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  r text;
  chi text;
  e jsonb;
  mesi integer;
begin
  if not public.ha_profilo() then return; end if;
  if jsonb_typeof(eventi) <> 'array' then return; end if;
  insert into public.registro_persone (utente) values (auth.uid()) on conflict (utente) do nothing;
  select numero into n from public.registro_persone where utente = auth.uid();
  select case ruolo when 'consegne' then 'giro' else ruolo end, nome into r, chi from public.profili where id = auth.uid();
  for e in select * from jsonb_array_elements(eventi) limit 200 loop
    insert into public.registro (quando, persona, nome, ruolo, posto, evento, schermata, dati)
    values (
      case when (e->>'t') ~ '^[0-9]{10,14}$' then to_timestamp((e->>'t')::bigint / 1000.0) else now() end,
      'Persona ' || n, left(chi, 60), coalesce(r, '?'),
      left(e->>'p', 30),
      left(coalesce(e->>'e', '?'), 40),
      left(e->>'s', 40),
      case when jsonb_typeof(e->'d') = 'object' and length((e->'d')::text) <= 2000 then e->'d' else '{}'::jsonb end
    );
  end loop;
  -- dopo i mesi scelti (di partenza 6, mai meno di 3) si cancella da solo
  select case when (dati->>'registroMesi') ~ '^[0-9]{1,2}$' then least(24, greatest(3, (dati->>'registroMesi')::integer)) end
    into mesi from public.impostazioni where chiave = 'numeri';
  delete from public.registro where creato < now() - make_interval(months => greatest(3, coalesce(mesi, 6)));
end $$;
revoke all on function public.registra(jsonb) from public, anon;
grant execute on function public.registra(jsonb) to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
