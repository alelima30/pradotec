-- ===========================================================================
-- Deixa o banco como a instalação de verdade está HOJE: sem o módulo de
-- campanhas, e com os auxiliares de permissão na versão que devolve NULL.
-- Carregado por tests/rodar.sh, nunca sozinho.
--
-- Sem desfazer, o banco de teste nasce com tudo já certo — e o 98_campanhas
-- passaria na conferência mesmo se fosse um arquivo vazio.
-- ===========================================================================

\set ON_ERROR_STOP on

drop table if exists public.campanha_destinatarios cascade;
drop table if exists public.campanhas cascade;
alter table public.clientes drop column if exists aceita_marketing;
alter table public.clientes drop column if exists marketing_saiu_em;

drop function if exists public.publico_da_campanha(uuid, text, text, int, uuid[]) cascade;
drop function if exists public.montar_fila(uuid, text, int, uuid[]) cascade;
drop function if exists public.iniciar_campanha(uuid) cascade;
drop function if exists public.cancelar_campanha(uuid) cascade;
drop function if exists public.placar_campanha(uuid) cascade;
drop function if exists public.fila_proxima(int) cascade;
drop function if exists public.fila_resultado(uuid, boolean, text, text, text, boolean) cascade;

-- Os auxiliares como eram antes: sem `coalesce`, devolvendo NULL para quem
-- não tem vínculo. É o estado em que a instalação de produção está agora.
create or replace function public.e_equipe(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super()
      or papel_no_salao(p_salao) in ('dono','admin','recepcao','profissional')
$$;

create or replace function public.e_gestor(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) in ('dono','admin')
$$;
