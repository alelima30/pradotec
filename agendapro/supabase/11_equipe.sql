-- ===========================================================================
-- AgendaPro — 11: dar login para a equipe
--
-- O banco já sabia lidar com `recepcao` e `profissional`: as policies estão
-- escritas desde o 02_rls.sql, e a policy `vinc_gerir` até deixa o dono criar
-- vínculo no próprio salão. O que faltava era o CAMINHO.
--
-- ── POR QUE UM CONVITE, E NÃO UM CAMPO DE E-MAIL ───────────────────────────
-- Para criar o vínculo é preciso o `perfil_id` da pessoa. O dono não tem como
-- descobrir esse id: `perfis` tem RLS, e cada um só enxerga o próprio. E é
-- para continuar assim — um campo "digite o e-mail e eu procuro" seria uma
-- porta para descobrir quem tem conta na plataforma, um e-mail por vez.
--
-- No convite quem traz o `perfil_id` é a PRÓPRIA PESSOA, ao aceitar logada.
-- O dono nunca precisa saber o id de ninguém, e a plataforma não vira lista
-- telefônica.
--
-- ── O LINK VAI PELO WHATSAPP, NÃO POR E-MAIL ───────────────────────────────
-- Não há servidor de e-mail neste projeto, e não vale inventar um para isto:
-- o dono já manda o link do salão pelo WhatsApp o dia inteiro. O convite é
-- mais um link, no mesmo canal, com o mesmo gesto.
--
-- Isso tem uma consequência de segurança que o desenho leva em conta: um link
-- que circula no WhatsApp pode ser encaminhado. Por isso ele é de UM USO SÓ,
-- vence em 7 dias, e dá para revogar antes disso.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) O CONVITE
-- ---------------------------------------------------------------------------
create table if not exists public.convites_equipe (
  id         uuid primary key default gen_random_uuid(),
  salao_id   uuid not null references public.saloes(id) on delete cascade,

  -- O papel que a pessoa vai ter. `cliente` não entra: para ser cliente
  -- basta abrir o link do salão, e `dono` não se convida — transferir a casa
  -- é outra operação, com outras perguntas.
  papel      text not null check (papel in ('admin','recepcao','profissional')),

  -- Só um rótulo, para o dono saber de quem é o convite na lista. Não é
  -- usado para achar ninguém, e não precisa bater com nada.
  para_quem  text,

  -- O segredo do link. Índice único porque é por ele que se entra.
  token      uuid not null default gen_random_uuid(),

  expira_em  timestamptz not null default now() + interval '7 days',
  usado_em   timestamptz,
  usado_por  uuid references public.perfis(id) on delete set null,
  revogado_em timestamptz,

  criado_por uuid references public.perfis(id) on delete set null,
  criado_em  timestamptz not null default now()
);

create unique index if not exists ux_convite_token on public.convites_equipe(token);
create index if not exists ix_convite_salao on public.convites_equipe(salao_id, criado_em desc);

alter table public.convites_equipe enable row level security;
alter table public.convites_equipe force row level security;

drop policy if exists conv_gerir on public.convites_equipe;
create policy conv_gerir on public.convites_equipe for all to authenticated
  using ( public.e_gestor(salao_id) ) with check ( public.e_gestor(salao_id) );

-- `anon` não lê esta tabela nem por acidente: quem tiver acesso a ela tem
-- todos os tokens do sistema, e cada token é uma cadeira dentro de um salão.
revoke all on public.convites_equipe from anon;
grant select, insert, update, delete on public.convites_equipe to authenticated;

-- ---------------------------------------------------------------------------
-- 2) CRIAR
-- ---------------------------------------------------------------------------
create or replace function public.criar_convite(
  p_salao uuid, p_papel text, p_para_quem text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_token uuid;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só quem administra o salão pode convidar.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_papel not in ('admin','recepcao','profissional') then
    raise exception 'Papel inválido para convite.' using errcode = 'check_violation';
  end if;

  insert into public.convites_equipe (salao_id, papel, para_quem, criado_por)
       values (p_salao, p_papel,
               nullif(btrim(coalesce(p_para_quem, '')), ''), auth.uid())
    returning token into v_token;

  return jsonb_build_object('token', v_token);
end $$;

-- ---------------------------------------------------------------------------
-- 3) O QUE A PESSOA CONVIDADA VÊ ANTES DE ENTRAR
--
-- Chamável por quem NÃO fez login: é a página do convite, e ela precisa dizer
-- de que salão se trata antes de pedir a conta. Devolve o mínimo — nome do
-- salão e papel — e nada mais. Nem quem convidou, nem quem já é da equipe,
-- nem o id de coisa nenhuma.
--
-- Token inválido e token vencido dão a MESMA resposta genérica de propósito:
-- distinguir os dois diria a quem está tentando adivinhar que ele acertou o
-- formato e errou só a validade.
-- ---------------------------------------------------------------------------
create or replace function public.ver_convite(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c public.convites_equipe%rowtype;
  s public.saloes%rowtype;
begin
  select * into c from public.convites_equipe where token = p_token;
  if c.id is null
     or c.usado_em is not null
     or c.revogado_em is not null
     or c.expira_em < now() then
    return jsonb_build_object('valido', false);
  end if;

  select * into s from public.saloes where id = c.salao_id;
  if s.id is null or s.status <> 'ativo' then
    return jsonb_build_object('valido', false);
  end if;

  return jsonb_build_object(
    'valido', true,
    'salao',  s.nome,
    'tipo',   s.tipo,
    'logo',   s.logo,
    'papel',  c.papel,
    'paraQuem', c.para_quem);
end $$;

-- ---------------------------------------------------------------------------
-- 4) ACEITAR
--
-- Quem aceita é sempre `auth.uid()`. Não há parâmetro de "para quem" — se
-- houvesse, um convite vazado viraria a chance de colocar OUTRA pessoa
-- dentro do salão.
-- ---------------------------------------------------------------------------
create or replace function public.aceitar_convite(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.convites_equipe%rowtype;
  v_eu uuid := auth.uid();
begin
  if v_eu is null then
    raise exception 'Entre na sua conta para aceitar o convite.'
      using errcode = 'insufficient_privilege';
  end if;

  /* `for update` trava a linha até o fim desta transação. Sem isso, dois
     cliques no mesmo instante — ou o mesmo link aberto em dois aparelhos —
     passariam os dois pela conferência de "já foi usado" antes de qualquer um
     marcar. O convite é de um uso só, e quem garante isso é esta linha. */
  select * into c from public.convites_equipe where token = p_token for update;

  if c.id is null
     or c.usado_em is not null
     or c.revogado_em is not null
     or c.expira_em < now() then
    raise exception 'Este convite não vale mais. Peça outro ao salão.'
      using errcode = 'check_violation';
  end if;

  -- Já é da casa: não cria de novo, e não estraga o convite de quem ainda
  -- vai usar. Acontece quando a pessoa abre o link duas vezes.
  if exists (select 1 from public.vinculos v
              where v.perfil_id = v_eu and v.salao_id = c.salao_id
                and v.papel = c.papel and v.status = 'ativo') then
    return jsonb_build_object('ok', true, 'jaEra', true, 'salaoId', c.salao_id);
  end if;

  insert into public.vinculos (perfil_id, salao_id, papel, status)
       values (v_eu, c.salao_id, c.papel, 'ativo')
  on conflict (perfil_id, salao_id, papel)
    do update set status = 'ativo';

  update public.convites_equipe
     set usado_em = now(), usado_por = v_eu
   where id = c.id;

  return jsonb_build_object('ok', true, 'salaoId', c.salao_id, 'papel', c.papel);
end $$;

-- ---------------------------------------------------------------------------
-- 5) QUEM TEM ACESSO
--
-- A lista que o painel mostra. `security definer` porque precisa ler `perfis`
-- de outras pessoas — e por isso devolve só o que o dono precisa ver para
-- administrar: nome, papel e desde quando. O e-mail NÃO vai junto: ele é a
-- chave de login da pessoa, e não é preciso para tirar o acesso dela.
-- ---------------------------------------------------------------------------
create or replace function public.equipe_com_acesso(p_salao uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'perfilId', p.id,
             'nome',     p.nome,
             'papel',    v.papel,
             'desde',    v.criado_em,
             'souEu',    p.id = auth.uid())
           order by array_position(
             array['dono','admin','recepcao','profissional'], v.papel), p.nome)
      from public.vinculos v
      join public.perfis p on p.id = v.perfil_id
     where v.salao_id = p_salao
       and v.status = 'ativo'
       and v.papel <> 'cliente'), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 6) TIRAR O ACESSO
--
-- Duas recusas, e as duas evitam um salão sem dono:
--   · ninguém tira o próprio acesso de dono (ficaria de fora da própria casa,
--     sem caminho de volta pela tela);
--   · não se tira o ÚLTIMO dono, mesmo sendo outra pessoa a fazer isso.
--
-- Tirar o acesso NÃO apaga a ficha de profissional nem o histórico: são
-- coisas diferentes. Quem sai da equipe para de entrar no sistema; os
-- atendimentos que ela fez continuam no caixa do salão.
-- ---------------------------------------------------------------------------
create or replace function public.remover_acesso(
  p_salao uuid, p_perfil uuid, p_papel text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_donos int;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só quem administra o salão pode mexer nos acessos.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_papel = 'dono' then
    if p_perfil = auth.uid() then
      raise exception 'Você não pode tirar o próprio acesso de dono.'
        using errcode = 'check_violation';
    end if;
    select count(*) into v_donos from public.vinculos
     where salao_id = p_salao and papel = 'dono' and status = 'ativo';
    if v_donos <= 1 then
      raise exception 'Este é o único dono do salão. Passe a titularidade antes.'
        using errcode = 'check_violation';
    end if;
  end if;

  delete from public.vinculos
   where salao_id = p_salao and perfil_id = p_perfil and papel = p_papel;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 7) REVOGAR UM CONVITE QUE AINDA NÃO FOI USADO
-- ---------------------------------------------------------------------------
create or replace function public.revogar_convite(p_convite uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.convites_equipe%rowtype;
begin
  select * into c from public.convites_equipe where id = p_convite;
  if c.id is null or not public.e_gestor(c.salao_id) then
    raise exception 'Convite não encontrado.' using errcode = 'insufficient_privilege';
  end if;
  update public.convites_equipe set revogado_em = now()
   where id = c.id and usado_em is null and revogado_em is null;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- 8) PERMISSÕES
--
-- `ver_convite` é a única que `anon` alcança, e é por desenho: a página do
-- convite precisa dizer de que salão se trata ANTES de a pessoa ter conta.
-- Ela devolve nome do salão e papel, nada mais.
-- ---------------------------------------------------------------------------
revoke all on function public.criar_convite(uuid, text, text)   from public;
revoke all on function public.ver_convite(uuid)                 from public;
revoke all on function public.aceitar_convite(uuid)             from public;
revoke all on function public.equipe_com_acesso(uuid)           from public;
revoke all on function public.remover_acesso(uuid, uuid, text)  from public;
revoke all on function public.revogar_convite(uuid)             from public;

grant execute on function public.criar_convite(uuid, text, text)  to authenticated;
grant execute on function public.ver_convite(uuid)                to anon, authenticated;
grant execute on function public.aceitar_convite(uuid)            to authenticated;
grant execute on function public.equipe_com_acesso(uuid)          to authenticated;
grant execute on function public.remover_acesso(uuid, uuid, text) to authenticated;
grant execute on function public.revogar_convite(uuid)            to authenticated;
