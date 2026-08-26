-- ===========================================================================
-- AgendaPro — 07: o painel de quem é dono da plataforma
--
-- O `super_admin` já existia no schema e já destrancava tudo: `tem_acesso()`
-- devolve verdadeiro para ele em qualquer salão, e as policies de `planos` e
-- `assinaturas` só deixam ELE escrever. O que faltava era o outro lado — um
-- lugar de onde olhar o negócio inteiro, e um jeito de mudar o plano de um
-- salão sem digitar UPDATE na mão às onze da noite.
--
-- ── COMO ALGUÉM VIRA SUPER_ADMIN ───────────────────────────────────────────
-- Só por SQL, rodado no painel do Supabase. Não existe tela, não existe botão,
-- não existe chamada de API que promova ninguém — e o teste
-- 02_rls.test.sql prova que nem editando o próprio perfil dá:
--
--     ✓ não consegue se tornar dona da plataforma
--
-- É de propósito. Uma conta super_admin lê a clientela e o faturamento de
-- TODOS os salões. Se houvesse caminho pela aplicação, esse caminho seria o
-- alvo — e um dia alguém acharia a ponta solta. Sem caminho, a única porta é
-- o painel do Supabase, que já exige a senha do projeto.
--
-- O comando está em tests/promover_admin.sql, com as instruções.
--
-- ── DUAS COISAS QUE VALEM A DISCIPLINA ─────────────────────────────────────
-- 1. Use uma conta SEPARADA da que você usa como dono de salão. Se um dia
--    você emprestar a tela para alguém ver, ou deixar a sessão aberta num
--    computador, o estrago é do tamanho da conta que estava logada.
-- 2. Ligue a verificação em dois passos nessa conta, no painel do Supabase.
--    É a única credencial do sistema cuja perda não tem conserto parcial.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) O retrato do negócio
--
-- Uma chamada, um JSON. Poderia ser meia dúzia de consultas da tela, mas aí a
-- regra de "o que conta como receita" estaria escrita no JavaScript — e
-- receita conferida no navegador é receita que a primeira mudança de tela
-- desalinha.
-- ---------------------------------------------------------------------------
create or replace function public.painel_plataforma()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_hoje date := current_date;
begin
  if not public.is_super() then
    raise exception 'Só a plataforma abre este painel.'
      using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(

    -- ── Os números do topo ────────────────────────────────────────────────
    'resumo', (
      select jsonb_build_object(
        'saloes',        count(*) filter (where s.status = 'ativo'),
        'suspensos',     count(*) filter (where s.status <> 'ativo'),
        -- Pagante é quem está num plano com preço, em vigor. Trial não é
        -- receita: é esperança. Contar os dois juntos é como um dono de salão
        -- somar orçamento com caixa.
        'pagantes',      count(*) filter (
                           where s.status = 'ativo'
                             and coalesce(pl.preco_mes, 0) > 0),
        'em_teste',      count(*) filter (
                           where s.status = 'ativo' and a.status = 'trial'
                             and (a.trial_ate is null or a.trial_ate >= v_hoje)),
        'no_gratuito',   count(*) filter (
                           where s.status = 'ativo'
                             and coalesce(pl.preco_mes, 0) = 0
                             and coalesce(a.status, 'x') <> 'trial'),
        'inadimplentes', count(*) filter (where a.status = 'inadimplente'),
        -- Receita recorrente do mês: a soma do que os salões ativos pagam
        -- HOJE, pelo plano que vale hoje.
        'mrr',           coalesce(sum(pl.preco_mes) filter (
                           where s.status = 'ativo'), 0)
      )
      from public.saloes s
      left join public.assinaturas a on a.salao_id = s.id
      left join public.planos pl on pl.codigo = public.plano_efetivo(s.id)
    ),

    -- ── Quem precisa de um telefonema esta semana ─────────────────────────
    -- O teste que vence é o momento em que o salão decide ficar ou sumir, e é
    -- a única hora em que uma ligação muda o resultado. Depois de vencido, já
    -- virou "aquele sistema que eu testei uma vez".
    'vencendo', coalesce((
      select jsonb_agg(x order by x->>'trialAte')
      from (
        select jsonb_build_object(
          'id', s.id, 'nome', s.nome, 'slug', s.slug,
          'whatsapp', coalesce(s.whatsapp, s.telefone),
          'trialAte', a.trial_ate,
          'faltam', a.trial_ate - v_hoje,
          -- Quem usou o sistema tem chance de virar cliente; quem cadastrou e
          -- nunca voltou, não. O número diz para quem ligar primeiro.
          'agendamentos', (select count(*) from public.agendamentos ag
                            where ag.salao_id = s.id)
        ) as x
        from public.saloes s
        join public.assinaturas a on a.salao_id = s.id
        where s.status = 'ativo' and a.status = 'trial'
          and a.trial_ate between v_hoje and v_hoje + 7
      ) t), '[]'::jsonb),

    -- ── A lista, com o que decide conversa ────────────────────────────────
    'saloes', coalesce((
      select jsonb_agg(x order by x->>'nome')
      from (
        select jsonb_build_object(
          'id', s.id, 'nome', s.nome, 'slug', s.slug, 'tipo', s.tipo,
          'status', s.status,
          'criadoEm', s.criado_em,
          'whatsapp', coalesce(s.whatsapp, s.telefone),
          'plano', public.plano_efetivo(s.id),
          'planoNome', (select nome from public.planos
                         where codigo = public.plano_efetivo(s.id)),
          'preco', (select preco_mes from public.planos
                     where codigo = public.plano_efetivo(s.id)),
          'assinatura', a.status,
          'trialAte', a.trial_ate,
          'venceEm', a.vence_em,
          'origem', a.origem,
          'profissionais', (select count(*) from public.profissionais p
                             where p.salao_id = s.id and p.ativo),
          'limite', public.limite_profissionais(s.id),
          -- Uso do mês corrente, no fuso do salão. É o número que diz se o
          -- salão está VIVO — plano pago com zero agendamento é cancelamento
          -- esperando acontecer.
          'agendamentosMes', (
            select count(*) from public.agendamentos ag
             where ag.salao_id = s.id
               and ag.status in ('pendente','confirmado','em_atendimento','concluido')
               and ag.arquivado_em is null
               and (ag.inicio at time zone s.fuso)::date
                   >= date_trunc('month', (now() at time zone s.fuso))::date),
          'ultimoAgendamento', (
            select max(ag.criado_em) from public.agendamentos ag
             where ag.salao_id = s.id)
        ) as x
        from public.saloes s
        left join public.assinaturas a on a.salao_id = s.id
      ) t), '[]'::jsonb),

    'planos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'codigo', codigo, 'nome', nome, 'preco', preco_mes,
               'maxProfissionais', max_profissionais, 'ativo', ativo)
             order by ordem, preco_mes)
        from public.planos), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 2) Mudar o plano de um salão
--
-- A policy já deixa o super_admin escrever direto em `assinaturas`. Esta
-- função existe mesmo assim por dois motivos:
--
--   · UPDATE na mão erra. Trocar o plano sem mexer no `status`, ou marcar
--     'ativa' esquecendo o `vence_em`, deixa o salão num estado que só
--     aparece semanas depois — no dia em que ele para de funcionar sem
--     motivo, ou continua funcionando sem pagar.
--   · `atualizado_em` passa a ser sempre verdade. Sem isso a coluna mente, e
--     uma coluna que mente é pior que coluna que não existe.
-- ---------------------------------------------------------------------------
create or replace function public.definir_plano(
  p_salao   uuid,
  p_plano   text,
  p_status  text default 'ativa',
  p_vence_em date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_linha public.assinaturas;
begin
  if not public.is_super() then
    raise exception 'Só a plataforma muda plano.'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.planos where codigo = p_plano) then
    raise exception 'Plano % não existe.', p_plano using errcode = 'check_violation';
  end if;

  if p_status not in ('trial','ativa','inadimplente','cancelada') then
    raise exception 'Status % não existe.', p_status using errcode = 'check_violation';
  end if;

  -- Assinatura 'ativa' sem data de vencimento é a que nunca vence: o salão
  -- fica com o plano cheio para sempre, de graça, e ninguém percebe porque
  -- nada quebra. Trinta dias é o padrão de quem acabou de pagar o mês.
  insert into public.assinaturas (salao_id, plano, status, vence_em, atualizado_em)
       values (p_salao, p_plano, p_status,
               case when p_status = 'ativa'
                    then coalesce(p_vence_em, current_date + 30)
                    else p_vence_em end,
               now())
  on conflict (salao_id) do update
     set plano = excluded.plano,
         status = excluded.status,
         vence_em = excluded.vence_em,
         atualizado_em = now()
  returning * into v_linha;

  return jsonb_build_object(
    'salaoId', v_linha.salao_id,
    'plano', v_linha.plano,
    'status', v_linha.status,
    'venceEm', v_linha.vence_em,
    -- O que o salão passa a ter de verdade, já pela regra do banco. Serve de
    -- conferência imediata: se você marcou 'ativa' com data vencida, o efetivo
    -- volta 'gratuito' e você vê o engano na hora, não no mês que vem.
    'planoEfetivo', public.plano_efetivo(v_linha.salao_id));
end $$;

-- ---------------------------------------------------------------------------
-- 3) Suspender e religar um salão
--
-- Suspenso, ele some da vitrine e para de aceitar marcação — o link que a
-- cliente salvou deixa de funcionar na hora. É o que se usa para quem parou
-- de pagar de vez, ou pediu para sair.
--
-- Não apaga nada: o dono volta amanhã e encontra a agenda inteira. Apagar
-- salão é outra conversa, e não deve caber num clique.
-- ---------------------------------------------------------------------------
create or replace function public.definir_status_salao(p_salao uuid, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_antes text;
begin
  if not public.is_super() then
    raise exception 'Só a plataforma suspende salão.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_status not in ('ativo','suspenso','cancelado') then
    raise exception 'Status % não existe.', p_status using errcode = 'check_violation';
  end if;

  select status into v_antes from public.saloes where id = p_salao;
  if v_antes is null then
    raise exception 'Salão não encontrado.' using errcode = 'check_violation';
  end if;

  update public.saloes set status = p_status where id = p_salao;

  return jsonb_build_object('salaoId', p_salao, 'de', v_antes, 'para', p_status);
end $$;

-- ---------------------------------------------------------------------------
-- 4) Quem pode chamar
--
-- `authenticated` e não `anon`: as três funções conferem `is_super()` na
-- primeira linha, mas conceder para quem nem fez login seria deixar a porta
-- destrancada confiando no cachorro. Duas camadas custam uma linha.
-- ---------------------------------------------------------------------------
revoke all on function public.painel_plataforma() from public;
revoke all on function public.definir_plano(uuid, text, text, date) from public;
revoke all on function public.definir_status_salao(uuid, text) from public;

grant execute on function public.painel_plataforma() to authenticated;
grant execute on function public.definir_plano(uuid, text, text, date) to authenticated;
grant execute on function public.definir_status_salao(uuid, text) to authenticated;
