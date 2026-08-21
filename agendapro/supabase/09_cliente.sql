-- ===========================================================================
-- AgendaPro — 09: a cliente mexe no que é dela
--
-- ── O PROBLEMA ─────────────────────────────────────────────────────────────
-- Marcar não pede identificação, e está certo: atrito na primeira vez custa
-- cliente, e o estrago de uma marcação falsa é pequeno. Mas VER, CANCELAR e
-- REMARCAR mexem em dado de alguém. Sem prova de identidade, bastaria saber o
-- telefone da vizinha para cancelar o corte dela.
--
-- A prova óbvia seria um código por SMS. Ela custa um provedor de SMS, uma
-- Edge Function e um contrato — e sem nada disso a tela ficava mostrando um
-- código simulado, que é pior que não ter: parece verificação e não é.
--
-- ── A PROVA QUE NÃO PRECISA DE SMS ─────────────────────────────────────────
-- Quando alguém marca, o banco devolve um SEGREDO daquela marcação. Quem tem
-- o segredo é quem marcou — ninguém mais o viu passar. O navegador guarda, e
-- é com ele que a pessoa vê, cancela ou remarca.
--
-- É o mesmo desenho do "gerenciar sua reserva" de companhia aérea e hotel, e
-- ele tem três propriedades que importam aqui:
--
--   · não dá para adivinhar: uuid v4 tem 122 bits de acaso;
--   · não dá para enumerar: saber o telefone, o nome ou o id do salão não
--     ajuda em nada;
--   · funciona no WhatsApp: o mesmo link vai na mensagem de confirmação, e
--     aí a pessoa gerencia do celular dela mesmo depois de limpar o
--     navegador.
--
-- O que ele NÃO faz: não junta as marcações de vários aparelhos. Quem marcou
-- no computador do trabalho e quer cancelar do celular precisa do link. É uma
-- limitação honesta — e o dia em que houver SMS, ela cai.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) O segredo
--
-- Coluna nova nas duas tabelas em que a cliente mexe. `default` cobre as
-- linhas que já existem e as que entrarem por outro caminho — inclusive as
-- que a recepção criar pelo painel, que assim também podem ser gerenciadas
-- pela cliente se o salão mandar o link.
-- ---------------------------------------------------------------------------
alter table public.agendamentos
  add column if not exists gerenciar_token uuid not null default gen_random_uuid();

alter table public.lista_espera
  add column if not exists gerenciar_token uuid not null default gen_random_uuid();

-- Sem índice, cancelar vira varredura na tabela inteira de agendamentos da
-- plataforma. Único porque o segredo é a chave: dois iguais seriam duas
-- pessoas mexendo na mesma marcação.
create unique index if not exists ix_agend_token on public.agendamentos (gerenciar_token);
create unique index if not exists ix_espera_token on public.lista_espera (gerenciar_token);

-- ---------------------------------------------------------------------------
-- 2) agendar() passa a devolver o segredo
--
-- Mudar o que uma função devolve exige derrubá-la antes: `create or replace`
-- recusa alterar o tipo de retorno. Como a assinatura de ENTRADA não muda,
-- quem chama continua chamando igual.
-- ---------------------------------------------------------------------------
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

  select c.id into v_cliente from public.clientes c
   where c.salao_id = v_salao and c.telefone = v_tel;

  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (v_salao, v_perfil, v_nome, v_tel)
      returning clientes.id into v_cliente;
  elsif v_perfil is not null then
    update public.clientes
       set perfil_id = coalesce(perfil_id, v_perfil)
     where clientes.id = v_cliente;
  end if;

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

-- ---------------------------------------------------------------------------
-- 3) Ver o que é meu
--
-- Recebe a lista de segredos que o navegador guardou e devolve as marcações
-- correspondentes, já com o nome do serviço e de quem atende — a cliente não
-- alcança `servicos` nem `profissionais` diretamente, e não precisa.
--
-- Segredo que não existe simplesmente não devolve linha. Sem mensagem de erro
-- diferente: "este código não existe" versus "existe mas não é seu" seria um
-- oráculo para quem quisesse tentar.
-- ---------------------------------------------------------------------------
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
      -- A tela precisa saber se ainda dá tempo de mexer. A regra mora aqui
      -- para as duas pontas não discordarem: `cancelar_agendamento()` cobra
      -- o mesmo limite, e nada é oferecido para ser recusado depois.
      'podeMexer', a.status in ('pendente','confirmado')
                   and a.inicio > now() + interval '2 hours'
    ) as x
      from public.agendamentos a
      join public.saloes sa        on sa.id = a.salao_id
      join public.profissionais p  on p.id  = a.profissional_id
     where a.gerenciar_token = any(coalesce(p_tokens, '{}'::uuid[]))
  ) t
$$;

-- ---------------------------------------------------------------------------
-- 4) Cancelar
--
-- As DUAS horas de antecedência não são burocracia: cadeira cancelada em cima
-- da hora não é revendida, e o prejuízo é do salão. Quem precisa cancelar
-- depois disso fala com a casa — e aí é uma conversa, não um botão.
-- ---------------------------------------------------------------------------
create or replace function public.cancelar_agendamento(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.agendamentos%rowtype;
begin
  select * into a from public.agendamentos where gerenciar_token = p_token;

  -- Mesma frase para "não existe" e para "não é seu": qualquer diferença
  -- entre as duas responde perguntas para quem está tentando adivinhar.
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

-- ---------------------------------------------------------------------------
-- 5) A lista de espera
--
-- O dia cheio é onde o sistema comum perde o cliente: mostra "sem horário" e
-- a pessoa fecha a página. Aqui ela deixa o nome, e a cadeira que vagar tem
-- para quem ser oferecida.
--
-- Como `agendar()`, a duração sai dos SERVIÇOS e nunca do navegador: sem
-- isso, a fila encheria de pedidos de três horas que ninguém pediu.
-- ---------------------------------------------------------------------------
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

  -- Serviço tem que ser DESTE salão e estar aberto ao online, pela mesma
  -- razão de `agendar()`: sem conferir, dá para entrar na fila de um salão
  -- pedindo o serviço de outro, colando o id na chamada.
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

  select c.id into v_cliente from public.clientes c
   where c.salao_id = p_salao and c.telefone = v_tel;
  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (p_salao, v_perfil, v_nome, v_tel)
      returning clientes.id into v_cliente;
  end if;

  -- O mesmo freio de spam de `agendar()`, e pelo mesmo motivo: é um
  -- formulário aberto na internet.
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

-- ---------------------------------------------------------------------------
-- 6) Quem pode chamar
--
-- Tudo para `anon`: a cliente que abre o link não fez login, e é ela quem
-- precisa disso. O segredo é a credencial — as funções não confiam em nada
-- além dele, e nenhuma delas aceita "me dê a lista de fulano".
--
-- E `anon` continua SEM alcançar `agendamentos`, `clientes` e `lista_espera`
-- pelas tabelas. Todo o acesso passa por estas funções, que só respondem a
-- quem apresenta o segredo daquela linha.
-- ---------------------------------------------------------------------------
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
