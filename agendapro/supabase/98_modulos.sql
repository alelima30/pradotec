create or replace function public.tem_acesso(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_super() or papel_no_salao(p_salao) is not null, false)
$$;

create or replace function public.e_equipe(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_super()
      or papel_no_salao(p_salao) in ('dono','admin','recepcao','profissional'), false)
$$;

create or replace function public.e_gestor(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_super() or papel_no_salao(p_salao) in ('dono','admin'), false)
$$;

create or replace function public.ve_agenda_toda(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_super() or papel_no_salao(p_salao) in ('dono','admin','recepcao'), false)
$$;

alter table public.clientes
  add column if not exists aceita_marketing boolean not null default true;
alter table public.clientes
  add column if not exists marketing_saiu_em timestamptz;
create table if not exists public.campanhas (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  nome          text not null check (length(btrim(nome)) between 2 and 120),
  tipo          text not null default 'promocao'
                check (tipo in ('promocao','lembrete','confirmacao','aniversario',
                                'ausente','retorno','aviso','personalizada')),
  corpo         text,
  template_nome text,
  template_idioma text not null default 'pt_BR',
  status        text not null default 'rascunho'
                check (status in ('rascunho','agendada','processando','concluida',
                                  'cancelada','concluida_com_falhas')),
  agendada_para timestamptz,
  intervalo_min int not null default 5  check (intervalo_min between 3 and 300),
  intervalo_max int not null default 12 check (intervalo_max between 3 and 600),
  check (intervalo_max >= intervalo_min),
  iniciada_em   timestamptz,
  concluida_em  timestamptz,
  criada_por    uuid references public.perfis(id) on delete set null,
  criada_em     timestamptz not null default now(),
  check (coalesce(nullif(btrim(template_nome), ''), nullif(btrim(corpo), '')) is not null)
);
create index if not exists ix_camp_salao on public.campanhas(salao_id, criada_em desc);
create index if not exists ix_camp_rodando on public.campanhas(status)
  where status = 'processando';
create table if not exists public.campanha_destinatarios (
  id            uuid primary key default gen_random_uuid(),
  campanha_id   uuid not null references public.campanhas(id) on delete cascade,
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  telefone      text not null,
  status        text not null default 'pendente'
                check (status in ('pendente','processando','enviado','falhou','cancelado')),
  tentativas    smallint not null default 0 check (tentativas >= 0),
  proxima_em    timestamptz,
  tentado_em    timestamptz,
  enviado_em    timestamptz,
  erro_codigo   text,
  erro_msg      text,
  wam_id        text,
  criado_em     timestamptz not null default now(),
  constraint ux_camp_dest unique (campanha_id, cliente_id)
);
create index if not exists ix_dest_camp on public.campanha_destinatarios(campanha_id, status);
create index if not exists ix_dest_fila
  on public.campanha_destinatarios(campanha_id, criado_em)
  where status = 'pendente';
alter table public.campanhas               enable row level security;
alter table public.campanha_destinatarios  enable row level security;
alter table public.campanhas               force row level security;
alter table public.campanha_destinatarios  force row level security;
drop policy if exists camp_ler    on public.campanhas;
drop policy if exists camp_gerir  on public.campanhas;
drop policy if exists dest_ler    on public.campanha_destinatarios;
drop policy if exists dest_gerir  on public.campanha_destinatarios;
create policy camp_ler on public.campanhas
  for select using ( public.e_equipe(salao_id) );
create policy camp_gerir on public.campanhas
  for all using ( public.e_gestor(salao_id) )
       with check ( public.e_gestor(salao_id) );
create policy dest_ler on public.campanha_destinatarios
  for select using ( public.e_equipe(salao_id) );
create policy dest_gerir on public.campanha_destinatarios
  for all using ( public.e_gestor(salao_id) )
       with check ( public.e_gestor(salao_id) );
revoke all on public.campanhas              from anon;
revoke all on public.campanha_destinatarios from anon;
grant select, insert, update, delete on public.campanhas              to authenticated;
grant select, insert, update, delete on public.campanha_destinatarios to authenticated;
create or replace function public.publico_da_campanha(
  p_salao   uuid,
  p_tipo    text default 'promocao',
  p_criterio text default 'todos',
  p_dias    int  default 90,
  p_ids     uuid[] default null)
returns table (cliente_id uuid, nome text, telefone text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.id, c.nome, c.telefone
    from public.clientes c
   where c.salao_id = p_salao
     and public.so_digitos(c.telefone) is not null
     and (p_tipo <> 'promocao' or c.aceita_marketing)
     and case p_criterio
           when 'selecionados' then c.id = any(coalesce(p_ids, '{}'::uuid[]))
           when 'sumidos' then not exists (
             select 1 from public.agendamentos a
              where a.cliente_id = c.id
                and a.arquivado_em is null
                and a.status = 'concluido'
                and a.inicio > now() - make_interval(days => greatest(p_dias, 1)))
           when 'aniversario' then
             c.nascimento is not null
             and to_char(c.nascimento, 'MM-DD')
               = to_char(public.hoje_no_salao(p_salao), 'MM-DD')
           when 'faltaram' then exists (
             select 1 from public.agendamentos a
              where a.cliente_id = c.id
                and a.arquivado_em is null
                and a.status = 'faltou'
                and a.inicio > now() - make_interval(days => greatest(p_dias, 1)))
           else true
         end
   order by c.nome;
end $$;
revoke all on function public.publico_da_campanha(uuid, text, text, int, uuid[]) from public;
grant execute on function public.publico_da_campanha(uuid, text, text, int, uuid[])
  to authenticated;
create or replace function public.montar_fila(
  p_campanha uuid,
  p_criterio text default 'todos',
  p_dias     int  default 90,
  p_ids      uuid[] default null)
returns int
language plpgsql security definer set search_path = public as $$
declare
  c public.campanhas%rowtype;
  n int;
begin
  select * into c from public.campanhas where id = p_campanha;
  if c.id is null or not public.e_gestor(c.salao_id) then
    raise exception 'Campanha não encontrada.' using errcode = 'insufficient_privilege';
  end if;
  if c.status <> 'rascunho' then
    raise exception 'Esta campanha já saiu do rascunho.' using errcode = 'check_violation';
  end if;
  insert into public.campanha_destinatarios (campanha_id, salao_id, cliente_id, telefone)
  select c.id, c.salao_id, p.cliente_id, public.so_digitos(p.telefone)
    from public.publico_da_campanha(c.salao_id, c.tipo, p_criterio, p_dias, p_ids) p
  on conflict (campanha_id, cliente_id) do nothing;
  select count(*) into n from public.campanha_destinatarios where campanha_id = c.id;
  return n;
end $$;
revoke all on function public.montar_fila(uuid, text, int, uuid[]) from public;
grant execute on function public.montar_fila(uuid, text, int, uuid[]) to authenticated;
create or replace function public.iniciar_campanha(p_campanha uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.campanhas%rowtype;
  n int;
begin
  select * into c from public.campanhas where id = p_campanha;
  if c.id is null or not public.e_gestor(c.salao_id) then
    raise exception 'Campanha não encontrada.' using errcode = 'insufficient_privilege';
  end if;
  if c.status not in ('rascunho','agendada') then
    raise exception 'Esta campanha já foi iniciada.' using errcode = 'check_violation';
  end if;
  select count(*) into n from public.campanha_destinatarios
   where campanha_id = c.id and status = 'pendente';
  if n = 0 then
    raise exception 'Nenhum destinatário na fila.' using errcode = 'check_violation';
  end if;
  update public.campanhas
     set status = 'processando', iniciada_em = now()
   where id = c.id;
  return jsonb_build_object('ok', true, 'pendentes', n);
end $$;
create or replace function public.cancelar_campanha(p_campanha uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.campanhas%rowtype;
  n int;
begin
  select * into c from public.campanhas where id = p_campanha;
  if c.id is null or not public.e_gestor(c.salao_id) then
    raise exception 'Campanha não encontrada.' using errcode = 'insufficient_privilege';
  end if;
  if c.status in ('concluida','concluida_com_falhas','cancelada') then
    raise exception 'Esta campanha já terminou.' using errcode = 'check_violation';
  end if;
  update public.campanha_destinatarios
     set status = 'cancelado'
   where campanha_id = c.id and status = 'pendente';
  get diagnostics n = row_count;
  update public.campanhas
     set status = 'cancelada', concluida_em = now()
   where id = c.id;
  return jsonb_build_object('ok', true, 'cancelados', n);
end $$;
revoke all on function public.iniciar_campanha(uuid)  from public;
revoke all on function public.cancelar_campanha(uuid) from public;
grant execute on function public.iniciar_campanha(uuid)  to authenticated;
grant execute on function public.cancelar_campanha(uuid) to authenticated;
create or replace function public.placar_campanha(p_campanha uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c public.campanhas%rowtype;
begin
  select * into c from public.campanhas where id = p_campanha;
  if c.id is null or not public.e_equipe(c.salao_id) then
    raise exception 'Campanha não encontrada.' using errcode = 'insufficient_privilege';
  end if;
  return (
    select jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'status', c.status, 'tipo', c.tipo,
      'iniciadaEm', c.iniciada_em, 'concluidaEm', c.concluida_em,
      'corpo', c.corpo, 'template', c.template_nome,
      'total',      count(*),
      'enviadas',   count(*) filter (where d.status = 'enviado'),
      'falhas',     count(*) filter (where d.status = 'falhou'),
      'pendentes',  count(*) filter (where d.status in ('pendente','processando')),
      'cancelados', count(*) filter (where d.status = 'cancelado'),
      'ultimoEnvio', max(d.enviado_em))
      from public.campanha_destinatarios d where d.campanha_id = c.id);
end $$;
revoke all on function public.placar_campanha(uuid) from public;
grant execute on function public.placar_campanha(uuid) to authenticated;
create or replace function public.fila_proxima(p_lote int default 1)
returns table (
  destinatario_id uuid, campanha_id uuid, telefone text,
  nome text, salao text, corpo text, template_nome text, template_idioma text,
  tentativas smallint, intervalo_min int, intervalo_max int)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with alvo as (
    select d.id
      from public.campanha_destinatarios d
      join public.campanhas c on c.id = d.campanha_id
     where d.status = 'pendente'
       and c.status = 'processando'
       and (d.proxima_em is null or d.proxima_em <= now())
     order by d.criado_em
     for update of d skip locked
     limit greatest(coalesce(p_lote, 1), 1)
  ),
  tomados as (
    update public.campanha_destinatarios d
       set status = 'processando',
           tentativas = d.tentativas + 1,
           tentado_em = now()
      from alvo a
     where d.id = a.id
     returning d.*
  )
  select t.id, t.campanha_id, t.telefone,
         cl.nome, s.nome, c.corpo, c.template_nome, c.template_idioma,
         t.tentativas, c.intervalo_min, c.intervalo_max
    from tomados t
    join public.campanhas c  on c.id  = t.campanha_id
    join public.clientes  cl on cl.id = t.cliente_id
    join public.saloes    s  on s.id  = t.salao_id;
end $$;
create or replace function public.fila_resultado(
  p_destinatario uuid,
  p_ok           boolean,
  p_wam_id       text default null,
  p_erro_codigo  text default null,
  p_erro_msg     text default null,
  p_permanente   boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.campanha_destinatarios%rowtype;
begin
  select * into d from public.campanha_destinatarios where id = p_destinatario;
  if d.id is null then return; end if;
  if p_ok then
    update public.campanha_destinatarios
       set status = 'enviado', enviado_em = now(), wam_id = p_wam_id,
           erro_codigo = null, erro_msg = null, proxima_em = null
     where id = d.id;
  elsif p_permanente or d.tentativas >= 3 then
    update public.campanha_destinatarios
       set status = 'falhou', erro_codigo = p_erro_codigo,
           erro_msg = left(coalesce(p_erro_msg, ''), 500), proxima_em = null
     where id = d.id;
  else
    update public.campanha_destinatarios
       set status = 'pendente', erro_codigo = p_erro_codigo,
           erro_msg = left(coalesce(p_erro_msg, ''), 500),
           proxima_em = now() + make_interval(secs => 30 * power(4, d.tentativas - 1))
     where id = d.id;
  end if;
  update public.campanhas c
     set status = case
           when exists (select 1 from public.campanha_destinatarios x
                         where x.campanha_id = c.id and x.status = 'falhou')
             then 'concluida_com_falhas' else 'concluida' end,
         concluida_em = now()
   where c.id = d.campanha_id
     and c.status = 'processando'
     and not exists (select 1 from public.campanha_destinatarios x
                      where x.campanha_id = c.id
                        and x.status in ('pendente','processando'));
end $$;
revoke all on function public.fila_proxima(int) from public;
revoke all on function public.fila_resultado(uuid, boolean, text, text, text, boolean)
  from public;
grant execute on function public.fila_proxima(int) to service_role;
grant execute on function public.fila_resultado(uuid, boolean, text, text, text, boolean)
  to service_role;

create table if not exists public.convites_equipe (
  id         uuid primary key default gen_random_uuid(),
  salao_id   uuid not null references public.saloes(id) on delete cascade,
  papel      text not null check (papel in ('admin','recepcao','profissional')),
  para_quem  text,
  profissional_id uuid references public.profissionais(id) on delete cascade,
  token      uuid not null default gen_random_uuid(),
  expira_em  timestamptz not null default now() + interval '7 days',
  usado_em   timestamptz,
  usado_por  uuid references public.perfis(id) on delete set null,
  revogado_em timestamptz,
  criado_por uuid references public.perfis(id) on delete set null,
  criado_em  timestamptz not null default now()
);
alter table public.convites_equipe
  add column if not exists profissional_id uuid
  references public.profissionais(id) on delete cascade;
create unique index if not exists ux_convite_token on public.convites_equipe(token);
create index if not exists ix_convite_salao on public.convites_equipe(salao_id, criado_em desc);
alter table public.convites_equipe enable row level security;
alter table public.convites_equipe force row level security;
drop policy if exists conv_gerir on public.convites_equipe;
create policy conv_gerir on public.convites_equipe for all to authenticated
  using ( public.e_gestor(salao_id) ) with check ( public.e_gestor(salao_id) );
revoke all on public.convites_equipe from anon;
grant select, insert, update, delete on public.convites_equipe to authenticated;
drop function if exists public.criar_convite(uuid, text, text);
create or replace function public.criar_convite(
  p_salao uuid, p_papel text, p_para_quem text default null,
  p_profissional uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_token uuid;
  pr public.profissionais%rowtype;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só quem administra o salão pode convidar.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_papel not in ('admin','recepcao','profissional') then
    raise exception 'Papel inválido para convite.' using errcode = 'check_violation';
  end if;
  if p_papel = 'profissional' then
    if p_profissional is null then
      raise exception 'Escolha de quem é a agenda. Cadastre a pessoa em Equipe antes de dar o login.'
        using errcode = 'check_violation';
    end if;
    select * into pr from public.profissionais where id = p_profissional;
    if pr.id is null or pr.salao_id <> p_salao then
      raise exception 'Esta agenda não é deste salão.' using errcode = 'check_violation';
    end if;
    if pr.perfil_id is not null then
      raise exception 'A agenda de % já tem login.', pr.nome
        using errcode = 'check_violation';
    end if;
  else
    p_profissional := null;
  end if;
  insert into public.convites_equipe
         (salao_id, papel, para_quem, profissional_id, criado_por)
       values (p_salao, p_papel,
               nullif(btrim(coalesce(p_para_quem, '')), ''),
               p_profissional, auth.uid())
    returning token into v_token;
  return jsonb_build_object('token', v_token);
end $$;
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
  select * into c from public.convites_equipe where token = p_token for update;
  if c.id is null
     or c.usado_em is not null
     or c.revogado_em is not null
     or c.expira_em < now() then
    raise exception 'Este convite não vale mais. Peça outro ao salão.'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.vinculos v
              where v.perfil_id = v_eu and v.salao_id = c.salao_id
                and v.papel = c.papel and v.status = 'ativo') then
    return jsonb_build_object('ok', true, 'jaEra', true, 'salaoId', c.salao_id);
  end if;
  insert into public.vinculos (perfil_id, salao_id, papel, status)
       values (v_eu, c.salao_id, c.papel, 'ativo')
  on conflict (perfil_id, salao_id, papel)
    do update set status = 'ativo';
  if c.papel = 'profissional' and c.profissional_id is not null then
    update public.profissionais
       set perfil_id = v_eu
     where id = c.profissional_id and salao_id = c.salao_id
       and perfil_id is null;
  end if;
  update public.convites_equipe
     set usado_em = now(), usado_por = v_eu
   where id = c.id;
  return jsonb_build_object('ok', true, 'salaoId', c.salao_id, 'papel', c.papel);
end $$;
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
revoke all on function public.criar_convite(uuid, text, text, uuid) from public;
revoke all on function public.ver_convite(uuid)                 from public;
revoke all on function public.aceitar_convite(uuid)             from public;
revoke all on function public.equipe_com_acesso(uuid)           from public;
revoke all on function public.remover_acesso(uuid, uuid, text)  from public;
revoke all on function public.revogar_convite(uuid)             from public;
grant execute on function public.criar_convite(uuid, text, text, uuid) to authenticated;
grant execute on function public.ver_convite(uuid)                to anon, authenticated;
grant execute on function public.aceitar_convite(uuid)            to authenticated;
grant execute on function public.equipe_com_acesso(uuid)          to authenticated;
grant execute on function public.remover_acesso(uuid, uuid, text) to authenticated;
grant execute on function public.revogar_convite(uuid)            to authenticated;

create or replace function public.relatorio(
  p_salao uuid, p_de date, p_ate date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_fuso  text;
  v_ini   timestamptz;
  v_fim   timestamptz;
  v_dias  int;
  v_ini_a timestamptz;
  v_fim_a timestamptz;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Confira as datas do período.' using errcode = 'check_violation';
  end if;
  select fuso into v_fuso from public.saloes where id = p_salao;
  v_fuso := coalesce(v_fuso, 'America/Sao_Paulo');
  v_ini := (p_de::timestamp) at time zone v_fuso;
  v_fim := ((p_ate + 1)::timestamp) at time zone v_fuso;
  v_dias  := (p_ate - p_de) + 1;
  v_fim_a := v_ini;
  v_ini_a := v_ini - make_interval(days => v_dias);
  return jsonb_build_object(
    'de',  p_de,
    'ate', p_ate,
    'dias', v_dias,
    'faturamento', coalesce((
      select round(sum(t.total), 2) from public.comandas_totais t
        join public.comandas c on c.id = t.id
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim), 0),
    'atendimentos', (
      select count(*) from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim),
    'descontos', coalesce((
      select round(sum(c.desconto), 2) from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim), 0),
    'faturamentoAntes', coalesce((
      select round(sum(t.total), 2) from public.comandas_totais t
        join public.comandas c on c.id = t.id
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini_a and c.fechada_em < v_fim_a), 0),
    'formas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'forma', f.forma, 'valor', f.valor, 'taxa', f.taxa)
             order by f.valor desc)
        from (select pg.forma,
                     round(sum(pg.valor), 2) as valor,
                     round(sum(pg.taxa), 2)  as taxa
                from public.pagamentos pg
                join public.comandas c on c.id = pg.comanda_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by pg.forma) f), '[]'::jsonb),
    'comissoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'profissionalId', x.pid, 'nome', x.nome,
               'vendido', x.vendido, 'comissao', x.comissao,
               'itens', x.itens)
             order by x.comissao desc)
        from (select i.profissional_id as pid,
                     coalesce(pr.apelido, pr.nome, 'sem profissional') as nome,
                     round(sum(i.total), 2)          as vendido,
                     round(sum(i.comissao_valor), 2) as comissao,
                     count(*)                        as itens
                from public.comanda_itens i
                join public.comandas c on c.id = i.comanda_id
                left join public.profissionais pr on pr.id = i.profissional_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by i.profissional_id, coalesce(pr.apelido, pr.nome, 'sem profissional')) x),
      '[]'::jsonb),
    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', y.nome, 'qtd', y.qtd, 'valor', y.valor)
             order by y.valor desc)
        from (select i.descricao as nome,
                     round(sum(i.qtd), 2)   as qtd,
                     round(sum(i.total), 2) as valor
                from public.comanda_itens i
                join public.comandas c on c.id = i.comanda_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by i.descricao
               order by 3 desc limit 12) y), '[]'::jsonb),
    'agenda', (
      select jsonb_build_object(
        'concluidos', count(*) filter (where a.status = 'concluido'),
        'faltas',     count(*) filter (where a.status = 'faltou'),
        'cancelados', count(*) filter (where a.status = 'cancelado'),
        'marcados',   count(*),
        'perdido', coalesce(round(sum(a.valor_previsto)
                     filter (where a.status in ('faltou','cancelado')), 2), 0))
        from public.agendamentos a
       where a.salao_id = p_salao
         and a.arquivado_em is null
         and a.inicio >= v_ini and a.inicio < v_fim),
    'clientes', (
      select jsonb_build_object(
        'atendidas', count(distinct c.cliente_id),
        'novas', count(distinct c.cliente_id) filter (
          where not exists (
            select 1 from public.comandas c2
             where c2.cliente_id = c.cliente_id
               and c2.salao_id = p_salao
               and c2.status = 'fechada'
               and c2.fechada_em < v_ini)))
        from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim)
  );
end $$;
revoke all on function public.relatorio(uuid, date, date) from public;
grant execute on function public.relatorio(uuid, date, date) to authenticated;

create table if not exists public.cobrancas (
  id          uuid primary key default gen_random_uuid(),
  salao_id    uuid not null references public.saloes(id) on delete cascade,
  plano       text not null references public.planos(codigo),
  valor       numeric(10,2) not null check (valor > 0),
  metodo      text not null check (metodo in ('pix','boleto')),
  status      text not null default 'pendente'
              check (status in ('pendente','paga','vencida','cancelada','devolvida')),
  vence_em    timestamptz not null,
  criada_em   timestamptz not null default now(),
  paga_em     timestamptz,
  mp_id       text unique,
  mp_status   text,
  pix_copia_cola text,
  pix_qr_base64  text,
  boleto_url     text,
  linha_digitavel text,
  aberta_por  uuid references public.perfis(id) on delete set null
);
create index if not exists ix_cobranca_salao
  on public.cobrancas(salao_id, criada_em desc);
create unique index if not exists ux_cobranca_aberta
  on public.cobrancas(salao_id) where (status = 'pendente');
alter table public.cobrancas enable row level security;
drop policy if exists cobranca_ler on public.cobrancas;
create policy cobranca_ler on public.cobrancas for select to authenticated
  using ( e_gestor(salao_id) );
drop policy if exists cobranca_gerir on public.cobrancas;
create policy cobranca_gerir on public.cobrancas for all to authenticated
  using ( is_super() ) with check ( is_super() );
revoke all on public.cobrancas from anon, authenticated;
grant select on public.cobrancas to authenticated;
create or replace function public.abrir_cobranca(
  p_salao uuid, p_plano text, p_metodo text, p_quem uuid)
returns public.cobrancas
language plpgsql security definer set search_path = public as $$
declare
  v_preco numeric(10,2);
  v_dias  int;
  v_ja    public.cobrancas;
  v_nova  public.cobrancas;
begin
  if p_quem is null then
    raise exception 'Cobrança sem responsável.' using errcode = 'check_violation';
  end if;
  if not exists (
        select 1 from public.vinculos v
         where v.perfil_id = p_quem and v.salao_id = p_salao
           and v.status = 'ativo' and v.papel in ('dono','admin'))
     and not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_metodo not in ('pix','boleto') then
    raise exception 'Forma de pagamento desconhecida.' using errcode = 'check_violation';
  end if;
  select preco_mes into v_preco from public.planos where codigo = p_plano;
  if v_preco is null then
    raise exception 'Plano não encontrado.' using errcode = 'check_violation';
  end if;
  if v_preco <= 0 then
    raise exception 'Este plano não é pago.' using errcode = 'check_violation';
  end if;
  select * into v_ja from public.cobrancas
   where salao_id = p_salao and status = 'pendente'
   for update;
  if found then
    if v_ja.plano = p_plano and v_ja.metodo = p_metodo and v_ja.vence_em > now() then
      return v_ja;
    end if;
    update public.cobrancas set status = 'cancelada' where id = v_ja.id;
  end if;
  v_dias := case when p_metodo = 'boleto' then 3 else 1 end;
  insert into public.cobrancas (salao_id, plano, valor, metodo, vence_em, aberta_por)
  values (p_salao, p_plano, v_preco, p_metodo,
          now() + make_interval(days => v_dias), p_quem)
  returning * into v_nova;
  return v_nova;
end $$;
create or replace function public.anotar_cobranca(
  p_id uuid, p_mp_id text, p_mp_status text,
  p_pix text default null, p_qr text default null,
  p_boleto text default null, p_linha text default null)
returns void
language sql security definer set search_path = public as $$
  update public.cobrancas
     set mp_id = p_mp_id, mp_status = p_mp_status,
         pix_copia_cola = coalesce(p_pix, pix_copia_cola),
         pix_qr_base64  = coalesce(p_qr, pix_qr_base64),
         boleto_url     = coalesce(p_boleto, boleto_url),
         linha_digitavel = coalesce(p_linha, linha_digitavel)
   where id = p_id;
$$;
create or replace function public.dados_do_pagador(p_salao uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome',      coalesce(pf.nome, s.nome),
    'email',     pf.email,
    'documento', d.documento,
    'salao',     s.nome)
    from public.saloes s
    left join public.documentos_cobranca d on d.salao_id = s.id
    left join lateral (
      select p.nome, p.email
        from public.vinculos v
        join public.perfis p on p.id = v.perfil_id
       where v.salao_id = s.id and v.status = 'ativo' and v.papel = 'dono'
       order by v.criado_em limit 1) pf on true
   where s.id = p_salao;
$$;
revoke all on function public.dados_do_pagador(uuid) from public, anon, authenticated;
create or replace function public.registrar_pagamento(
  p_mp_id text, p_valor numeric, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.cobrancas;
  v_base date;
begin
  select * into c from public.cobrancas
   where mp_id = p_mp_id
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'cobranca_desconhecida');
  end if;
  if c.status = 'paga' then
    return jsonb_build_object('ok', true, 'motivo', 'ja_registrada');
  end if;
  if p_status <> 'approved' then
    update public.cobrancas set mp_status = p_status where id = c.id;
    return jsonb_build_object('ok', true, 'motivo', 'nao_aprovado');
  end if;
  if p_valor is distinct from c.valor then
    update public.cobrancas
       set mp_status = 'valor_divergente:' || coalesce(p_valor::text, 'null')
     where id = c.id;
    return jsonb_build_object('ok', false, 'motivo', 'valor_divergente');
  end if;
  update public.cobrancas
     set status = 'paga', paga_em = now(), mp_status = p_status
   where id = c.id;
  select greatest(coalesce(a.vence_em, current_date), current_date)
    into v_base
    from public.assinaturas a where a.salao_id = c.salao_id;
  update public.assinaturas
     set plano = c.plano,
         status = 'ativa',
         trial_ate = null,
         vence_em = coalesce(v_base, current_date) + interval '1 month',
         atualizado_em = now()
   where salao_id = c.salao_id;
  return jsonb_build_object('ok', true, 'salao', c.salao_id, 'plano', c.plano);
end $$;
revoke all on function public.abrir_cobranca(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.anotar_cobranca(uuid, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.registrar_pagamento(text, numeric, text) from public, anon, authenticated;
create or replace function public.minha_cobranca(p_salao uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'aberta', (
      select to_jsonb(x) from (
        select c.id, c.plano, c.valor, c.metodo, c.vence_em,
               c.pix_copia_cola, c.pix_qr_base64, c.boleto_url, c.linha_digitavel
          from public.cobrancas c
         where c.salao_id = p_salao and c.status = 'pendente'
           and c.vence_em > now()
         order by c.criada_em desc limit 1) x),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', h.id, 'plano', h.plano, 'valor', h.valor,
               'metodo', h.metodo, 'status', h.status,
               'pagaEm', h.paga_em, 'criadaEm', h.criada_em)
             order by h.criada_em desc)
        from (select * from public.cobrancas
               where salao_id = p_salao and status in ('paga','devolvida')
               order by criada_em desc limit 12) h), '[]'::jsonb)
  );
end $$;
revoke all on function public.minha_cobranca(uuid) from public;
grant execute on function public.minha_cobranca(uuid) to authenticated;
create or replace function public.assinaturas_a_vencer(p_dias int default 5)
returns table (salao_id uuid, salao text, whatsapp text, plano text,
               valor numeric, vence_em date)
language sql security definer set search_path = public as $$
  select a.salao_id, s.nome, s.whatsapp, a.plano, pl.preco_mes, a.vence_em
    from public.assinaturas a
    join public.saloes s  on s.id = a.salao_id
    join public.planos pl on pl.codigo = a.plano
   where a.status = 'ativa'
     and a.vence_em is not null
     and a.vence_em <= current_date + p_dias
     and pl.preco_mes > 0
     and not exists (
       select 1 from public.cobrancas c
        where c.salao_id = a.salao_id and c.status = 'pendente'
          and c.vence_em > now())
   order by a.vence_em;
$$;
create or replace function public.vencer_cobrancas()
returns int
language sql security definer set search_path = public as $$
  with mortas as (
    update public.cobrancas set status = 'vencida'
     where status = 'pendente' and vence_em <= now()
     returning 1)
  select count(*)::int from mortas;
$$;
revoke all on function public.assinaturas_a_vencer(int) from public, anon, authenticated;
revoke all on function public.vencer_cobrancas() from public, anon, authenticated;

alter table public.agendamentos
  add column if not exists encaixe boolean not null default false;
alter table public.agendamentos
  add column if not exists encaixe_por uuid references public.perfis(id)
    on delete set null;
comment on column public.agendamentos.encaixe is
  'Marcado fora da jornada, com confirmação explícita de quem tem acesso ao salão.';
create or replace function public.jornada_costurada(
  p_profissional uuid, p_data date)
returns table (inicio timestamptz, fim timestamptz)
language sql stable security definer set search_path = public as $$
  with fuso as (
    select coalesce(sa.fuso, 'America/Sao_Paulo') as z
      from public.profissionais p
      join public.saloes sa on sa.id = p.salao_id
     where p.id = p_profissional
  ),
  cruas as (
    select j.inicio, j.fim from public.jornadas j
     where j.profissional_id = p_profissional
       and j.dia_semana = extract(dow from p_data)::smallint
  ),
  marcadas as (
    select c.inicio, c.fim,
           case when c.inicio <= max(c.fim) over (
                  order by c.inicio, c.fim
                  rows between unbounded preceding and 1 preceding)
                then 0 else 1 end as nova
      from cruas c
  ),
  grupos as (
    select m.inicio, m.fim,
           sum(m.nova) over (order by m.inicio, m.fim
                             rows between unbounded preceding and current row) as g
      from marcadas m
  )
  select ((p_data + min(gr.inicio)) at time zone f.z),
         ((p_data + max(gr.fim))    at time zone f.z)
    from grupos gr cross join fuso f
   group by gr.g, f.z
   order by 1;
$$;
create or replace function public.cabe_na_jornada(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.jornadas
                      where profissional_id = p_profissional)
      or exists (
    select 1 from public.jornada_costurada(
                    p_profissional,
                    (p_inicio at time zone coalesce(
                       (select sa.fuso from public.profissionais p
                          join public.saloes sa on sa.id = p.salao_id
                         where p.id = p_profissional), 'America/Sao_Paulo'))::date) j
     where p_inicio >= j.inicio and p_fim <= j.fim);
$$;
create or replace function public.ha_bloqueio(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns text
language sql stable security definer set search_path = public as $$
  select coalesce(b.motivo, 'bloqueado')
    from public.bloqueios b
    join public.profissionais p on p.id = p_profissional
   where b.salao_id = p.salao_id
     and (b.profissional_id = p_profissional or b.profissional_id is null)
     and tstzrange(b.inicio, b.fim, '[)') && tstzrange(p_inicio, p_fim, '[)')
   limit 1;
$$;
create or replace function public.ha_choque(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns uuid
language sql stable security definer set search_path = public as $$
  select a.id from public.agendamentos a
   where a.profissional_id = p_profissional
     and a.status in ('pendente','confirmado','em_atendimento','concluido')
     and a.arquivado_em is null
     and (p_ignorar is null or a.id <> p_ignorar)
     and tstzrange(a.inicio, a.fim, '[)') && tstzrange(p_inicio, p_fim, '[)')
   limit 1;
$$;
create or replace function public.porque_nao_cabe(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_prof   record;
  v_motivo text;
  v_outro  uuid;
  v_fuso   text;
begin
  if p_inicio is null or p_fim is null or p_fim <= p_inicio then
    return 'Confira o horário: o fim tem que ser depois do início.';
  end if;
  select p.id, p.nome, p.ativo, sa.fuso, sa.status as status_salao
    into v_prof
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;
  if v_prof.id is null then
    return 'Profissional não encontrado.';
  end if;
  if not v_prof.ativo then
    return format('%s está desativado(a) na equipe.', v_prof.nome);
  end if;
  if v_prof.status_salao <> 'ativo' then
    return 'Este salão está suspenso.';
  end if;
  v_fuso := coalesce(v_prof.fuso, 'America/Sao_Paulo');
  v_outro := public.ha_choque(p_profissional, p_inicio, p_fim, p_ignorar);
  if v_outro is not null then
    return (select format('%s já tem %s das %s às %s.',
              v_prof.nome,
              coalesce(c.nome, 'um atendimento'),
              to_char(a.inicio at time zone v_fuso, 'HH24:MI'),
              to_char(a.fim    at time zone v_fuso, 'HH24:MI'))
              from public.agendamentos a
              left join public.clientes c on c.id = a.cliente_id
             where a.id = v_outro);
  end if;
  v_motivo := public.ha_bloqueio(p_profissional, p_inicio, p_fim);
  if v_motivo is not null then
    return format('Horário bloqueado na agenda de %s: %s.', v_prof.nome, v_motivo);
  end if;
  if not public.cabe_na_jornada(p_profissional, p_inicio, p_fim) then
    return format('Fora da jornada de %s neste dia.', v_prof.nome);
  end if;
  return null;
end $$;
create or replace function public.avaliar_horario(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_motivo text;
begin
  v_motivo := public.porque_nao_cabe(p_profissional, p_inicio, p_fim, p_ignorar);
  if v_motivo is null then
    return jsonb_build_object('cabe', true);
  end if;
  return jsonb_build_object(
    'cabe', false,
    'motivo', v_motivo,
    'encaixavel',
      public.ha_choque(p_profissional, p_inicio, p_fim, p_ignorar) is null
      and public.ha_bloqueio(p_profissional, p_inicio, p_fim) is null);
end $$;
create or replace function public.checar_cabe_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status not in ('pendente','confirmado','em_atendimento','concluido')
     or new.arquivado_em is not null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.inicio = old.inicio
     and new.fim = old.fim
     and new.profissional_id = old.profissional_id then
    return new;
  end if;
  if new.encaixe then
    return new;
  end if;
  if public.ha_choque(new.profissional_id, new.inicio, new.fim, new.id)
     is not null then
    raise exception 'Esse horário já está ocupado.'
      using errcode = 'exclusion_violation';
  end if;
  if public.ha_bloqueio(new.profissional_id, new.inicio, new.fim)
     is not null then
    raise exception 'Esse horário está bloqueado na agenda.'
      using errcode = 'check_violation';
  end if;
  if not public.cabe_na_jornada(new.profissional_id, new.inicio, new.fim) then
    raise exception 'Fora da jornada de trabalho deste profissional.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists tg_agend_cabe on public.agendamentos;
create trigger tg_agend_cabe
  before insert or update of inicio, fim, profissional_id, status, encaixe
  on public.agendamentos
  for each row execute function public.checar_cabe_agendamento();
create or replace function public.horarios_livres(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns setof timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_duracao int;
  v_passo   constant interval := '15 minutes';
  v_cedo_demais constant interval := '30 minutes';
  j         record;
  v_ini     timestamptz;
  v_fim     timestamptz;
begin
  if public.porque_nao_agenda(p_profissional, p_data, p_servicos) is not null then
    return;
  end if;
  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  if v_duracao <= 0 then return; end if;
  for j in select * from public.jornada_costurada(p_profissional, p_data) loop
    v_ini := j.inicio;
    while v_ini + make_interval(mins => v_duracao) <= j.fim loop
      v_fim := v_ini + make_interval(mins => v_duracao);
      if v_ini >= now() + v_cedo_demais
         and public.ha_choque(p_profissional, v_ini, v_fim) is null
         and public.ha_bloqueio(p_profissional, v_ini, v_fim) is null
      then
        return next v_ini;
      end if;
      v_ini := v_ini + v_passo;
    end loop;
  end loop;
end $$;
revoke all on function public.jornada_costurada(uuid, date) from public, anon, authenticated;
revoke all on function public.cabe_na_jornada(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ha_bloqueio(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ha_choque(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid) from public;
revoke all on function public.avaliar_horario(uuid, timestamptz, timestamptz, uuid) from public;
grant execute on function public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.avaliar_horario(uuid, timestamptz, timestamptz, uuid) to authenticated;

create or replace function public.reais(v numeric)
returns text language sql immutable set search_path = public as $$
  select 'R$ ' || replace(replace(replace(
           to_char(coalesce(v, 0), 'FM999,999,990.00'),
           '.', '|'), ',', '.'), '|', ',')
$$;
update public.comandas c
   set agendamento_id = null
 where c.agendamento_id is not null
   and c.status <> 'cancelada'
   and c.id <> (
     select d.id from public.comandas d
      where d.agendamento_id = c.agendamento_id
        and d.status <> 'cancelada'
      order by (select count(*) from public.pagamentos p
                 where p.comanda_id = d.id) desc,
               (select count(*) from public.comanda_itens i
                 where i.comanda_id = d.id) desc,
               d.aberta_em asc,
               d.id asc
      limit 1);
create unique index if not exists ux_comanda_agendamento
  on public.comandas(agendamento_id)
  where (agendamento_id is not null and status <> 'cancelada');
alter table public.comandas
  add column if not exists acrescimo numeric(10,2) not null default 0
    check (acrescimo >= 0);
comment on column public.comandas.acrescimo is
  'Taxa de urgência, domingo, deslocamento. Entra no total e NÃO gera comissão.';
drop view if exists public.comandas_totais;
create view public.comandas_totais
with (security_invoker = true) as
  select c.id,
         c.salao_id,
         c.numero,
         c.status,
         coalesce(sum(i.total), 0)                                as subtotal,
         c.desconto,
         c.acrescimo,
         coalesce(sum(i.total), 0) - c.desconto + c.acrescimo     as total,
         coalesce(sum(i.comissao_valor), 0)                       as comissao_total,
         coalesce((select sum(p.valor) from public.pagamentos p
                    where p.comanda_id = c.id), 0)                as pago,
         (coalesce(sum(i.total), 0) - c.desconto + c.acrescimo)
           - coalesce((select sum(p.valor) from public.pagamentos p
                        where p.comanda_id = c.id), 0)            as falta,
         case
           when c.status = 'cancelada' then 'cancelado'
           when coalesce((select sum(p.valor) from public.pagamentos p
                           where p.comanda_id = c.id), 0) = 0 then 'pendente'
           when coalesce((select sum(p.valor) from public.pagamentos p
                           where p.comanda_id = c.id), 0)
                >= (coalesce(sum(i.total), 0) - c.desconto + c.acrescimo)
             then 'pago'
           else 'parcial'
         end                                                      as situacao
    from public.comandas c
    left join public.comanda_itens i on i.comanda_id = c.id
   group by c.id;
grant select on public.comandas_totais to authenticated;
create or replace function public.conferir_desconto(p_comanda uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_sub  numeric(10,2);
  v_desc numeric(10,2);
begin
  select coalesce(sum(i.total), 0) into v_sub
    from public.comanda_itens i where i.comanda_id = p_comanda;
  select c.desconto into v_desc
    from public.comandas c where c.id = p_comanda;
  if v_desc > v_sub then
    raise exception
      'O desconto de % não pode ser maior que o valor dos itens (%).',
      public.reais(v_desc), public.reais(v_sub)
      using errcode = 'check_violation';
  end if;
end $$;
create or replace function public.tg_comanda_desconto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.conferir_desconto(new.id);
  return new;
end $$;
create or replace function public.tg_item_desconto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.conferir_desconto(coalesce(new.comanda_id, old.comanda_id));
  return coalesce(new, old);
end $$;
drop trigger if exists tg_comanda_desconto on public.comandas;
create constraint trigger tg_comanda_desconto
  after update of desconto on public.comandas
  deferrable initially immediate
  for each row execute function public.tg_comanda_desconto();
drop trigger if exists tg_item_desconto on public.comanda_itens;
create constraint trigger tg_item_desconto
  after insert or update or delete on public.comanda_itens
  deferrable initially immediate
  for each row execute function public.tg_item_desconto();
create or replace function public.tg_pagamento_cabe()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_total numeric(10,2);
  v_pago  numeric(10,2);
begin
  select t.total into v_total from public.comandas_totais t where t.id = new.comanda_id;
  select coalesce(sum(p.valor), 0) into v_pago
    from public.pagamentos p
   where p.comanda_id = new.comanda_id
     and (tg_op = 'INSERT' or p.id <> new.id);
  if v_total is null then
    raise exception 'Comanda não encontrada.' using errcode = 'check_violation';
  end if;
  if v_pago + new.valor > v_total + 0.005 then
    raise exception
      'Pagamento de % excede o que falta nesta comanda: %.',
      public.reais(new.valor), public.reais(greatest(v_total - v_pago, 0))
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists tg_pagamento_cabe on public.pagamentos;
create trigger tg_pagamento_cabe
  before insert or update of valor, comanda_id on public.pagamentos
  for each row execute function public.tg_pagamento_cabe();
create or replace function public.tg_comanda_travada()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_com    uuid;
begin
  v_com := coalesce(
    case tg_table_name
      when 'comanda_itens' then coalesce(new.comanda_id, old.comanda_id)
      when 'pagamentos'    then coalesce(new.comanda_id, old.comanda_id)
    end);
  select c.status into v_status from public.comandas c where c.id = v_com;
  if v_status = 'fechada' then
    raise exception 'Esta comanda está fechada. Reabra antes de alterar.'
      using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists tg_item_travado on public.comanda_itens;
create trigger tg_item_travado
  before insert or update or delete on public.comanda_itens
  for each row execute function public.tg_comanda_travada();
drop trigger if exists tg_pagamento_travado on public.pagamentos;
create trigger tg_pagamento_travado
  before insert or update or delete on public.pagamentos
  for each row execute function public.tg_comanda_travada();
create or replace function public.tg_comanda_valor_travado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'fechada' and new.status = 'fechada'
     and (new.desconto is distinct from old.desconto
       or new.acrescimo is distinct from old.acrescimo) then
    raise exception 'Esta comanda está fechada. Reabra antes de alterar.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists tg_comanda_valor_travado on public.comandas;
create trigger tg_comanda_valor_travado
  before update of desconto, acrescimo on public.comandas
  for each row execute function public.tg_comanda_valor_travado();
create or replace function public.tg_fechar_comanda()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  if new.status <> 'fechada' or old.status = 'fechada' then
    return new;
  end if;
  select * into t from public.comandas_totais where id = new.id;
  if t.subtotal <= 0 then
    raise exception 'Comanda sem itens não pode ser fechada.'
      using errcode = 'check_violation';
  end if;
  if t.falta > 0.005 then
    raise exception 'Ainda faltam % para fechar esta comanda.',
      public.reais(t.falta) using errcode = 'check_violation';
  end if;
  if new.fechada_em is null then new.fechada_em := now(); end if;
  return new;
end $$;
drop trigger if exists tg_fechar_comanda on public.comandas;
create trigger tg_fechar_comanda
  before update of status on public.comandas
  for each row execute function public.tg_fechar_comanda();
revoke all on function public.conferir_desconto(uuid) from public, anon, authenticated;
revoke all on function public.reais(numeric) from public;
grant execute on function public.reais(numeric) to anon, authenticated;
