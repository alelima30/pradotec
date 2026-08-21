-- ===========================================================================
-- AgendaPro — a cliente mexe no que é dela, e só no que é dela
--
-- O segredo devolvido por `agendar()` é a credencial. Este arquivo cobra as
-- duas metades: que ele FUNCIONA para quem o tem, e que ele é a ÚNICA coisa
-- que funciona — saber o telefone, o nome ou o id não abre nada.
-- ===========================================================================
\set ON_ERROR_STOP on

-- ── Cenário ────────────────────────────────────────────────────────────────
insert into public.saloes (id, slug, nome, tipo, status, fuso, cfg)
values ('11111111-0000-0000-0000-000000000001', 'salao-do-teste', 'Salão do Teste',
        'salao', 'ativo', 'America/Sao_Paulo', '{"diasLiberados": 30}')
on conflict (id) do nothing;

insert into public.assinaturas (salao_id, plano, status, trial_ate)
values ('11111111-0000-0000-0000-000000000001', 'trial', 'trial', current_date + 7)
on conflict (salao_id) do nothing;

insert into public.profissionais (id, salao_id, nome, ativo, aceita_online, comissao_pct)
values ('22222222-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000001', 'Ana', true, true, 40)
on conflict (id) do nothing;

insert into public.servicos (id, salao_id, nome, duracao_min, intervalo_min,
                             preco, ativo, aceita_online)
values ('33333333-0000-0000-0000-000000000001',
        '11111111-0000-0000-0000-000000000001', 'Corte', 60, 0, 80, true, true)
on conflict (id) do nothing;

-- Jornada nos sete dias: o teste não pode depender do dia em que roda.
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
select '22222222-0000-0000-0000-000000000001', d, '09:00', '18:00'
  from generate_series(0,6) d
on conflict do nothing;

-- Amanhã, para nunca esbarrar na antecedência mínima de 30 minutos.
create or replace function dia_cliente() returns date language sql stable as $f$
  select (now() at time zone 'America/Sao_Paulo')::date + 1
$f$;

-- ---------------------------------------------------------------------------
-- 1) Marcar devolve o segredo
-- ---------------------------------------------------------------------------
create temporary table marcado as
select * from public.agendar(
  '22222222-0000-0000-0000-000000000001'::uuid,
  (select min(h) from public.horarios_livres(
     '22222222-0000-0000-0000-000000000001'::uuid, dia_cliente(),
     array['33333333-0000-0000-0000-000000000001'::uuid]) h),
  array['33333333-0000-0000-0000-000000000001'::uuid],
  'Juliana Ferreira', '51988776655');

select t_verdade('agendar() devolve um segredo',
  (select token is not null from marcado));

select t_verdade('e ele é diferente do id da marcação — id não abre nada',
  (select token <> id from marcado));

-- ---------------------------------------------------------------------------
-- 2) Com o segredo, a pessoa vê o que é dela
-- ---------------------------------------------------------------------------
select t_igual('meus_agendamentos() devolve a marcação de quem tem o segredo',
  (select jsonb_array_length(public.meus_agendamentos(array[(select token from marcado)]))), 1);

select t_texto('com o nome de quem atende',
  (select public.meus_agendamentos(array[(select token from marcado)])
          -> 0 ->> 'profissional'), 'Ana');

select t_texto('e o nome do serviço',
  (select public.meus_agendamentos(array[(select token from marcado)])
          -> 0 -> 'servicos' ->> 0), 'Corte');

select t_verdade('marcada para amanhã, ainda dá para mexer',
  (select (public.meus_agendamentos(array[(select token from marcado)])
           -> 0 ->> 'podeMexer')::boolean));

-- ---------------------------------------------------------------------------
-- 3) SEM o segredo, não se vê nada
--
-- É o ponto inteiro do desenho. Um segredo inventado não devolve linha, e
-- não devolve mensagem diferente: "não existe" e "não é seu" respondem a
-- mesma coisa, senão viram oráculo para quem está tentando adivinhar.
-- ---------------------------------------------------------------------------
select t_igual('segredo inventado não devolve nada',
  jsonb_array_length(public.meus_agendamentos(
    array['99999999-9999-4999-8999-999999999999'::uuid])), 0);

select t_igual('lista de segredos vazia não devolve nada',
  jsonb_array_length(public.meus_agendamentos('{}'::uuid[])), 0);

select t_igual('nem nula',
  jsonb_array_length(public.meus_agendamentos(null)), 0);

-- ---------------------------------------------------------------------------
-- 4) Cancelar
-- ---------------------------------------------------------------------------
select t_texto('cancelar com segredo inventado é recusado',
  erro_de($$select public.cancelar_agendamento('99999999-9999-4999-8999-999999999999'::uuid)$$),
  'Não achei esse horário. Confira o link.');

select t_verdade('com o segredo certo, cancela',
  (select (public.cancelar_agendamento((select token from marcado)) ->> 'ok')::boolean));

select t_texto('e o banco registra quem cancelou',
  (select cancelado_motivo from public.agendamentos
    where id = (select id from marcado)), 'cancelado pelo cliente');

select t_texto('cancelar duas vezes é recusado, dizendo o que houve',
  erro_de(format($$select public.cancelar_agendamento(%L::uuid)$$, (select token from marcado))),
  'Este horário já foi cancelado.');

-- ── A ANTECEDÊNCIA ─────────────────────────────────────────────────────────
-- Cadeira cancelada em cima da hora não é revendida, e o prejuízo é do salão.
-- Quem precisa cancelar depois disso fala com a casa — é uma conversa, não
-- um botão.
insert into public.agendamentos
  (id, salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
   gerenciar_token)
select '44444444-0000-0000-0000-000000000001',
       '11111111-0000-0000-0000-000000000001',
       (select cliente_id from public.agendamentos where id = (select id from marcado)),
       '22222222-0000-0000-0000-000000000001',
       now() + interval '30 minutes', now() + interval '90 minutes',
       'confirmado', 'online',
       '55555555-0000-4000-8000-000000000001';

select t_texto('faltando menos de 2 horas, o botão não resolve — manda falar com o salão',
  erro_de($$select public.cancelar_agendamento('55555555-0000-4000-8000-000000000001'::uuid)$$),
  'Faltam menos de 2 horas. Fale com o salão para desmarcar.');

select t_falso('e a tela nem oferece: podeMexer vem falso',
  (select (public.meus_agendamentos(
     array['55555555-0000-4000-8000-000000000001'::uuid]) -> 0 ->> 'podeMexer')::boolean));

-- ---------------------------------------------------------------------------
-- 5) A lista de espera
-- ---------------------------------------------------------------------------
create temporary table na_fila as
select public.entrar_na_fila(
  '11111111-0000-0000-0000-000000000001'::uuid,
  array['33333333-0000-0000-0000-000000000001'::uuid],
  'Juliana Ferreira', '51988776655',
  dia_cliente(), dia_cliente() + 5) as r;

select t_verdade('entrar na fila devolve um segredo',
  (select (r ->> 'token') is not null from na_fila));

select t_igual('e ela se vê na fila com ele',
  (select jsonb_array_length(public.minha_fila(
     array[((select r ->> 'token' from na_fila))::uuid]))), 1);

select t_igual('segredo inventado não vê fila nenhuma',
  jsonb_array_length(public.minha_fila(
    array['99999999-9999-4999-8999-999999999999'::uuid])), 0);

-- A duração vem dos SERVIÇOS, não de quem chamou. Sem isso a fila encheria
-- de pedidos de três horas que ninguém pediu.
select t_igual('a duração foi calculada pelo banco',
  (select duracao_min from public.lista_espera
    where gerenciar_token = ((select r ->> 'token' from na_fila))::uuid), 60);

select t_texto('serviço de outro salão é recusado',
  erro_de(format($$select public.entrar_na_fila(%L::uuid, array[%L::uuid], 'X', '51988776655',
                                        current_date, current_date + 1)$$,
    '11111111-0000-0000-0000-000000000001',
    '33333333-0000-0000-0000-000000000009')),
  'Um dos serviços escolhidos não está disponível.');

select t_texto('telefone sem DDD é recusado',
  erro_de(format($$select public.entrar_na_fila(%L::uuid, array[%L::uuid], 'X', '9887',
                                        current_date, current_date + 1)$$,
    '11111111-0000-0000-0000-000000000001',
    '33333333-0000-0000-0000-000000000001')),
  'Confira o telefone: precisa do DDD.');

select t_verdade('e ela sai da fila com o mesmo segredo',
  (select (public.sair_da_fila(((select r ->> 'token' from na_fila))::uuid)
           ->> 'ok')::boolean));

select t_igual('depois de sair, não aparece mais',
  (select jsonb_array_length(public.minha_fila(
     array[((select r ->> 'token' from na_fila))::uuid]))), 0);

select t_texto('sair duas vezes é recusado',
  erro_de(format($$select public.sair_da_fila(%L::uuid)$$, (select r ->> 'token' from na_fila))),
  'Não achei esse pedido na lista.');

-- ---------------------------------------------------------------------------
-- 6) Quem pode chamar, e o que continua fechado
--
-- `anon` executa as funções e continua SEM alcançar as tabelas. É o ponto do
-- `security definer`: a cliente mexe no que é dela sem enxergar a agenda do
-- salão nem a lista de clientes dele.
-- ---------------------------------------------------------------------------
select t_verdade('anon pode ver o que é dele',
  has_function_privilege('anon', 'public.meus_agendamentos(uuid[])', 'execute'));
select t_verdade('anon pode cancelar',
  has_function_privilege('anon', 'public.cancelar_agendamento(uuid)', 'execute'));
select t_verdade('anon pode entrar na fila',
  has_function_privilege('anon',
    'public.entrar_na_fila(uuid, uuid[], text, text, date, date, uuid, text, text)', 'execute'));

select t_falso('mas anon continua sem ler a tabela de agendamentos',
  has_table_privilege('anon', 'public.agendamentos', 'select'));
select t_falso('nem a de lista de espera',
  has_table_privilege('anon', 'public.lista_espera', 'select'));
select t_falso('nem a de clientes',
  has_table_privilege('anon', 'public.clientes', 'select'));

select t_ok('cliente: tudo conferido');
