create or replace function public.ficha_do_cliente(
  p_salao uuid, p_nome text, p_tel text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_perfil  uuid := auth.uid();
  v_cliente uuid;
begin
  if v_perfil is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.perfil_id = v_perfil;
  end if;
  if v_cliente is null and p_tel is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.telefone = p_tel;
  end if;
  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (p_salao, v_perfil, p_nome, p_tel)
      returning clientes.id into v_cliente;
    return v_cliente;
  end if;
  update public.clientes c
     set perfil_id = coalesce(c.perfil_id, v_perfil),
         telefone  = case
           when p_tel is null or p_tel = c.telefone then c.telefone
           when exists (select 1 from public.clientes o
                         where o.salao_id = p_salao
                           and o.telefone = p_tel
                           and o.id <> c.id) then c.telefone
           else p_tel end
   where c.id = v_cliente;
  return v_cliente;
end $$;

revoke all on function public.ficha_do_cliente(uuid, text, text) from public;

alter table public.agendamentos
  add column if not exists gerenciar_token uuid not null default gen_random_uuid();
alter table public.lista_espera
  add column if not exists gerenciar_token uuid not null default gen_random_uuid();
create unique index if not exists ix_agend_token on public.agendamentos (gerenciar_token);
create unique index if not exists ix_espera_token on public.lista_espera (gerenciar_token);
drop function if exists public.agendar(uuid, timestamptz, uuid[], text, text, text, text);
create or replace function public.agendar(
  p_profissional  uuid,
  p_inicio        timestamptz,
  p_servicos      uuid[],
  p_nome          text,
  p_telefone      text,
  p_atendido_nome text default null,
  p_obs           text default null)
returns table (id uuid, inicio timestamptz, fim timestamptz, valor numeric,
               token uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_salao    uuid;
  v_fuso     text;
  v_data     date;
  v_motivo   text;
  v_duracao  int;
  v_tel      text;
  v_nome     text;
  v_cliente  uuid;
  v_perfil   uuid;
  v_agend    uuid;
  v_token    uuid;
  v_fim      timestamptz;
  v_valor    numeric(10,2);
  v_abertos  int;
  v_ordem    smallint := 1;
  s          record;
begin
  v_nome := nullif(btrim(coalesce(p_nome, '')), '');
  v_tel  := public.so_digitos(p_telefone);
  if v_nome is null then
    raise exception 'Diga seu nome para a gente saber quem esperar.'
      using errcode = 'check_violation';
  end if;
  if v_tel is null or length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'Confira o telefone: precisa do DDD.'
      using errcode = 'check_violation';
  end if;
  select p.salao_id, sa.fuso into v_salao, v_fuso
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;
  if v_salao is null then
    raise exception 'Este profissional não está atendendo pela agenda online.'
      using errcode = 'check_violation';
  end if;
  v_data := (p_inicio at time zone v_fuso)::date;
  v_motivo := public.porque_nao_agenda(p_profissional, v_data, p_servicos);
  if v_motivo is not null then
    raise exception '%', v_motivo using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.horarios_livres(p_profissional, v_data, p_servicos) h
     where h = p_inicio)
  then
    raise exception 'Esse horário não está mais livre. Escolha outro, por favor.'
      using errcode = 'check_violation';
  end if;
  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  v_valor   := public.preco_dos_servicos(p_profissional, p_servicos);
  v_fim     := p_inicio + make_interval(mins => v_duracao);
  v_perfil := auth.uid();
  v_cliente := public.ficha_do_cliente(v_salao, v_nome, v_tel);
  select count(*) into v_abertos from public.agendamentos a
   where a.cliente_id = v_cliente
     and a.status in ('pendente','confirmado')
     and a.inicio > now();
  if v_abertos >= 3 then
    raise exception 'Você já tem 3 horários marcados aqui. Cancele um antes de marcar outro.'
      using errcode = 'check_violation';
  end if;
  begin
    insert into public.agendamentos
      (salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
       valor_previsto, atendido_nome, obs, criado_por)
    values
      (v_salao, v_cliente, p_profissional, p_inicio, v_fim, 'confirmado', 'online',
       v_valor, nullif(btrim(coalesce(p_atendido_nome, '')), ''),
       nullif(btrim(coalesce(p_obs, '')), ''), v_perfil)
    returning agendamentos.id, agendamentos.gerenciar_token into v_agend, v_token;
  exception
    when exclusion_violation then
      raise exception 'Alguém acabou de marcar esse horário. Escolha outro, por favor.'
        using errcode = 'check_violation';
  end;
  for s in
    select sv.id, coalesce(sp.duracao_min, sv.duracao_min) + sv.intervalo_min as dur,
           coalesce(sp.preco, sv.preco) as preco,
           coalesce(sv.comissao_pct, pr.comissao_pct, 0) as com
      from unnest(p_servicos) with ordinality as pedido(id, pos)
      join public.servicos sv on sv.id = pedido.id
      join public.profissionais pr on pr.id = p_profissional
      left join public.servicos_profissionais sp
             on sp.servico_id = sv.id and sp.profissional_id = p_profissional
     order by pedido.pos
  loop
    insert into public.agendamento_servicos
      (agendamento_id, servico_id, ordem, duracao_min, preco, comissao_pct)
    values (v_agend, s.id, v_ordem, s.dur, s.preco, s.com);
    v_ordem := v_ordem + 1;
  end loop;
  return query select v_agend, p_inicio, v_fim, v_valor, v_token;
end $$;
create or replace function public.meus_agendamentos(p_tokens uuid[])
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'inicio'), '[]'::jsonb) from (
    select jsonb_build_object(
      'token',     a.gerenciar_token,
      'inicio',    a.inicio,
      'fim',       a.fim,
      'status',    a.status,
      'atendido',  a.atendido_nome,
      'valor',     a.valor_previsto,
      'salao',     sa.nome,
      'slug',      sa.slug,
      'fuso',      sa.fuso,
      'profissional', coalesce(p.apelido, p.nome),
      'servicos', coalesce((
        select jsonb_agg(sv.nome order by asv.ordem)
          from public.agendamento_servicos asv
          join public.servicos sv on sv.id = asv.servico_id
         where asv.agendamento_id = a.id), '[]'::jsonb),
      'podeMexer', a.status in ('pendente','confirmado')
                   and a.inicio > now() + interval '2 hours'
    ) as x
      from public.agendamentos a
      join public.saloes sa        on sa.id = a.salao_id
      join public.profissionais p  on p.id  = a.profissional_id
     where a.gerenciar_token = any(coalesce(p_tokens, '{}'::uuid[]))
  ) t
$$;
create or replace function public.cancelar_agendamento(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.agendamentos%rowtype;
begin
  select * into a from public.agendamentos where gerenciar_token = p_token;
  if a.id is null then
    raise exception 'Não achei esse horário. Confira o link.'
      using errcode = 'check_violation';
  end if;
  if a.status not in ('pendente','confirmado') then
    raise exception 'Este horário já foi %.',
      case a.status when 'cancelado' then 'cancelado'
                    when 'concluido' then 'atendido'
                    else a.status end
      using errcode = 'check_violation';
  end if;
  if a.inicio <= now() + interval '2 hours' then
    raise exception 'Faltam menos de 2 horas. Fale com o salão para desmarcar.'
      using errcode = 'check_violation';
  end if;
  update public.agendamentos
     set status = 'cancelado', cancelado_motivo = 'cancelado pelo cliente'
   where id = a.id;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.entrar_na_fila(
  p_salao      uuid,
  p_servicos   uuid[],
  p_nome       text,
  p_telefone   text,
  p_de         date,
  p_ate        date,
  p_profissional uuid default null,
  p_turno      text default 'qualquer',
  p_obs        text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tel     text;
  v_nome    text;
  v_cliente uuid;
  v_perfil  uuid := auth.uid();
  v_dur     int;
  v_hoje    date;
  v_token   uuid;
  v_abertas int;
begin
  v_nome := nullif(btrim(coalesce(p_nome, '')), '');
  v_tel  := public.so_digitos(p_telefone);
  if v_nome is null then
    raise exception 'Diga seu nome para a gente saber quem avisar.'
      using errcode = 'check_violation';
  end if;
  if v_tel is null or length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'Confira o telefone: precisa do DDD.'
      using errcode = 'check_violation';
  end if;
  if p_servicos is null or cardinality(p_servicos) = 0 then
    raise exception 'Escolha pelo menos um serviço.'
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.saloes
                  where id = p_salao and status = 'ativo') then
    raise exception 'Este salão não está aceitando pedidos agora.'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from unnest(p_servicos) as pedido(id)
     where not exists (
       select 1 from public.servicos s
        where s.id = pedido.id and s.salao_id = p_salao
          and s.ativo and s.aceita_online))
  then
    raise exception 'Um dos serviços escolhidos não está disponível.'
      using errcode = 'check_violation';
  end if;
  v_hoje := public.hoje_no_salao(p_salao);
  if p_de < v_hoje or p_ate < p_de then
    raise exception 'Confira as datas do período.'
      using errcode = 'check_violation';
  end if;
  if p_ate > v_hoje + public.dias_liberados(p_salao) then
    raise exception 'A agenda está liberada até %.',
      to_char(v_hoje + public.dias_liberados(p_salao), 'DD/MM/YYYY')
      using errcode = 'check_violation';
  end if;
  v_cliente := public.ficha_do_cliente(p_salao, v_nome, v_tel);
  select count(*) into v_abertas from public.lista_espera
   where cliente_id = v_cliente and status = 'aguardando';
  if v_abertas >= 3 then
    raise exception 'Você já está em 3 listas de espera aqui. Saia de uma antes de entrar noutra.'
      using errcode = 'check_violation';
  end if;
  v_dur := public.duracao_dos_servicos(
             coalesce(p_profissional,
                      (select id from public.profissionais
                        where salao_id = p_salao and ativo limit 1)),
             p_servicos);
  insert into public.lista_espera
    (salao_id, cliente_id, profissional_id, servicos, duracao_min,
     de, ate, turno, obs, status)
  values
    (p_salao, v_cliente, p_profissional, to_jsonb(p_servicos), greatest(v_dur, 1),
     p_de, p_ate, coalesce(nullif(btrim(p_turno), ''), 'qualquer'),
     nullif(btrim(coalesce(p_obs, '')), ''), 'aguardando')
  returning gerenciar_token into v_token;
  return jsonb_build_object('token', v_token);
end $$;
create or replace function public.minha_fila(p_tokens uuid[])
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'de'), '[]'::jsonb) from (
    select jsonb_build_object(
      'token',  e.gerenciar_token,
      'de',     e.de,
      'ate',    e.ate,
      'turno',  e.turno,
      'status', e.status,
      'salao',  sa.nome,
      'slug',   sa.slug
    ) as x
      from public.lista_espera e
      join public.saloes sa on sa.id = e.salao_id
     where e.gerenciar_token = any(coalesce(p_tokens, '{}'::uuid[]))
       and e.status = 'aguardando'
  ) t
$$;
create or replace function public.sair_da_fila(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.lista_espera
     set status = 'desistiu'
   where gerenciar_token = p_token and status = 'aguardando';
  if not found then
    raise exception 'Não achei esse pedido na lista.'
      using errcode = 'check_violation';
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.meus_agendamentos(uuid[])   from public;
revoke all on function public.cancelar_agendamento(uuid)  from public;
revoke all on function public.minha_fila(uuid[])          from public;
revoke all on function public.sair_da_fila(uuid)          from public;
revoke all on function public.entrar_na_fila(uuid, uuid[], text, text, date, date,
                                             uuid, text, text) from public;
revoke all on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  from public;
grant execute on function public.meus_agendamentos(uuid[])   to anon, authenticated;
grant execute on function public.cancelar_agendamento(uuid)  to anon, authenticated;
grant execute on function public.minha_fila(uuid[])          to anon, authenticated;
grant execute on function public.sair_da_fila(uuid)          to anon, authenticated;
grant execute on function public.entrar_na_fila(uuid, uuid[], text, text, date, date,
                                                uuid, text, text) to anon, authenticated;
grant execute on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  to anon, authenticated;

create or replace function public.vitrine(p_slug text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'salao', jsonb_build_object(
      'id', s.id, 'slug', s.slug, 'nome', s.nome, 'tipo', s.tipo,
      'logo', s.logo, 'capa', s.capa,
      'telefone', s.telefone, 'whatsapp', s.whatsapp,
      'endereco', s.endereco, 'fuso', s.fuso,
      'diasLiberados', public.dias_liberados(s.id),
      'cor',  s.cfg->>'cor',
      'tema', s.cfg->>'tema',
      'precoNaCapa', coalesce((s.cfg->>'precoNaCapa')::boolean, false),
      'fundo', s.cfg->>'fundo',
      'brilho', coalesce((s.cfg->>'brilho')::boolean, true),
      'letra', s.cfg->>'letra',
      'slideDe', s.cfg->>'slideDe',
      'galeria', coalesce(s.cfg->'galeria', '[]'::jsonb)
    ),
    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'nome', v.nome, 'categoria', v.categoria,
               'descricao', v.descricao, 'duracaoMin', v.duracao_min,
               'preco', v.preco, 'foto', v.foto)
             order by v.categoria nulls last, v.nome)
        from public.servicos v
       where v.salao_id = s.id and v.ativo and v.aceita_online), '[]'::jsonb),
    'profissionais', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'nome', coalesce(p.apelido, p.nome),
               'foto', p.foto,
               'servicos', (select coalesce(jsonb_agg(sp.servico_id), '[]'::jsonb)
                              from public.servicos_profissionais sp
                             where sp.profissional_id = p.id))
             order by p.criado_em, p.id)
        from public.profissionais p
       where p.salao_id = s.id and p.ativo and p.aceita_online
         and public.profissional_na_cota(p.id)), '[]'::jsonb)
  )
  from public.saloes s
  where s.slug = p_slug and s.status = 'ativo'
$$;
revoke all on public.saloes_publicos        from anon, authenticated;
revoke all on public.servicos_publicos      from anon, authenticated;
revoke all on public.profissionais_publicos from anon, authenticated;
revoke all on function public.vitrine(text) from public;
grant execute on function public.vitrine(text) to anon, authenticated;
