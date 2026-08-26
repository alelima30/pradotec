-- ===========================================================================
-- AgendaPro — a jornada deixou de ser sugestão
--
-- Antes deste motor, o banco aceitava um agendamento às 03:00 num
-- profissional com jornada das 09:00 às 18:00. Não é hipótese: foi medido na
-- auditoria, com este mesmo banco, antes de uma linha ser escrita.
--
-- ⚠ A PRIMEIRA SEÇÃO DESFAZ O MOTOR DE PROPÓSITO.
-- Sem isso, todo o resto ficaria verde mesmo se o gatilho não existisse — o
-- banco de teste nasce com ele instalado. A seção 0 prova que a suíte SABE
-- ver o defeito, e só então o motor é recolocado e o resto roda.
--
-- Os números dos casos são os da especificação da Fase 1.
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-00000000000a', 'motor@teste.com');
insert into public.perfis (id, nome, telefone) values
  ('a0000000-0000-0000-0000-00000000000a', 'Dona Motor', '+5511900000401')
on conflict (id) do update set nome = excluded.nome;

insert into public.saloes (id, slug, nome, tipo, fuso) values
  ('a0000000-1111-0000-0000-00000000000a', 'salao-motor', 'Salão Motor',
   'salao', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status) values
  ('a0000000-1111-0000-0000-00000000000a', 'time', 'ativa');
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a0000000-0000-0000-0000-00000000000a',
   'a0000000-1111-0000-0000-00000000000a', 'dono', 'ativo');

-- Ana: 09:00–12:00 e 13:00–18:00. O buraco do meio é o almoço, e ele existe
-- como DUAS faixas de jornada — que é como o painel grava.
insert into public.profissionais (id, salao_id, nome, comissao_pct) values
  ('a0000000-2222-0000-0000-00000000000a', 'a0000000-1111-0000-0000-00000000000a', 'Ana', 40),
  ('a0000000-2222-0000-0000-00000000000b', 'a0000000-1111-0000-0000-00000000000a', 'Bia', 40);
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'a0000000-2222-0000-0000-00000000000a', g, '09:00', '12:00' from generate_series(0,6) g;
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'a0000000-2222-0000-0000-00000000000a', g, '13:00', '18:00' from generate_series(0,6) g;
-- Bia trabalha o dia inteiro: serve para provar que o problema de uma não
-- fecha a agenda da outra.
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'a0000000-2222-0000-0000-00000000000b', g, '09:00', '18:00' from generate_series(0,6) g;

insert into public.clientes (id, salao_id, nome, telefone) values
  ('a0000000-3333-0000-0000-00000000000a', 'a0000000-1111-0000-0000-00000000000a', 'Cliente Um',  '11922220001'),
  ('a0000000-3333-0000-0000-00000000000b', 'a0000000-1111-0000-0000-00000000000a', 'Cliente Dois','11922220002');

-- Amanhã, para nunca esbarrar na regra de "cedo demais" nem na data passada.
\set amanha '(current_date + 1)'

/* Atalho: monta um instante de amanhã, na hora de parede do salão. */
create or replace function h(t text) returns timestamptz
language sql stable as $$
  select ((current_date + 1) + t::time) at time zone 'America/Sao_Paulo'
$$;

/* Tenta marcar e devolve a mensagem do banco (null quando passou). */
create or replace function marcar(
  p_prof uuid, p_ini text, p_fim text, p_encaixe boolean default false,
  p_cliente uuid default 'a0000000-3333-0000-0000-00000000000a')
returns text language plpgsql as $$
begin
  insert into public.agendamentos
    (salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
     valor_previsto, encaixe)
  values ('a0000000-1111-0000-0000-00000000000a', p_cliente, p_prof,
          h(p_ini), h(p_fim), 'confirmado', 'recepcao', 100, p_encaixe);
  return null;
exception when others then
  return sqlerrm;
end $$;

\echo ''
\echo '0. A SUÍTE SABE VER O DEFEITO'

/* ⚠ Sem esta seção, tudo abaixo passaria com um gatilho que não faz nada.
   Aqui o motor é DESLIGADO e o defeito original é reproduzido: 03:00 numa
   jornada 09:00–18:00. Depois o gatilho volta, e a mesma marcação é
   recusada. É a diferença entre "o teste está verde" e "a regra existe". */
drop trigger if exists tg_agend_cabe on public.agendamentos;
select t_verdade('sem o gatilho, 03:00 entra numa jornada 09-18 (o defeito antigo)',
  marcar('a0000000-2222-0000-0000-00000000000b', '03:00', '04:00') is null);
delete from public.agendamentos where inicio = h('03:00');

create trigger tg_agend_cabe
  before insert or update of inicio, fim, profissional_id, status, encaixe
  on public.agendamentos
  for each row execute function public.checar_cabe_agendamento();

select t_verdade('com o gatilho de volta, a MESMA marcação é recusada',
  marcar('a0000000-2222-0000-0000-00000000000b', '03:00', '04:00') is not null);
select t_verdade('e a mensagem diz o motivo, não "erro"',
  marcar('a0000000-2222-0000-0000-00000000000b', '03:00', '04:00') like '%jornada%');

\echo ''
\echo 'CASO 1 · serviço de 30 min dentro da jornada'
select t_texto('14:00 às 14:30 entra',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:00', '14:30'), null);

\echo ''
\echo 'CASO 2 · o serviço TERMINA depois de a jornada acabar'
/* O erro mais comum deste tipo de sistema: conferir só o início. Às 17:30 a
   Ana ainda está trabalhando; um serviço de 90 minutos termina 19:00, e a
   jornada dela acaba 18:00. */
select t_verdade('17:30 + 90 min = 19:00 é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000a', '17:30', '19:00') is not null);
select t_texto('mas 17:00 às 18:00, que termina em cima da hora, entra',
  marcar('a0000000-2222-0000-0000-00000000000a', '17:00', '18:00'), null);

\echo ''
\echo 'CASO 3 e 4 · sobreposição parcial e encosto exato'
-- Já existe 14:00–14:30 (caso 1).
select t_verdade('14:15 às 14:45 (sobrepõe) é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:15', '14:45') is not null);
select t_verdade('13:45 às 14:15 (sobrepõe pelo outro lado) é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000a', '13:45', '14:15') is not null);
select t_verdade('14:00 às 14:30 exatamente igual é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:00', '14:30') is not null);
select t_texto('14:30 às 15:00, encostado no fim, ENTRA',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:30', '15:00'), null);

-- E a mensagem tem que dizer com quem está o horário — não "indisponível".
select t_verdade('a recusa por choque diz o nome e as horas',
  public.porque_nao_cabe('a0000000-2222-0000-0000-00000000000a',
    h('14:15'), h('14:45')) like '%Ana já tem Cliente Um das 14:00 às 14:30%');

\echo ''
\echo 'CASO 5 · o problema de uma não é o problema da outra'
select t_texto('a Bia entra às 14:00, mesma hora que a Ana está ocupada',
  marcar('a0000000-2222-0000-0000-00000000000b', '14:00', '15:00',
         false, 'a0000000-3333-0000-0000-00000000000b'), null);

\echo ''
\echo 'CASO 6 · o almoço, que é o buraco entre duas faixas'
select t_verdade('12:00 às 13:00 (o almoço da Ana) é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000a', '12:00', '13:00') is not null);
select t_verdade('e atravessar o almoço também: 11:30 às 13:30',
  marcar('a0000000-2222-0000-0000-00000000000a', '11:30', '13:30') is not null);
select t_verdade('encostar no almoço pelo fim da manhã tem que ENTRAR: 11:00 às 12:00',
  marcar('a0000000-2222-0000-0000-00000000000a', '11:00', '12:00') is null);

\echo ''
\echo 'CASO 9 · bloqueio manual'
insert into public.bloqueios (salao_id, profissional_id, inicio, fim, motivo)
values ('a0000000-1111-0000-0000-00000000000a', 'a0000000-2222-0000-0000-00000000000b',
        h('16:00'), h('17:00'), 'Dentista');
select t_verdade('em cima do bloqueio é RECUSADO',
  marcar('a0000000-2222-0000-0000-00000000000b', '16:00', '17:00') is not null);
select t_verdade('e a mensagem traz o MOTIVO que o dono escreveu',
  public.porque_nao_cabe('a0000000-2222-0000-0000-00000000000b',
    h('16:00'), h('17:00')) like '%Dentista%');

\echo ''
\echo 'O ENCAIXE — a exceção que tem nome, e o que ela NÃO fura'

/* ⚠ AQUI ESTÁ O CORAÇÃO DO DESENHO.
   Encaixe afrouxa a JORNADA e só. Se ele furasse bloqueio ou choque, teria
   virado um jeito de ignorar o sistema inteiro — e a recepção usaria, porque
   é mais rápido que resolver o conflito de verdade. */
select t_texto('encaixe entra fora da jornada (08:00, antes de a Ana abrir)',
  marcar('a0000000-2222-0000-0000-00000000000a', '08:00', '08:30', true), null);
select t_verdade('mas encaixe NÃO fura bloqueio',
  marcar('a0000000-2222-0000-0000-00000000000b', '16:00', '17:00', true) is not null);
select t_verdade('e encaixe NÃO fura choque de horário',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:00', '14:30', true) is not null);
select t_verdade('nem o almoço deixa de ser um bloqueio de jornada encaixável',
  marcar('a0000000-2222-0000-0000-00000000000a', '12:00', '12:30', true) is null);

-- E a tela precisa saber ANTES de oferecer o botão de encaixe.
select t_verdade('avaliar_horario marca como encaixável o que só quebra jornada',
  (public.avaliar_horario('a0000000-2222-0000-0000-00000000000a',
     h('07:00'), h('07:30')) ->> 'encaixavel')::boolean);
select t_falso('e NÃO marca como encaixável o que tem choque',
  (public.avaliar_horario('a0000000-2222-0000-0000-00000000000a',
     h('14:00'), h('14:30')) ->> 'encaixavel')::boolean);
select t_falso('nem o que tem bloqueio',
  (public.avaliar_horario('a0000000-2222-0000-0000-00000000000b',
     h('16:00'), h('16:30')) ->> 'encaixavel')::boolean);

\echo ''
\echo 'CASO 10 · cancelar devolve a cadeira'
update public.agendamentos set status = 'cancelado'
 where profissional_id = 'a0000000-2222-0000-0000-00000000000a' and inicio = h('14:00');
select t_texto('com o de 14:00 cancelado, o horário aceita outra pessoa',
  marcar('a0000000-2222-0000-0000-00000000000a', '14:00', '14:30',
         false, 'a0000000-3333-0000-0000-00000000000b'), null);

\echo ''
\echo 'CASO 11 e 12 · remarcar'
select id as remarcar from public.agendamentos
 where profissional_id = 'a0000000-2222-0000-0000-00000000000a'
   and inicio = h('17:00') \gset

select t_texto('remarcar para 15:30, que está livre, PASSA',
  (select null from (select 1) x where not exists (
     select 1 from (select public.porque_nao_cabe(
       'a0000000-2222-0000-0000-00000000000a', h('15:30'), h('16:30'),
       :'remarcar'::uuid) m) y where y.m is not null)), null);
update public.agendamentos set inicio = h('15:30'), fim = h('16:30')
 where id = :'remarcar';
select t_texto('e ficou gravado',
  (select to_char(inicio at time zone 'America/Sao_Paulo', 'HH24:MI')
     from public.agendamentos where id = :'remarcar'), '15:30');

select t_verdade('remarcar para cima de outro atendimento é RECUSADO',
  recusado(format($$update public.agendamentos
    set inicio = %L, fim = %L where id = %L$$,
    h('14:30'), h('15:00'), :'remarcar'::uuid)));

/* ⚠ REMARCAR NÃO PODE CONFLITAR CONSIGO MESMO.
   Sem o `p_ignorar`, um atendimento comparado com ele próprio sempre acha um
   choque — e ninguém consegue mudar nada de um horário sem mudar o horário. */
select t_texto('e o atendimento não conflita consigo mesmo',
  public.porque_nao_cabe('a0000000-2222-0000-0000-00000000000a',
    h('15:30'), h('16:30'), :'remarcar'::uuid), null);

\echo ''
\echo 'O QUE JÁ ESTAVA MARCADO CONTINUA PODENDO SER FECHADO'

/* ⚠ A ARMADILHA QUE ESTE ARQUIVO EXISTE PARA NÃO DEIXAR PASSAR.
   Existem agendamentos fora da jornada gravados antes desta regra — porque
   até ontem nada impedia. Se o gatilho revalidasse a jornada em toda troca de
   status, a recepção não conseguiria marcar nenhum deles como concluído,
   cancelado ou falta. O dia não fecharia, e a culpa pareceria do relatório. */
insert into public.agendamentos
  (salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
   valor_previsto, encaixe)
values ('a0000000-1111-0000-0000-00000000000a', 'a0000000-3333-0000-0000-00000000000a',
        'a0000000-2222-0000-0000-00000000000a', h('05:00'), h('05:30'),
        'confirmado', 'recepcao', 100, true);

-- Agora finge que ele é antigo: nasceu sem a marca de encaixe.
update public.agendamentos set encaixe = false where inicio = h('05:00');

select t_texto('um agendamento antigo, fora da jornada, ainda vira concluído',
  (select case when recusado(format(
     $$update public.agendamentos set status = 'concluido' where id = %L$$,
     (select id from public.agendamentos where inicio = h('05:00'))))
   then 'recusou' end), null);
select t_texto('e ficou concluído mesmo',
  (select status from public.agendamentos where inicio = h('05:00')), 'concluido');

-- Mas mexer no HORÁRIO dele revalida, e aí a regra nova vale.
select t_verdade('mover esse mesmo agendamento para outro horário fora da jornada é RECUSADO',
  recusado(format($$update public.agendamentos
    set inicio = %L, fim = %L where inicio = %L$$,
    h('04:00'), h('04:30'), h('05:00'))));

\echo ''
\echo 'A CLIENTE E A RECEPÇÃO ENXERGAM A MESMA AGENDA'

/* As duas perguntas — "quais horários servem" e "este horário serve" — passam
   a ler os mesmos auxiliares. Divergirem é o defeito que este arquivo
   existe para tornar impossível: aqui cada vaga oferecida pela primeira é
   conferida pela segunda. */
insert into public.servicos (id, salao_id, nome, duracao_min, intervalo_min,
                             preco, ativo, aceita_online)
values ('a0000000-4444-0000-0000-00000000000a', 'a0000000-1111-0000-0000-00000000000a',
        'Corte', 30, 0, 100, true, true);
insert into public.servicos_profissionais (servico_id, profissional_id)
values ('a0000000-4444-0000-0000-00000000000a', 'a0000000-2222-0000-0000-00000000000b');

select count(*) as n_vagas from public.horarios_livres(
  'a0000000-2222-0000-0000-00000000000b', (current_date + 1),
  array['a0000000-4444-0000-0000-00000000000a']::uuid[]) \gset

select t_verdade('a Bia tem vagas oferecidas', :n_vagas > 0);
select t_igual('e TODAS elas passam na conferência da recepção',
  (select count(*) from public.horarios_livres(
     'a0000000-2222-0000-0000-00000000000b', (current_date + 1),
     array['a0000000-4444-0000-0000-00000000000a']::uuid[]) v
    where public.porque_nao_cabe(
      'a0000000-2222-0000-0000-00000000000b', v, v + interval '30 minutes')
      is not null), 0);

-- E o contrário: nada dentro do bloqueio da Bia foi oferecido.
select t_igual('nenhuma vaga cai dentro do bloqueio',
  (select count(*) from public.horarios_livres(
     'a0000000-2222-0000-0000-00000000000b', (current_date + 1),
     array['a0000000-4444-0000-0000-00000000000a']::uuid[]) v
    where v >= h('16:00') and v < h('17:00')), 0);

\echo ''
\echo 'JORNADA CADASTRADA ERRADA NÃO PODE VIRAR HORÁRIO REPETIDO'

/* Duas faixas que se cruzam é erro de digitação comum, e o painel aceita.
   Sem costurar, o trecho comum saía duas vezes e a lista voltava no tempo. */
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'a0000000-2222-0000-0000-00000000000b', g, '17:00', '20:00' from generate_series(0,6) g;

select t_igual('as faixas 09-18 e 17-20 viram UMA faixa costurada',
  (select count(*) from public.jornada_costurada(
     'a0000000-2222-0000-0000-00000000000b', (current_date + 1))), 1);
select t_texto('que vai das 09:00 às 20:00',
  (select to_char(fim at time zone 'America/Sao_Paulo', 'HH24:MI')
     from public.jornada_costurada(
       'a0000000-2222-0000-0000-00000000000b', (current_date + 1))), '20:00');
select t_igual('e a Ana, com almoço de verdade no meio, continua com DUAS',
  (select count(*) from public.jornada_costurada(
     'a0000000-2222-0000-0000-00000000000a', (current_date + 1))), 2);

\echo ''
\echo 'QUEM AINDA NÃO CONFIGUROU A JORNADA CONSEGUE TRABALHAR'

/* ⚠ ESTA SEÇÃO EXISTE PORQUE A PRIMEIRA VERSÃO DO MOTOR ERRAVA AQUI.
   Ela recusava tudo quando não havia jornada — e um salão recém-cadastrado
   não tem jornada, porque preencher jornada é outro passo. Ele não
   conseguiria marcar NADA no primeiro dia e concluiria que o sistema não
   deixa trabalhar.

   Quem pegou foi o 01_agenda.test.sql, que já existia. */
insert into public.profissionais (id, salao_id, nome) values
  ('a0000000-2222-0000-0000-00000000000c',
   'a0000000-1111-0000-0000-00000000000a', 'Cida');
-- Cida não tem NENHUMA linha em `jornadas`.
select t_texto('sem jornada configurada, a recepção marca a qualquer hora',
  marcar('a0000000-2222-0000-0000-00000000000c', '06:00', '07:00'), null);
select t_texto('e não é encaixe: é ausência de regra, não exceção a ela',
  (select case when encaixe then 'encaixe' end from public.agendamentos
    where profissional_id = 'a0000000-2222-0000-0000-00000000000c'), null);

/* Mas ter jornada em OUTROS dias e não hoje é folga — e folga se respeita.
   É a diferença entre "não configurei" e "não trabalho neste dia". */
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'a0000000-2222-0000-0000-00000000000c', g, '09:00', '18:00'
    from generate_series(0,6) g
   where g <> extract(dow from current_date + 1)::int;

select t_verdade('com jornada nos outros dias, a folga de amanhã é RECUSADA',
  marcar('a0000000-2222-0000-0000-00000000000c', '10:00', '11:00') is not null);
select t_verdade('e o encaixe continua sendo o caminho para a exceção',
  marcar('a0000000-2222-0000-0000-00000000000c', '10:00', '11:00', true) is null);

\echo ''
\echo 'O QUE O NAVEGADOR ALCANÇA'

select t_falso('anon não pergunta pela jornada da equipe',
  has_function_privilege('anon',
    'public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid)', 'execute'));
select t_verdade('mas o painel logado pergunta',
  has_function_privilege('authenticated',
    'public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid)', 'execute'));
select t_falso('e ninguém alcança os auxiliares direto',
  has_function_privilege('authenticated', 'public.jornada_costurada(uuid, date)', 'execute'));

drop function if exists h(text);
drop function if exists marcar(uuid, text, text, boolean, uuid);
