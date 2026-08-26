-- ===========================================================================
-- AgendaPro — 10: Campanhas de WhatsApp
--
-- Mandar mensagem para a clientela é o pedido mais repetido de quem tem
-- salão, e é também o mais fácil de fazer errado de um jeito que custa o
-- número do dono. Este arquivo é a metade que mora no banco: as tabelas, o
-- isolamento por salão e a FILA.
--
-- A outra metade é a função de borda (supabase/functions/enviar-campanha),
-- que roda no servidor do Supabase e é a única que enxerga o token da Meta.
--
-- ── O QUE NÃO ESTÁ AQUI, E POR QUÊ ─────────────────────────────────────────
-- Nenhuma credencial. Nem token, nem id de número, nem segredo de webhook.
-- Eles vivem nas variáveis de ambiente da função de borda. O painel do dono é
-- HTML servido do GitHub Pages: tudo o que chega nele é público por
-- construção, e um token da Cloud API vazado manda mensagem em nome do salão
-- até alguém revogar.
--
-- ── A REGRA DA META QUE MUDA O DESENHO ─────────────────────────────────────
-- A Cloud API só entrega texto livre para quem falou com o número nas
-- últimas 24 horas. Fora dessa janela — que é o caso de toda campanha de
-- marketing — a mensagem PRECISA ser um template aprovado pela Meta, com os
-- valores entrando como parâmetros numerados.
--
-- Por isso a campanha guarda as duas formas: `template_nome` (o caminho que
-- funciona para marketing) e `corpo` (texto livre, que só sai para quem está
-- dentro da janela). Fingir que texto livre resolve marketing seria entregar
-- um módulo que falha justamente no dia da promoção.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) CONSENTIMENTO
--
-- Antes de qualquer tabela de campanha: o direito de não receber. Sem isto o
-- módulo nasce ilegal — LGPD, art. 18 — e, pior no dia a dia, queima o
-- número do salão em denúncia de spam.
--
-- `default true` é decisão consciente: quem já é cliente do salão e deu o
-- telefone no balcão tem relação com a casa. O que não pode é não haver saída
-- — e a saída existe, na ficha e pelo pedido da própria pessoa.
-- ---------------------------------------------------------------------------
alter table public.clientes
  add column if not exists aceita_marketing boolean not null default true;

alter table public.clientes
  add column if not exists marketing_saiu_em timestamptz;

-- ---------------------------------------------------------------------------
-- 2) A CAMPANHA
-- ---------------------------------------------------------------------------
create table if not exists public.campanhas (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  nome          text not null check (length(btrim(nome)) between 2 and 120),

  -- Para que serve. Separa marketing de transacional porque as duas coisas
  -- têm regras diferentes na Meta E na lei: lembrete de horário vai para quem
  -- pediu para não receber promoção, promoção não vai.
  tipo          text not null default 'promocao'
                check (tipo in ('promocao','lembrete','confirmacao','aniversario',
                                'ausente','retorno','aviso','personalizada')),

  -- Texto livre. Só chega em quem falou com o número nas últimas 24h.
  corpo         text,
  -- O caminho do marketing: template aprovado pela Meta.
  template_nome text,
  template_idioma text not null default 'pt_BR',

  status        text not null default 'rascunho'
                check (status in ('rascunho','agendada','processando','concluida',
                                  'cancelada','concluida_com_falhas')),

  -- Preparado para "enviar amanhã às 10:00" sem precisar de outra tabela.
  agendada_para timestamptz,

  -- Intervalo entre mensagens, em segundos. O disparo usa um valor sorteado
  -- na faixa: cadência de metrônomo é o padrão que denuncia robô.
  intervalo_min int not null default 5  check (intervalo_min between 3 and 300),
  intervalo_max int not null default 12 check (intervalo_max between 3 and 600),
  check (intervalo_max >= intervalo_min),

  iniciada_em   timestamptz,
  concluida_em  timestamptz,
  criada_por    uuid references public.perfis(id) on delete set null,
  criada_em     timestamptz not null default now(),

  -- Ou template, ou corpo. Campanha sem nenhum dos dois não tem o que mandar,
  -- e descobrir isso no meio do disparo é descobrir tarde.
  check (coalesce(nullif(btrim(template_nome), ''), nullif(btrim(corpo), '')) is not null)
);

create index if not exists ix_camp_salao on public.campanhas(salao_id, criada_em desc);
-- O índice que a fila varre. Parcial porque só interessa quem está rodando.
create index if not exists ix_camp_rodando on public.campanhas(status)
  where status = 'processando';

-- ---------------------------------------------------------------------------
-- 3) O DESTINATÁRIO
--
-- Uma linha por pessoa por campanha, com o estado dela. É esta tabela que
-- torna o envio idempotente: o worker não guarda nada em memória, e nada é
-- decidido no navegador.
--
-- `salao_id` está repetido aqui de propósito, apesar de já vir pela campanha.
-- É o que deixa a policy de RLS ser direta em vez de depender de subconsulta
-- — e policy simples é policy que se confere de olho.
-- ---------------------------------------------------------------------------
create table if not exists public.campanha_destinatarios (
  id            uuid primary key default gen_random_uuid(),
  campanha_id   uuid not null references public.campanhas(id) on delete cascade,
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  cliente_id    uuid not null references public.clientes(id) on delete cascade,

  -- O telefone é COPIADO no momento em que a campanha é montada. Se a ficha
  -- mudar de número depois, o histórico continua dizendo para onde foi.
  telefone      text not null,

  status        text not null default 'pendente'
                check (status in ('pendente','processando','enviado','falhou','cancelado')),
  tentativas    smallint not null default 0 check (tentativas >= 0),
  -- Espera antes da próxima tentativa. É o que impede a retentativa de virar
  -- laço apertado quando a API está fora do ar.
  proxima_em    timestamptz,
  tentado_em    timestamptz,
  enviado_em    timestamptz,
  erro_codigo   text,
  erro_msg      text,
  -- O id que a Meta devolve. Serve para casar o webhook de status depois.
  wam_id        text,
  criado_em     timestamptz not null default now(),

  -- ⚠ A TRAVA CONTRA MENSAGEM REPETIDA
  -- Refresh, timeout, retry, worker reiniciado, dois workers ao mesmo tempo:
  -- todos terminam tentando inserir a mesma pessoa na mesma campanha. Aqui o
  -- banco recusa, e nenhum caminho de código precisa lembrar de conferir.
  constraint ux_camp_dest unique (campanha_id, cliente_id)
);

create index if not exists ix_dest_camp on public.campanha_destinatarios(campanha_id, status);
-- O índice do worker: os pendentes prontos para sair, na ordem de entrada.
create index if not exists ix_dest_fila
  on public.campanha_destinatarios(campanha_id, criado_em)
  where status = 'pendente';

-- ---------------------------------------------------------------------------
-- 4) RLS — O SALÃO A NÃO ENXERGA O SALÃO B
--
-- Este é o requisito que não admite engano. As duas tabelas ligam RLS, e a
-- policy usa os mesmos auxiliares do resto do sistema: `e_gestor()` para
-- escrever, `e_equipe()` para ler.
--
-- Campanha é assunto de quem manda no salão — quem atende não precisa ver a
-- lista de telefone da casa inteira para trabalhar.
-- ---------------------------------------------------------------------------
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

-- O `anon` não tem nada a fazer aqui. Explícito porque o Supabase liga por
-- padrão "expose new tables", que dá ALL para anon em toda tabela nova — foi
-- assim que 20 tabelas deste projeto já nasceram abertas uma vez.
revoke all on public.campanhas              from anon;
revoke all on public.campanha_destinatarios from anon;
grant select, insert, update, delete on public.campanhas              to authenticated;
grant select, insert, update, delete on public.campanha_destinatarios to authenticated;

-- ---------------------------------------------------------------------------
-- 5) QUEM ENTRA NA CAMPANHA
--
-- Uma função só, porque a mesma pergunta é feita três vezes: para mostrar o
-- número no resumo, para montar a fila, e para o teste conferir. Três cópias
-- da regra é como o resumo passa a prometer 127 e a fila mandar 119.
--
-- `security definer` com `search_path` fixo, e a PRIMEIRA linha confere se
-- quem chamou manda neste salão. Sem essa linha, `security definer` seria uma
-- porta para ler a clientela alheia trocando o uuid na chamada — que é o
-- IDOR que o pedido manda procurar.
-- ---------------------------------------------------------------------------
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
     -- Sem telefone não há para onde mandar. Fica de fora antes de virar
     -- linha de fila, senão a campanha nasce com falha garantida.
     and public.so_digitos(c.telefone) is not null
     -- ⚠ O opt-out vale só para marketing. Lembrete e confirmação de horário
     -- são serviço, não propaganda: quem pediu para não receber promoção
     -- continua sendo avisado de que tem horário marcado.
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

-- ---------------------------------------------------------------------------
-- 6) MONTAR A FILA
--
-- Copia o público para `campanha_destinatarios` e deixa a campanha pronta.
-- `on conflict do nothing` mais a trava única: chamar duas vezes não duplica
-- ninguém, e é o que faz um refresh no meio do caminho ser inofensivo.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 7) COMEÇAR E PARAR
-- ---------------------------------------------------------------------------
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

/* Cancelar não interrompe quem já está no ar.
   Quem está em 'processando' foi entregue à Meta ou está a caminho: marcar
   como cancelado ali criaria um registro que diz "não mandei" para uma
   mensagem que a cliente recebeu. Os pendentes param; o resto o worker
   fecha. */
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

-- ---------------------------------------------------------------------------
-- 8) O PLACAR
--
-- Uma consulta só para a tela de progresso e a de detalhes. Sem ela, o painel
-- baixaria a lista inteira de destinatários para contar no navegador — que é
-- exatamente o que trava com mil clientes.
-- ---------------------------------------------------------------------------
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

-- ===========================================================================
-- 9) A FILA, DO LADO DO WORKER
--
-- ⚠ TUDO NESTA SEÇÃO É SÓ PARA `service_role`.
--
-- Estas funções contornam o RLS de propósito: o worker não é dono de salão
-- nenhum e precisa atender todos. É por isso que elas NÃO são concedidas a
-- `authenticated` nem a `anon` — quem as chama é a função de borda, com a
-- chave secreta que só existe no servidor.
--
-- Se alguma delas aparecer concedida a `authenticated`, é falha grave: dá
-- para varrer telefone de qualquer salão da plataforma.
-- ===========================================================================

/* Pega o próximo da fila e marca como 'processando' NA MESMA transação.

   `for update skip locked` é o que torna isto seguro com mais de um worker:
   quem chega depois pula a linha travada em vez de esperar por ela, e a
   mesma pessoa nunca é entregue duas vezes. Sem isso, dois workers — ou o
   mesmo worker reiniciado — mandariam a mesma mensagem duas vezes, que é o
   item 23 do pedido. */
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

/* Registra o resultado. Erro temporário volta para a fila com espera
   crescente; a partir da terceira tentativa vira falha definitiva.

   Três é o teto do pedido, e é teto de verdade: sem ele, um número inválido
   fica girando na fila para sempre e segura a campanha inteira atrás dele. */
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
    -- Espera crescente: 30s, 2min, 8min. Erro de rede costuma passar; erro de
    -- rede consultado a cada segundo vira mais erro de rede.
    update public.campanha_destinatarios
       set status = 'pendente', erro_codigo = p_erro_codigo,
           erro_msg = left(coalesce(p_erro_msg, ''), 500),
           proxima_em = now() + make_interval(secs => 30 * power(4, d.tentativas - 1))
     where id = d.id;
  end if;

  -- Acabou a fila desta campanha? Fecha, dizendo se foi limpo ou não.
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
