-- ===========================================================================
-- AgendaPro — o painel de quem é dono da plataforma
--
-- Uma conta super_admin lê a clientela e o faturamento de TODOS os salões. É
-- a credencial mais perigosa do sistema, então o que se prova aqui é menos
-- "funciona" e mais "não abre para quem não é".
-- ===========================================================================

\set ON_ERROR_STOP on
\o /dev/null

insert into auth.users (id) values
  ('aa000000-0000-0000-0000-00000000000a'),   -- Ana, dona de salão
  ('ee000000-0000-0000-0000-00000000000e'),   -- Você, dono da plataforma
  ('cc000000-0000-0000-0000-00000000000c');   -- Cliente qualquer

insert into public.perfis (id, nome, telefone, super_admin) values
  ('aa000000-0000-0000-0000-00000000000a', 'Ana',        '+5511900000101', false),
  ('ee000000-0000-0000-0000-00000000000e', 'Plataforma', '+5511900000102', true),
  ('cc000000-0000-0000-0000-00000000000c', 'Maria',      '+5511900000103', false);

insert into public.saloes (id, slug, nome, fuso) values
  ('50000000-0000-0000-0000-00000000000a', 'salao-a', 'Salão A', 'America/Sao_Paulo'),
  ('50000000-0000-0000-0000-00000000000b', 'salao-b', 'Barbearia B', 'America/Sao_Paulo');

insert into public.assinaturas (salao_id, plano, status, trial_ate) values
  ('50000000-0000-0000-0000-00000000000a', 'individual', 'ativa', null),
  ('50000000-0000-0000-0000-00000000000b', 'trial', 'trial', current_date + 3);

update public.assinaturas set vence_em = current_date + 20
 where salao_id = '50000000-0000-0000-0000-00000000000a';

insert into public.vinculos (perfil_id, salao_id, papel) values
  ('aa000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-00000000000a', 'dono');

grant usage on schema auth to anon, authenticated;

\echo ''
\echo 'A porta: quem NÃO é da plataforma não entra'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'aa000000-0000-0000-0000-00000000000a';

  do $$ begin
    if recusado($q$select public.painel_plataforma()$q$)
    then perform t_ok('a dona de salão não abre o painel da plataforma');
    else perform t_falha('A DONA DE SALÃO ABRIU O PAINEL — ela vê o faturamento de todo mundo');
    end if;
  end $$;

  do $$ begin
    if recusado($q$select public.definir_plano(
         '50000000-0000-0000-0000-00000000000a', 'salao')$q$)
    then perform t_ok('e não se põe no plano maior por função');
    else perform t_falha('SE PROMOVEU DE PLANO pela função');
    end if;
  end $$;

  do $$ begin
    if recusado($q$select public.definir_status_salao(
         '50000000-0000-0000-0000-00000000000b', 'suspenso')$q$)
    then perform t_ok('nem suspende o salão do concorrente');
    else perform t_falha('SUSPENDEU O SALÃO DO VIZINHO');
    end if;
  end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'cc000000-0000-0000-0000-00000000000c';
  do $$ begin
    if recusado($q$select public.painel_plataforma()$q$)
    then perform t_ok('uma cliente qualquer também não entra');
    else perform t_falha('UMA CLIENTE ABRIU O PAINEL DA PLATAFORMA');
    end if;
  end $$;
rollback;

\echo ''
\echo 'E ninguém se promove sozinho'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'aa000000-0000-0000-0000-00000000000a';

  do $$
  begin
    perform recusado($q$update public.perfis set super_admin = true
                         where id = 'aa000000-0000-0000-0000-00000000000a'$q$);
    -- Recusado ou não, o que importa é o EFEITO. A policy pode deixar o
    -- update passar e o `with check` barrar a linha nova — nos dois casos o
    -- valor tem que continuar falso.
    if (select super_admin from public.perfis
         where id = 'aa000000-0000-0000-0000-00000000000a')
    then perform t_falha('VIROU DONA DA PLATAFORMA editando o próprio perfil');
    else perform t_ok('editar o próprio perfil não promove ninguém');
    end if;
  end $$;
rollback;

\echo ''
\echo 'A plataforma vê o negócio inteiro'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'ee000000-0000-0000-0000-00000000000e';

  do $$
  declare v jsonb;
  begin
    v := public.painel_plataforma();
    perform t_verdade('o painel abre para a plataforma', v is not null);

    perform t_igual('conta os 2 salões ativos',
                    (v->'resumo'->>'saloes')::bigint, 2);

    -- O que separa receita de esperança: um está pagando, o outro está
    -- testando. Somar os dois é como um salão somar orçamento com caixa.
    perform t_igual('1 pagante', (v->'resumo'->>'pagantes')::bigint, 1);
    perform t_igual('1 em teste', (v->'resumo'->>'em_teste')::bigint, 1);
    perform t_igual('o MRR é só do que paga: R$ 47',
                    (v->'resumo'->>'mrr')::numeric::bigint, 47);

    -- Quem vence esta semana é para quem se liga. Depois de vencido, já virou
    -- "aquele sistema que eu testei uma vez".
    perform t_igual('1 teste vencendo em 7 dias',
                    jsonb_array_length(v->'vencendo')::bigint, 1);
    perform t_texto('e é a Barbearia B',
                    v->'vencendo'->0->>'nome', 'Barbearia B');

    perform t_igual('a lista traz os 2 salões',
                    jsonb_array_length(v->'saloes')::bigint, 2);
    perform t_verdade('com os planos da plataforma junto',
                      jsonb_array_length(v->'planos') >= 6);
  end $$;

  -- Mudar plano: o efeito tem que ser o que a tela vai mostrar.
  do $$
  declare v jsonb;
  begin
    v := public.definir_plano('50000000-0000-0000-0000-00000000000b', 'time');
    perform t_texto('a plataforma muda o plano de um salão',
                    v->>'plano', 'time');
    perform t_texto('e o plano EFETIVO acompanha na hora',
                    v->>'planoEfetivo', 'time');

    -- A armadilha silenciosa: 'ativa' sem vencimento é o plano que nunca
    -- vence. A função põe 30 dias quando ninguém disse nada.
    perform t_verdade('assinatura ativa nunca sai sem data de vencimento',
                      (v->>'venceEm') is not null);
  end $$;

  do $$
  declare v jsonb;
  begin
    -- E o contrário: marcar 'ativa' com data já vencida tem que aparecer na
    -- hora, no plano efetivo, e não daqui a um mês.
    v := public.definir_plano('50000000-0000-0000-0000-00000000000b',
                              'salao', 'ativa', current_date - 1);
    perform t_texto('plano ativo com data vencida cai para gratuito na hora',
                    v->>'planoEfetivo', 'gratuito');
  end $$;

  do $$
  declare v jsonb;
  begin
    v := public.definir_status_salao('50000000-0000-0000-0000-00000000000b', 'suspenso');
    perform t_texto('a plataforma suspende um salão', v->>'para', 'suspenso');
    perform t_verdade('e ele some da vitrine na hora',
                      public.vitrine('salao-b') is null);
  end $$;

  do $$ begin
    if recusado($q$select public.definir_plano(
         '50000000-0000-0000-0000-00000000000a', 'plano-que-nao-existe')$q$)
    then perform t_ok('plano inventado é recusado, em vez de gravado');
    else perform t_falha('gravou um plano que não existe');
    end if;
  end $$;
rollback;

select t_ok('plataforma: tudo conferido');
