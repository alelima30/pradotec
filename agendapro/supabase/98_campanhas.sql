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
