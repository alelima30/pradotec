-- ===========================================================================
-- AgendaPro — a agenda pública (05_agenda.sql)
--
-- O que se prova aqui é o caminho da CLIENTE, que é o caminho de quem não fez
-- login e não pode ser confiado em nada: horários livres batendo com a
-- jornada, o almoço fora da lista, o ocupado fora da lista, e — o que mais
-- importa — a duração e o preço vindo do banco mesmo quando a chamada tenta
-- mandar outra coisa.
--
-- O cenário usa uma data FIXA no futuro para a semana não escorregar: teste
-- que muda de resultado conforme o dia em que roda não é teste.
-- ===========================================================================

\set ON_ERROR_STOP on
\o /dev/null

-- ── Cenário ────────────────────────────────────────────────────────────────
-- Uma segunda-feira bem no futuro, escolhida na mão. `dias_liberados` padrão
-- é 30, então o salão precisa liberar mais para ela caber na janela.
-- A data do cenário é a PRÓXIMA SEGUNDA a pelo menos uma semana daqui.
--
-- A primeira versão usava 05/01/2099, fixa, para a semana não escorregar. Não
-- serve: `dias_liberados()` trava a janela em 365 dias, então 2099 caía fora
-- e a função devolvia zero vaga em tudo. A trava está certa — agenda aberta
-- por 73 anos não é recurso, é descuido — quem estava errado era o cenário.
--
-- Calculada garante as duas coisas de que os testes precisam: cai sempre numa
-- segunda (a jornada do cenário é de segunda) e está longe o bastante para o
-- corte de "nada com menos de 30 minutos de antecedência" não interferir.
create or replace function dia_teste() returns date language sql stable as $f$
  select d + ((1 - extract(dow from d)::int + 7) % 7)
    from (select current_date + 7 as d) x
$f$;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@salao.com');

insert into public.saloes (id, slug, nome, tipo, fuso, cfg) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'salao-da-ana', 'Salão da Ana', 'salao',
   'America/Sao_Paulo', '{"diasLiberados": 120}'),
  -- Um salão suspenso, para provar que ele some da vitrine e recusa marcação.
  ('aaaaaaaa-0000-0000-0000-000000000002', 'salao-parado', 'Salão Parado', 'salao',
   'America/Sao_Paulo', '{"diasLiberados": 120}');

update public.saloes set status = 'suspenso'
 where id = 'aaaaaaaa-0000-0000-0000-000000000002';

insert into public.assinaturas (salao_id, plano, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'time', 'ativa'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'time', 'ativa');

insert into public.perfis (id, nome, telefone) values
  ('11111111-1111-1111-1111-111111111111', 'Ana Souza', '+5511988887777')
on conflict (id) do update set nome = excluded.nome,
  telefone = excluded.telefone;

insert into public.profissionais (id, salao_id, perfil_id, nome, comissao_pct) values
  ('bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Ana', 40),
  -- Segunda profissional, para o teste de "não faz esse serviço".
  ('bbbbbbbb-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001', null, 'Bia', 30);

-- Jornada de segunda com almoço: 09:00–12:00 e 13:00–18:00.
insert into public.jornadas (profissional_id, dia_semana, inicio, fim) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 1, '09:00', '12:00'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 1, '13:00', '18:00'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 1, '09:00', '18:00');

-- Corte de 30 min + 10 de intervalo = 40 min ocupados na agenda.
-- Escova de 60 min, sem intervalo.
insert into public.servicos (id, salao_id, nome, duracao_min, intervalo_min, preco) values
  ('cccccccc-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Corte',  30, 10,  60.00),
  ('cccccccc-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Escova', 60,  0,  80.00),
  -- Serviço de outro salão, para o teste de id colado na chamada.
  ('cccccccc-0000-0000-0000-000000000009',
   'aaaaaaaa-0000-0000-0000-000000000002', 'Corte de lá', 30, 0, 999.00);

-- ---------------------------------------------------------------------------
-- 1) A conta da duração e do preço
-- ---------------------------------------------------------------------------
select t_igual('corte sozinho ocupa 40 min (30 + 10 de intervalo)',
  public.duracao_dos_servicos('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]), 40);

select t_igual('corte + escova ocupam 100 min',
  public.duracao_dos_servicos('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    array['cccccccc-0000-0000-0000-000000000001',
          'cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[]), 100);

select t_igual('corte + escova custam 140',
  public.preco_dos_servicos('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    array['cccccccc-0000-0000-0000-000000000001',
          'cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[])::bigint, 140);

-- A Bia faz mecha em outro tempo e cobra outro preço.
insert into public.servicos_profissionais
  (servico_id, profissional_id, duracao_min, preco) values
  ('cccccccc-0000-0000-0000-000000000002',
   'bbbbbbbb-0000-0000-0000-000000000002', 90, 120.00);

select t_igual('a escova da Bia leva 90 min, não 60',
  public.duracao_dos_servicos('bbbbbbbb-0000-0000-0000-000000000002'::uuid,
    array['cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[]), 90);

select t_igual('e custa 120, não 80',
  public.preco_dos_servicos('bbbbbbbb-0000-0000-0000-000000000002'::uuid,
    array['cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[])::bigint, 120);

-- ---------------------------------------------------------------------------
-- 2) Quem faz o quê
-- ---------------------------------------------------------------------------
select t_verdade('sem cruzamento cadastrado, a Ana faz tudo',
  public.profissional_faz('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]));

select t_verdade('a Bia faz a escova, que está cadastrada para ela',
  public.profissional_faz('bbbbbbbb-0000-0000-0000-000000000002'::uuid,
    array['cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[]));

select t_falso('mas a Bia NÃO faz o corte: ela tem cruzamento, e o corte não está nele',
  public.profissional_faz('bbbbbbbb-0000-0000-0000-000000000002'::uuid,
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]));

-- ---------------------------------------------------------------------------
-- 3) Horários livres batem com a jornada
-- ---------------------------------------------------------------------------

-- Manhã 09:00–12:00 com serviço de 40 min, passo de 15:
--   09:00 … 11:15  →  a cada 15 min. 11:20 caberia, mas não está no passo
-- Tarde 13:00–18:00:
--   13:00 … 17:15  →  = 18 vagas
-- Total 28.
select t_igual('a manhã e a tarde somam 28 vagas de 40 min',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 28);

select t_verdade('a primeira vaga é 09:00 no fuso do salão',
  (select min(h) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]) h)
  = (dia_teste() + time '09:00') at time zone 'America/Sao_Paulo');

select t_verdade('a última é 17:15 — 17:20 não cai no passo de 15 min desde as 13:00',
  (select max(h) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]) h)
  = (dia_teste() + time '17:15') at time zone 'America/Sao_Paulo');

-- O ALMOÇO. Este é o caso que separa "duas linhas de jornada" de "uma linha
-- das 9 às 18": se o laço tratasse a jornada como um bloco só, 12:00 estaria
-- na lista, e a Ana receberia cliente na hora do almoço todo dia.
select t_igual('nenhuma vaga entre 11:30 e 13:00 — é o almoço',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]) h
    where (h at time zone 'America/Sao_Paulo')::time >= '11:30'
      and (h at time zone 'America/Sao_Paulo')::time <  '13:00'), 0);

-- Serviço mais longo cabe menos vezes. Corte + escova = 100 min:
--   manhã 09:00–12:00 → 09:00 … 10:15 =  6 vagas
--   tarde 13:00–18:00 → 13:00 … 16:15 = 14 vagas
select t_igual('serviço de 100 min cabe 20 vezes no mesmo dia',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001',
           'cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[])), 20);

-- Terça-feira: a Ana não tem jornada cadastrada.
select t_igual('dia sem jornada não oferece nada',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, (dia_teste() + 1),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 0);

-- ---------------------------------------------------------------------------
-- 4) Ocupado e bloqueado somem da lista
-- ---------------------------------------------------------------------------
insert into public.clientes (id, salao_id, nome, telefone) values
  ('dddddddd-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Maria', '11977776666');

-- Alguém já marcou das 10:00 às 10:40.
insert into public.agendamentos
  (salao_id, cliente_id, profissional_id, inicio, fim) values
  ('aaaaaaaa-0000-0000-0000-000000000001',
   'dddddddd-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001',
   (dia_teste() + time '10:00') at time zone 'America/Sao_Paulo',
   (dia_teste() + time '10:40') at time zone 'America/Sao_Paulo');

-- Some 09:30, 09:45, 10:00, 10:15, 10:30 — todo início cujo intervalo de 40
-- min encosta no que já está marcado. São 5 vagas a menos: 28 → 23.
select t_igual('um agendamento de 40 min derruba 5 vagas vizinhas',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 23);

select t_igual('e o próprio 10:00 não aparece mais',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]) h
    where h = (dia_teste() + time '10:00') at time zone 'America/Sao_Paulo'), 0);

-- Bloqueio do SALÃO INTEIRO (profissional_id nulo) na tarde toda.
insert into public.bloqueios (salao_id, profissional_id, inicio, fim, motivo) values
  ('aaaaaaaa-0000-0000-0000-000000000001', null,
   (dia_teste() + time '13:00') at time zone 'America/Sao_Paulo',
   (dia_teste() + time '18:00') at time zone 'America/Sao_Paulo',
   'Feriado municipal');

select t_igual('bloqueio do salão inteiro apaga a tarde: sobram as 5 da manhã',
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 5);

delete from public.bloqueios;
delete from public.agendamentos;

-- ---------------------------------------------------------------------------
-- 5) A janela de dias liberados
-- ---------------------------------------------------------------------------
update public.saloes set cfg = '{"diasLiberados": 7}'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';

select t_texto('além da janela, recusa dizendo até quando vai',
  left(public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    public.hoje_no_salao('aaaaaaaa-0000-0000-0000-000000000001'::uuid) + 8,
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]), 26),
  'A agenda está liberada até');

select t_texto('data que já passou é recusada',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
    public.hoje_no_salao('aaaaaaaa-0000-0000-0000-000000000001'::uuid) - 1,
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]),
  'Essa data já passou.');

update public.saloes set cfg = '{"diasLiberados": 120}'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- 6) O que a função recusa antes de olhar horário
-- ---------------------------------------------------------------------------
select t_texto('sem serviço nenhum, recusa',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
    array[]::uuid[]),
  'Escolha pelo menos um serviço.');

select t_texto('serviço de OUTRO salão colado na chamada é recusado',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
    array['cccccccc-0000-0000-0000-000000000009'::uuid]::uuid[]),
  'Um dos serviços escolhidos não está disponível.');

select t_texto('profissional que não faz o serviço é recusado',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000002'::uuid, dia_teste(),
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]),
  'Este profissional não faz todos os serviços escolhidos.');

update public.profissionais set aceita_online = false
 where id = 'bbbbbbbb-0000-0000-0000-000000000001';
select t_texto('profissional fora da agenda online é recusado',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
    array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]),
  'Este profissional não está atendendo pela agenda online.');
update public.profissionais set aceita_online = true
 where id = 'bbbbbbbb-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- 7) agendar() — o caminho feliz
-- ---------------------------------------------------------------------------
select t_igual('marcou: uma linha em agendamentos',
  (select count(*) from public.agendar(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
     (dia_teste() + time '09:00') at time zone 'America/Sao_Paulo',
     array['cccccccc-0000-0000-0000-000000000001',
           'cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[],
     'Joana Ribeiro', '(51) 99887-6655')), 1);

select t_igual('o fim veio do banco: 100 minutos depois do início',
  (select extract(epoch from (a.fim - a.inicio))::bigint / 60
     from public.agendamentos a), 100);

select t_igual('o valor veio do banco: 140, não do formulário',
  (select valor_previsto::bigint from public.agendamentos), 140);

select t_texto('a origem ficou marcada como online',
  (select origem from public.agendamentos), 'online');

select t_igual('os dois serviços foram copiados para o agendamento',
  (select count(*) from public.agendamento_servicos), 2);

select t_igual('e a comissão copiada é a da profissional: 40%',
  (select distinct comissao_pct::bigint from public.agendamento_servicos), 40);

select t_texto('o telefone foi guardado só com dígitos',
  (select telefone from public.clientes where nome = 'Joana Ribeiro'),
  '51998876655');

-- Segunda marcação com o telefone escrito de outro jeito: tem que cair na
-- MESMA ficha. Sem `so_digitos`, nasceria uma segunda Joana.
select t_igual('marcou de novo, com o telefone formatado diferente',
  (select count(*) from public.agendar(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
     (dia_teste() + time '14:00') at time zone 'America/Sao_Paulo',
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
     'Joana Ribeiro', '51998876655')), 1);

select t_igual('e continua tendo UMA ficha de cliente, não duas',
  (select count(*) from public.clientes where salao_id =
     'aaaaaaaa-0000-0000-0000-000000000001'::uuid), 2);  -- Maria + Joana

-- ---------------------------------------------------------------------------
-- 8) agendar() — o que ele recusa
-- ---------------------------------------------------------------------------
select t_texto('horário já ocupado é recusado com frase de gente',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Outra Pessoa', '51988887777')$f$,
    (dia_teste() + time '09:00') at time zone 'America/Sao_Paulo')),
  'Esse horário não está mais livre. Escolha outro, por favor.');

select t_texto('horário fora da jornada (07:00) é recusado',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Outra Pessoa', '51988887777')$f$,
    (dia_teste() + time '07:00') at time zone 'America/Sao_Paulo')),
  'Esse horário não está mais livre. Escolha outro, por favor.');

select t_texto('horário no meio do almoço (12:15) é recusado',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Outra Pessoa', '51988887777')$f$,
    (dia_teste() + time '12:15') at time zone 'America/Sao_Paulo')),
  'Esse horário não está mais livre. Escolha outro, por favor.');

-- Encaixe FORA do passo de 15 minutos. Uma chamada montada na mão poderia
-- pedir 09:07 e furar a grade da agenda inteira.
select t_texto('horário fora do passo de 15 min (09:07) é recusado',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Outra Pessoa', '51988887777')$f$,
    (dia_teste() + time '09:07') at time zone 'America/Sao_Paulo')),
  'Esse horário não está mais livre. Escolha outro, por favor.');

select t_texto('sem nome, recusa',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      '   ', '51988887777')$f$,
    (dia_teste() + time '15:00') at time zone 'America/Sao_Paulo')),
  'Diga seu nome para a gente saber quem esperar.');

select t_texto('telefone sem DDD é recusado',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Fulana', '99887766')$f$,
    (dia_teste() + time '15:00') at time zone 'America/Sao_Paulo')),
  'Confira o telefone: precisa do DDD.');

-- ---------------------------------------------------------------------------
-- 9) O freio de spam
--
-- A Joana já tem 2 marcações futuras. A terceira passa, a quarta não.
-- ---------------------------------------------------------------------------
select t_igual('a terceira marcação da mesma pessoa ainda passa',
  (select count(*) from public.agendar(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
     (dia_teste() + time '15:00') at time zone 'America/Sao_Paulo',
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
     'Joana Ribeiro', '51998876655')), 1);

select t_texto('a quarta é barrada',
  public.erro_de(format($f$
    select public.agendar('bbbbbbbb-0000-0000-0000-000000000001'::uuid,
      timestamptz %L, array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
      'Joana Ribeiro', '51998876655')$f$,
    (dia_teste() + time '16:00') at time zone 'America/Sao_Paulo')),
  'Você já tem 3 horários marcados aqui. Cancele um antes de marcar outro.');

-- Cancelou uma: volta a caber.
update public.agendamentos set status = 'cancelado'
 where inicio = (dia_teste() + time '15:00') at time zone 'America/Sao_Paulo';

select t_igual('depois de cancelar uma, cabe outra',
  (select count(*) from public.agendar(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid,
     (dia_teste() + time '16:00') at time zone 'America/Sao_Paulo',
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[],
     'Joana Ribeiro', '51998876655')), 1);

-- ---------------------------------------------------------------------------
-- 10) Salão suspenso
--
-- Deixou de pagar, ou foi desligado. A vitrine e a marcação fecham juntas —
-- se só a vitrine fechasse, o link antigo que a cliente salvou continuaria
-- marcando horário num salão que não atende mais.
-- ---------------------------------------------------------------------------
insert into public.profissionais (id, salao_id, nome) values
  ('bbbbbbbb-0000-0000-0000-000000000009',
   'aaaaaaaa-0000-0000-0000-000000000002', 'Zé');
insert into public.jornadas (profissional_id, dia_semana, inicio, fim) values
  ('bbbbbbbb-0000-0000-0000-000000000009', 1, '09:00', '18:00');

select t_texto('salão suspenso recusa marcação',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000009'::uuid, dia_teste(),
    array['cccccccc-0000-0000-0000-000000000009'::uuid]::uuid[]),
  'Este profissional não está atendendo pela agenda online.');

select t_igual('e não aparece na vitrine pública',
  (select count(*) from public.profissionais_publicos
    where salao_id = 'aaaaaaaa-0000-0000-0000-000000000002'::uuid), 0);

-- ---------------------------------------------------------------------------
-- 11) A cota do plano na vitrine
--
-- O salão cai do plano de 5 para o gratuito, que comporta 1. A partir daí a
-- vitrine só pode mostrar 1 — senão a cliente escolhe a Bia e leva um erro do
-- gatilho de cota na cara.
-- ---------------------------------------------------------------------------
select t_igual('no plano time, a vitrine mostra as duas profissionais',
  (select count(*) from public.profissionais_publicos
    where salao_id = 'aaaaaaaa-0000-0000-0000-000000000001'::uuid), 2);

update public.assinaturas set status = 'cancelada'
 where salao_id = 'aaaaaaaa-0000-0000-0000-000000000001';

select t_texto('o plano efetivo virou gratuito',
  public.plano_efetivo('aaaaaaaa-0000-0000-0000-000000000001'::uuid), 'gratuito');

select t_igual('e a vitrine passa a mostrar só a primeira',
  (select count(*) from public.profissionais_publicos
    where salao_id = 'aaaaaaaa-0000-0000-0000-000000000001'::uuid), 1);

select t_texto('a segunda passa a recusar marcação, em vez de aceitar e falhar',
  public.porque_nao_agenda('bbbbbbbb-0000-0000-0000-000000000002'::uuid, dia_teste(),
    array['cccccccc-0000-0000-0000-000000000002'::uuid]::uuid[]),
  'Este profissional não está atendendo pela agenda online.');

-- ---------------------------------------------------------------------------
-- 11b) horarios_livres_periodo(): a tela inteira numa pergunta só
--
-- Ela existe para a tela da cliente não precisar de 84 requisições para pintar
-- a faixa de dias. O que estes testes cobram é a única coisa que importa:
-- responder EXATAMENTE o mesmo que a função de um dia. Se as duas puderem
-- discordar, um dia vão — e a discordância aparece como cliente marcando em
-- cima de cliente.
-- ---------------------------------------------------------------------------
-- Nada de número mágico aqui. A primeira versão cobrava "28 vagas", copiado
-- da seção 3 — mas lá em cima o dia estava limpo, e a esta altura do arquivo
-- os testes de agendar() já ocuparam cadeiras. O teste falhou por 11 ≠ 28 e o
-- defeito era do teste. A comparação certa nunca foi com um número: é com a
-- outra função, no mesmo instante, com o mesmo banco.
select t_igual('o período de um dia devolve tantas vagas quanto o dia solto',
  (select count(*) from public.horarios_livres_periodo(
     array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
     dia_teste(), dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])),
  (select count(*) from public.horarios_livres(
     'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])));

select t_verdade('e são os mesmos instantes, não só a mesma quantidade',
  (select array_agg(inicio order by inicio)
     from public.horarios_livres_periodo(
       array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
       dia_teste(), dia_teste(),
       array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]))
  = (select array_agg(h order by h) from public.horarios_livres(
       'bbbbbbbb-0000-0000-0000-000000000001'::uuid, dia_teste(),
       array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[]) h));

select t_verdade('cada linha diz de quem é o horário',
  (select bool_and(profissional_id = 'bbbbbbbb-0000-0000-0000-000000000001'::uuid)
     from public.horarios_livres_periodo(
       array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
       dia_teste(), dia_teste(),
       array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])));

-- Sem isso, a tela mostraria "12 vagas" embaixo de uma terça em que ninguém
-- trabalha, e a pessoa clicaria num dia vazio.
select t_igual('dia sem jornada não entra no período',
  (select count(*) from public.horarios_livres_periodo(
     array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
     dia_teste() + 1, dia_teste() + 1,
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 0);

-- A janela de 62 dias não é enfeite: sem ela, uma chamada pedindo dois anos
-- faria o banco varrer 730 dias × cada profissional para responder a uma tela
-- que mostra 28.
select t_igual('o período é limitado a 62 dias, mesmo pedindo um ano',
  (select count(distinct (inicio at time zone 'America/Sao_Paulo')::date)
     from public.horarios_livres_periodo(
       array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
       dia_teste(), dia_teste() + 365,
       array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])
    where (inicio at time zone 'America/Sao_Paulo')::date > dia_teste() + 62), 0);

select t_igual('período invertido devolve vazio em vez de erro',
  (select count(*) from public.horarios_livres_periodo(
     array['bbbbbbbb-0000-0000-0000-000000000001'::uuid],
     dia_teste() + 5, dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 0);

select t_igual('lista de profissionais vazia devolve vazio, não erro',
  (select count(*) from public.horarios_livres_periodo(
     '{}'::uuid[], dia_teste(), dia_teste(),
     array['cccccccc-0000-0000-0000-000000000001'::uuid]::uuid[])), 0);

select t_verdade('anon pode executar horarios_livres_periodo',
  has_function_privilege('anon',
    'public.horarios_livres_periodo(uuid[], date, date, uuid[])', 'execute'));

-- ---------------------------------------------------------------------------
-- 12) Quem pode chamar
--
-- `anon` chama as duas funções e continua SEM enxergar as tabelas. É o ponto
-- inteiro do `security definer`: a cliente vê horário vago sem ver a agenda.
-- ---------------------------------------------------------------------------
select t_verdade('anon pode executar horarios_livres',
  has_function_privilege('anon',
    'public.horarios_livres(uuid, date, uuid[])', 'execute'));

select t_verdade('anon pode executar agendar',
  has_function_privilege('anon',
    'public.agendar(uuid, timestamptz, uuid[], text, text, text, text)', 'execute'));

select t_falso('mas anon NÃO lê a tabela de agendamentos',
  has_table_privilege('anon', 'public.agendamentos', 'select'));

select t_falso('nem a de clientes',
  has_table_privilege('anon', 'public.clientes', 'select'));

select t_falso('nem a de jornadas',
  has_table_privilege('anon', 'public.jornadas', 'select'));

select t_falso('nem a de bloqueios',
  has_table_privilege('anon', 'public.bloqueios', 'select'));

-- ---------------------------------------------------------------------------
-- 13) AS TRÊS VISTAS PÚBLICAS CONTINUAM FECHADAS
--
-- Este bloco existe porque o mesmo defeito apareceu duas vezes, em arquivos
-- diferentes: o 02_rls.sql concedia as três vistas e o 06 revogava; depois
-- descobri que o 05, no fim, concedia `profissionais_publicos` de novo. Nos
-- dois casos a instalação completa saía certa — 06 roda por último — e nos
-- dois casos reaplicar o arquivo sozinho reabria a enumeração da carteira de
-- clientes da plataforma.
--
-- Um teste por arquivo não pegaria o terceiro. Este pergunta pelo ESTADO, que
-- é o que importa: depois de tudo instalado, ninguém enxerga as três. Quem
-- adicionar um grant novo em qualquer arquivo reprova aqui.
-- ---------------------------------------------------------------------------
select t_falso('anon não folheia o catálogo de salões',
  has_table_privilege('anon', 'public.saloes_publicos', 'select'));
select t_falso('nem o de serviços',
  has_table_privilege('anon', 'public.servicos_publicos', 'select'));
select t_falso('nem o de profissionais',
  has_table_privilege('anon', 'public.profissionais_publicos', 'select'));

-- E quem fez login também não: criar conta leva dois minutos, então deixar
-- aberto para `authenticated` seria a mesma porta com um degrau na frente.
select t_falso('quem tem conta também não folheia',
  has_table_privilege('authenticated', 'public.saloes_publicos', 'select'));
select t_falso('nem o de profissionais, com conta',
  has_table_privilege('authenticated', 'public.profissionais_publicos', 'select'));

-- O caminho que SUBSTITUIU o catálogo continua aberto: quem tem o apelido
-- entra. Sem isto, o teste acima ficaria satisfeito com tudo trancado — e o
-- link da cliente parado.
select t_verdade('mas quem sabe o apelido entra pela vitrine',
  has_function_privilege('anon', 'public.vitrine(text)', 'execute'));

select t_ok('agenda pública: tudo conferido');
