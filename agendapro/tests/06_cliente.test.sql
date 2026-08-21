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

-- ---------------------------------------------------------------------------
-- N) MARCAR DE NOVO COM OUTRO NÚMERO
--
-- Veio de um print do celular, no meio de um agendamento preenchido:
--
--     Não consegui marcar.
--     duplicate key value violates unique constraint "ux_cli_perfil"
--
-- A busca da ficha era só pelo telefone. Quem já tinha ficha no salão e
-- marcava digitando um número diferente do que estava lá — trocou de chip,
-- digitou o do marido, corrigiu o DDD — não era encontrado, caía no insert, e
-- o insert batia na trava que existe para a mesma pessoa não ter duas fichas
-- no mesmo salão.
--
-- Erro de banco em inglês na cara de quem só queria marcar horário, sem saída
-- nenhuma: tentar de novo dava o mesmo. O salão perde a marcação e nem fica
-- sabendo que perdeu.
--
-- A regra estava escrita TRÊS vezes (agendar() aqui, agendar() do 05 e
-- entrar_na_fila()) e errada nas três. Agora é `ficha_do_cliente()`, uma só.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('cc000000-0000-0000-0000-0000000000cc', 'ju@teste.com')
on conflict (id) do nothing;
-- O telefone do PERFIL é E.164 (com o +55), por check no schema. O da FICHA
-- do salão é só dígitos, normalizado por `so_digitos()`. São dois campos
-- diferentes, com regras diferentes, e é de propósito.
insert into public.perfis (id, nome, telefone) values
  ('cc000000-0000-0000-0000-0000000000cc', 'Ju Barbosa', '+5551988776655')
on conflict (id) do nothing;

-- Ela marca logada, com o número dela. Nasce a ficha, com perfil.
do $$ begin
  perform set_config('request.jwt.claim.sub',
                     'cc000000-0000-0000-0000-0000000000cc', true);
  perform public.agendar(
    '22222222-0000-0000-0000-000000000001'::uuid,
    (select min(h) from public.horarios_livres(
       '22222222-0000-0000-0000-000000000001'::uuid, dia_cliente() + 7,
       array['33333333-0000-0000-0000-000000000001'::uuid]) h),
    array['33333333-0000-0000-0000-000000000001'::uuid],
    'Ju Barbosa', '51988776655');
end $$;

select t_igual('a primeira marcação criou UMA ficha para o perfil',
  (select count(*) from public.clientes
    where salao_id = '11111111-0000-0000-0000-000000000001'
      and perfil_id = 'cc000000-0000-0000-0000-0000000000cc'), 1);

-- E agora marca de novo, logada, digitando OUTRO número. Era aqui que caía.
select t_texto('marcar com outro número não estoura a trava de ficha única',
  erro_de($$
    do $x$ begin
      perform set_config('request.jwt.claim.sub',
                         'cc000000-0000-0000-0000-0000000000cc', true);
      perform public.agendar(
        '22222222-0000-0000-0000-000000000001'::uuid,
        (select min(h) from public.horarios_livres(
           '22222222-0000-0000-0000-000000000001'::uuid, dia_cliente() + 8,
           array['33333333-0000-0000-0000-000000000001'::uuid]) h),
        array['33333333-0000-0000-0000-000000000001'::uuid],
        'Ju Barbosa', '51977665544');
    end $x$;
  $$), null);

select t_igual('e continua sendo UMA ficha, não duas',
  (select count(*) from public.clientes
    where salao_id = '11111111-0000-0000-0000-000000000001'
      and perfil_id = 'cc000000-0000-0000-0000-0000000000cc'), 1);

select t_texto('com o telefone novo, que é o que ela acabou de informar',
  (select telefone from public.clientes
    where salao_id = '11111111-0000-0000-0000-000000000001'
      and perfil_id = 'cc000000-0000-0000-0000-0000000000cc'), '51977665544');

select t_igual('e as duas marcações foram para a MESMA ficha',
  (select count(distinct cliente_id) from public.agendamentos
    where cliente_id in (select id from public.clientes
                          where perfil_id = 'cc000000-0000-0000-0000-0000000000cc')), 1);

-- O telefone de OUTRA pessoa não pode ser tomado: a outra trava, ux_cli_tel,
-- derrubaria a marcação inteira — e a pessoa está aqui para marcar horário,
-- não para arrumar cadastro.
insert into public.clientes (id, salao_id, nome, telefone) values
  ('cc000000-0000-0000-0000-0000000000dd',
   '11111111-0000-0000-0000-000000000001', 'Outra Pessoa', '51955443322')
on conflict (id) do nothing;

-- Libera uma vaga: o freio de spam para em 3 marcações abertas, e ela já tem
-- duas das de cima. Não é o que este bloco está medindo.
update public.agendamentos set status = 'cancelado'
 where cliente_id in (select id from public.clientes
                       where perfil_id = 'cc000000-0000-0000-0000-0000000000cc');

select t_texto('marcar com um número que já é de outra ficha não derruba nada',
  erro_de($$
    do $x$ begin
      perform set_config('request.jwt.claim.sub',
                         'cc000000-0000-0000-0000-0000000000cc', true);
      perform public.agendar(
        '22222222-0000-0000-0000-000000000001'::uuid,
        (select min(h) from public.horarios_livres(
           '22222222-0000-0000-0000-000000000001'::uuid, dia_cliente() + 9,
           array['33333333-0000-0000-0000-000000000001'::uuid]) h),
        array['33333333-0000-0000-0000-000000000001'::uuid],
        'Ju Barbosa', '51955443322');
    end $x$;
  $$), null);

select t_texto('e o número da outra pessoa continua sendo dela',
  (select nome from public.clientes
    where salao_id = '11111111-0000-0000-0000-000000000001'
      and telefone = '51955443322'), 'Outra Pessoa');

-- A função que faz tudo isso é interna. Solta, deixaria qualquer visitante
-- criar e alterar ficha em QUALQUER salão — inclusive tomar um telefone.
select t_falso('ficha_do_cliente() não é chamável de fora',
  has_function_privilege('anon', 'public.ficha_do_cliente(uuid, text, text)', 'execute'));
select t_falso('nem por quem tem conta',
  has_function_privilege('authenticated', 'public.ficha_do_cliente(uuid, text, text)', 'execute'));

select t_ok('ficha do cliente: uma só por pessoa, mesmo trocando de número');
