-- ===========================================================================
-- AgendaPro — 13: a cobrança (Pix e boleto, pelo Mercado Pago)
--
-- Este arquivo é a metade que mora no banco. A outra metade são duas funções
-- de borda: `criar-cobranca` (que fala com o Mercado Pago) e `webhook-mp`
-- (que ouve a confirmação). Nenhuma credencial mora aqui, e nenhuma mora no
-- navegador.
--
-- ── AS TRÊS COISAS QUE, SE SAÍREM ERRADAS, DÃO O PRODUTO DE GRAÇA ─────────
--
-- 1. O VALOR NUNCA VEM DA TELA.
--    Se o navegador mandasse quanto pagar, qualquer pessoa com o console
--    aberto assinaria o plano de R$ 297 por um centavo. O preço é lido de
--    `planos` no servidor, pelo código do plano — e é por isso que
--    `abrir_cobranca()` recebe o CÓDIGO do plano, nunca o valor.
--
-- 2. O SALÃO NÃO EDITA A PRÓPRIA ASSINATURA.
--    Já era verdade antes deste arquivo (`assinaturas` só tem `grant select`
--    para `authenticated`, e a policy de escrita exige `is_super()`), e
--    continua sendo: quem move `plano` e `vence_em` é `registrar_pagamento()`,
--    que `anon` e `authenticated` não podem executar.
--
-- 3. "PAGOU" SÓ QUEM O MERCADO PAGO DISSER QUE PAGOU — E CONFERIDO NA FONTE.
--    O aviso (webhook) é um endereço público: qualquer um pode fazer POST
--    nele dizendo que a cobrança tal foi paga. Por isso a função de borda faz
--    DUAS conferências antes de chamar `registrar_pagamento()`: valida a
--    assinatura HMAC do aviso e, mesmo assim, vai buscar o pagamento na API
--    do Mercado Pago pelo id para ler status e valor de lá. O corpo do aviso
--    não é fonte de nada.
--
-- ── POR QUE PIX E BOLETO, E NÃO CARTÃO RECORRENTE ─────────────────────────
-- Pix não exige cartão salvo — e dono de salão pequeno resiste a deixar
-- cartão em arquivo. Em compensação, Pix avulso NÃO se renova sozinho: quem
-- renova é a gente, com aviso antes do vencimento e uma folga depois. É o que
-- as funções do fim deste arquivo fazem.
--
-- O desenho não fecha a porta do cartão: `cobrancas.metodo` já é uma coluna,
-- e `registrar_pagamento()` não olha para ela. Assinatura recorrente entra
-- depois sem mexer em nada disto.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) A COBRANÇA
--
-- Uma linha por tentativa de pagamento. Não é o extrato do salão (isso é
-- `comandas`, o dinheiro que ele RECEBE) — é o que ele nos paga.
-- ---------------------------------------------------------------------------
create table if not exists public.cobrancas (
  id          uuid primary key default gen_random_uuid(),
  salao_id    uuid not null references public.saloes(id) on delete cascade,

  -- O plano que esta cobrança compra, e o preço no momento em que ela nasceu.
  -- O valor fica GRAVADO de propósito: se amanhã o plano subir de preço, a
  -- cobrança que já está na mão do dono continua valendo o que ele viu.
  plano       text not null references public.planos(codigo),
  valor       numeric(10,2) not null check (valor > 0),

  metodo      text not null check (metodo in ('pix','boleto')),

  status      text not null default 'pendente'
              check (status in ('pendente','paga','vencida','cancelada','devolvida')),

  vence_em    timestamptz not null,
  criada_em   timestamptz not null default now(),
  paga_em     timestamptz,

  -- ── O que o Mercado Pago devolveu ────────────────────────────────────────
  -- `mp_id` é o id do pagamento lá. É ÚNICO, e é ele que torna o aviso
  -- repetido inofensivo: o mesmo webhook chega várias vezes por desenho, e
  -- sem esta unicidade cada chegada estenderia a assinatura mais um mês.
  mp_id       text unique,
  mp_status   text,

  -- ── O instrumento de pagamento ───────────────────────────────────────────
  -- Isto CHEGA ao navegador, e pode: é o código que a pessoa copia para pagar
  -- a própria conta dela. Não é credencial nossa. O que não chega, nunca, é o
  -- access token do Mercado Pago.
  pix_copia_cola text,
  pix_qr_base64  text,
  boleto_url     text,
  linha_digitavel text,

  -- Quem clicou em assinar. Serve para o suporte saber com quem falar.
  aberta_por  uuid references public.perfis(id) on delete set null
);

create index if not exists ix_cobranca_salao
  on public.cobrancas(salao_id, criada_em desc);

/* ⚠ UMA COBRANÇA ABERTA POR SALÃO, E SÓ UMA.
   Sem isto, cada clique em "Assinar" abre uma cobrança nova no Mercado Pago.
   O dono acaba com seis Pix na mão sem saber qual vale, paga dois, e a gente
   fica devendo devolução — que é o pior jeito de começar uma assinatura.

   O índice é PARCIAL: só as pendentes disputam. Cobrança paga, vencida ou
   cancelada pode haver quantas o histórico tiver. */
create unique index if not exists ux_cobranca_aberta
  on public.cobrancas(salao_id) where (status = 'pendente');

alter table public.cobrancas enable row level security;

/* Ler: só a gestão do próprio salão. É onde está o Pix copia-e-cola dele.
   Escrever: ninguém, por aqui. Quem cria é `abrir_cobranca()` e quem conclui
   é `registrar_pagamento()`, ambas `security definer` — a tabela em si não
   aceita INSERT nem UPDATE vindo de sessão de navegador. */
drop policy if exists cobranca_ler on public.cobrancas;
create policy cobranca_ler on public.cobrancas for select to authenticated
  using ( e_gestor(salao_id) );

drop policy if exists cobranca_gerir on public.cobrancas;
create policy cobranca_gerir on public.cobrancas for all to authenticated
  using ( is_super() ) with check ( is_super() );

revoke all on public.cobrancas from anon, authenticated;
grant select on public.cobrancas to authenticated;

-- ---------------------------------------------------------------------------
-- 2) ABRIR UMA COBRANÇA
--
-- Chamada pela função de borda `criar-cobranca` com a chave de serviço,
-- DEPOIS de ela verificar o JWT de quem pediu. Devolve a linha para a borda
-- preencher com o que o Mercado Pago responder.
--
-- Repare no que ela NÃO recebe: valor. Ele é lido de `planos` aqui dentro.
--
-- ⚠ E REPARE EM COMO A PERMISSÃO É CONFERIDA: pelo `p_quem`, não por
-- `e_gestor()`.
--
-- `e_gestor()` pergunta pelo `auth.uid()` da sessão — e a função de borda roda
-- com a chave de serviço, que não tem sessão de usuário nenhuma. A primeira
-- versão deste arquivo tinha `if not e_gestor(p_salao) then raise`, e teria
-- recusado 100% das chamadas em produção; quem pegou foi o teste, na primeira
-- execução.
--
-- O conserto não é tirar a conferência — é conferir a pessoa CERTA. A borda
-- só sabe o uuid depois de validar o token, então exigir `p_quem` aqui é o
-- que amarra a autorização a alguém de verdade em vez de ao ambiente.
-- ---------------------------------------------------------------------------
create or replace function public.abrir_cobranca(
  p_salao uuid, p_plano text, p_metodo text, p_quem uuid)
returns public.cobrancas
language plpgsql security definer set search_path = public as $$
declare
  v_preco numeric(10,2);
  v_dias  int;
  v_ja    public.cobrancas;
  v_nova  public.cobrancas;
begin
  if p_quem is null then
    raise exception 'Cobrança sem responsável.' using errcode = 'check_violation';
  end if;
  if not exists (
        select 1 from public.vinculos v
         where v.perfil_id = p_quem and v.salao_id = p_salao
           and v.status = 'ativo' and v.papel in ('dono','admin'))
     and not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_metodo not in ('pix','boleto') then
    raise exception 'Forma de pagamento desconhecida.' using errcode = 'check_violation';
  end if;

  select preco_mes into v_preco from public.planos where codigo = p_plano;
  if v_preco is null then
    raise exception 'Plano não encontrado.' using errcode = 'check_violation';
  end if;
  -- Plano sem preço não se compra: é o Grátis ou o teste, e cobrar R$ 0,00
  -- só serviria para o Mercado Pago recusar com uma mensagem ilegível.
  if v_preco <= 0 then
    raise exception 'Este plano não é pago.' using errcode = 'check_violation';
  end if;

  /* Já existe uma pendente? Devolve ELA, em vez de abrir outra.
     E só se for do mesmo plano e da mesma forma — quem estava no Pix e
     resolveu ir de boleto, ou subiu de plano, precisa de uma cobrança nova.
     A antiga é cancelada aqui mesmo, para o índice parcial não brigar. */
  select * into v_ja from public.cobrancas
   where salao_id = p_salao and status = 'pendente'
   for update;

  if found then
    if v_ja.plano = p_plano and v_ja.metodo = p_metodo and v_ja.vence_em > now() then
      return v_ja;
    end if;
    update public.cobrancas set status = 'cancelada' where id = v_ja.id;
  end if;

  -- Pix vence em 24h: tempo de a pessoa pagar sem a cobrança envelhecer no
  -- painel. Boleto precisa de mais, porque compensa em dia útil.
  v_dias := case when p_metodo = 'boleto' then 3 else 1 end;

  insert into public.cobrancas (salao_id, plano, valor, metodo, vence_em, aberta_por)
  values (p_salao, p_plano, v_preco, p_metodo,
          now() + make_interval(days => v_dias), p_quem)
  returning * into v_nova;

  return v_nova;
end $$;

-- ---------------------------------------------------------------------------
-- 3) GUARDAR O QUE O MERCADO PAGO DEVOLVEU
--
-- Separado de `abrir_cobranca()` porque são dois momentos: a linha nasce
-- aqui, a borda vai ao Mercado Pago, e volta para preencher. Se a ida falhar,
-- fica uma cobrança pendente sem instrumento — que a própria `abrir_cobranca`
-- reaproveita ou cancela na tentativa seguinte.
-- ---------------------------------------------------------------------------
create or replace function public.anotar_cobranca(
  p_id uuid, p_mp_id text, p_mp_status text,
  p_pix text default null, p_qr text default null,
  p_boleto text default null, p_linha text default null)
returns void
language sql security definer set search_path = public as $$
  update public.cobrancas
     set mp_id = p_mp_id, mp_status = p_mp_status,
         pix_copia_cola = coalesce(p_pix, pix_copia_cola),
         pix_qr_base64  = coalesce(p_qr, pix_qr_base64),
         boleto_url     = coalesce(p_boleto, boleto_url),
         linha_digitavel = coalesce(p_linha, linha_digitavel)
   where id = p_id;
$$;

-- ---------------------------------------------------------------------------
-- 3b) QUEM ESTÁ PAGANDO
--
-- Boleto no Mercado Pago exige pagador com nome, e-mail e CPF/CNPJ. O CPF já
-- é pedido no cadastro e mora em `documentos_cobranca`, que tem RLS próprio
-- porque é o dado mais sensível do cadastro do dono.
--
-- ⚠ E É POR ISSO QUE ESTA FUNÇÃO EXISTE, EM VEZ DE A TELA MANDAR O CPF.
-- Se o checkout pedisse o documento no navegador, o CPF do dono passaria a
-- trafegar num formulário toda vez que ele fosse pagar a mensalidade — e a
-- gente já tem o dado guardado. A borda lê aqui, com a chave de serviço, e o
-- navegador nunca vê.
-- ---------------------------------------------------------------------------
create or replace function public.dados_do_pagador(p_salao uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome',      coalesce(pf.nome, s.nome),
    'email',     pf.email,
    'documento', d.documento,
    'salao',     s.nome)
    from public.saloes s
    left join public.documentos_cobranca d on d.salao_id = s.id
    left join lateral (
      select p.nome, p.email
        from public.vinculos v
        join public.perfis p on p.id = v.perfil_id
       where v.salao_id = s.id and v.status = 'ativo' and v.papel = 'dono'
       order by v.criado_em limit 1) pf on true
   where s.id = p_salao;
$$;

revoke all on function public.dados_do_pagador(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) O PAGAMENTO CONFIRMADO
--
-- É a única porta que move `assinaturas`. Chamada só pela função de borda do
-- webhook, DEPOIS de ela conferir a assinatura HMAC do aviso e reler o
-- pagamento na API do Mercado Pago.
--
-- ⚠ IDEMPOTENTE POR CONSTRUÇÃO. O Mercado Pago reenvia o mesmo aviso até
-- receber 200, e reenvia de novo em cada mudança do pagamento. Sem a trava do
-- `status <> 'paga'` abaixo, cada reenvio somaria mais um mês de assinatura —
-- e o salão que pagou uma vez ficaria com meio ano de graça.
-- ---------------------------------------------------------------------------
create or replace function public.registrar_pagamento(
  p_mp_id text, p_valor numeric, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.cobrancas;
  v_base date;
begin
  select * into c from public.cobrancas
   where mp_id = p_mp_id
   for update;                       -- dois avisos ao mesmo tempo: um espera

  if not found then
    -- Não é erro nosso: pode ser aviso de um pagamento que não é deste
    -- sistema. A borda responde 200 assim mesmo, senão o Mercado Pago
    -- reenvia para sempre.
    return jsonb_build_object('ok', false, 'motivo', 'cobranca_desconhecida');
  end if;

  if c.status = 'paga' then
    return jsonb_build_object('ok', true, 'motivo', 'ja_registrada');
  end if;

  if p_status <> 'approved' then
    update public.cobrancas set mp_status = p_status where id = c.id;
    return jsonb_build_object('ok', true, 'motivo', 'nao_aprovado');
  end if;

  /* ⚠ O VALOR TEM QUE BATER.
     Chega aqui vindo da API do Mercado Pago, não do corpo do aviso — mas
     conferir mesmo assim custa uma linha e fecha o caso de alguém pagar uma
     cobrança de R$ 57 e receber o plano de R$ 297 porque o id foi trocado no
     caminho. */
  if p_valor is distinct from c.valor then
    update public.cobrancas
       set mp_status = 'valor_divergente:' || coalesce(p_valor::text, 'null')
     where id = c.id;
    return jsonb_build_object('ok', false, 'motivo', 'valor_divergente');
  end if;

  update public.cobrancas
     set status = 'paga', paga_em = now(), mp_status = p_status
   where id = c.id;

  /* A partir de quando conta o mês.
     Quem paga ANTES de vencer soma ao que ainda tem — não perde os dias que
     comprou. Quem paga depois começa de hoje: dar retroativo faria a
     assinatura vencer de novo na semana seguinte. */
  select greatest(coalesce(a.vence_em, current_date), current_date)
    into v_base
    from public.assinaturas a where a.salao_id = c.salao_id;

  update public.assinaturas
     set plano = c.plano,
         status = 'ativa',
         trial_ate = null,
         vence_em = coalesce(v_base, current_date) + interval '1 month',
         atualizado_em = now()
   where salao_id = c.salao_id;

  return jsonb_build_object('ok', true, 'salao', c.salao_id, 'plano', c.plano);
end $$;

/* ⚠ ESTAS DUAS NÃO SÃO DE NINGUÉM QUE ESTEJA NUM NAVEGADOR.
   `anotar_cobranca` escreve o instrumento; `registrar_pagamento` estende a
   assinatura. Alcançáveis por `authenticated`, qualquer dono de salão
   assinaria o plano maior de graça chamando a segunda com o mp_id certo. */
revoke all on function public.abrir_cobranca(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.anotar_cobranca(uuid, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.registrar_pagamento(text, numeric, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5) O QUE A TELA DO DONO PRECISA SABER
--
-- Uma chamada só, como o relatório: a cobrança aberta (se houver) e as
-- últimas pagas. A tela não monta isso de três consultas.
-- ---------------------------------------------------------------------------
create or replace function public.minha_cobranca(p_salao uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;

  return jsonb_build_object(
    'aberta', (
      select to_jsonb(x) from (
        select c.id, c.plano, c.valor, c.metodo, c.vence_em,
               c.pix_copia_cola, c.pix_qr_base64, c.boleto_url, c.linha_digitavel
          from public.cobrancas c
         where c.salao_id = p_salao and c.status = 'pendente'
           and c.vence_em > now()
         order by c.criada_em desc limit 1) x),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', h.id, 'plano', h.plano, 'valor', h.valor,
               'metodo', h.metodo, 'status', h.status,
               'pagaEm', h.paga_em, 'criadaEm', h.criada_em)
             order by h.criada_em desc)
        from (select * from public.cobrancas
               where salao_id = p_salao and status in ('paga','devolvida')
               order by criada_em desc limit 12) h), '[]'::jsonb)
  );
end $$;

revoke all on function public.minha_cobranca(uuid) from public;
grant execute on function public.minha_cobranca(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) A RENOVAÇÃO, QUE É O QUE PIX AVULSO NÃO FAZ SOZINHO
--
-- Cartão recorrente cobra sozinho. Pix não: alguém precisa lembrar o dono
-- antes de vencer, e dar uma folga depois. Sem isso, a assinatura morre por
-- esquecimento — que é a forma mais cara de perder cliente, porque ele nem
-- decidiu sair.
--
-- Estas duas funções são para a função de borda agendada (uma vez por dia).
-- Elas não mandam mensagem nenhuma: devolvem QUEM avisar. Quem manda é o
-- worker de WhatsApp que já existe.
-- ---------------------------------------------------------------------------

/* Quem vence nos próximos `p_dias` dias e ainda não tem cobrança aberta.
   É a lista de quem precisa receber o Pix do mês. */
create or replace function public.assinaturas_a_vencer(p_dias int default 5)
returns table (salao_id uuid, salao text, whatsapp text, plano text,
               valor numeric, vence_em date)
language sql security definer set search_path = public as $$
  select a.salao_id, s.nome, s.whatsapp, a.plano, pl.preco_mes, a.vence_em
    from public.assinaturas a
    join public.saloes s  on s.id = a.salao_id
    join public.planos pl on pl.codigo = a.plano
   where a.status = 'ativa'
     and a.vence_em is not null
     and a.vence_em <= current_date + p_dias
     and pl.preco_mes > 0
     and not exists (
       select 1 from public.cobrancas c
        where c.salao_id = a.salao_id and c.status = 'pendente'
          and c.vence_em > now())
   order by a.vence_em;
$$;

/* A faxina do dia: cobrança que passou da validade vira 'vencida'.
   Sem isto o índice parcial de "uma pendente por salão" travaria o dono para
   sempre num Pix que ele nunca pagou. */
create or replace function public.vencer_cobrancas()
returns int
language sql security definer set search_path = public as $$
  with mortas as (
    update public.cobrancas set status = 'vencida'
     where status = 'pendente' and vence_em <= now()
     returning 1)
  select count(*)::int from mortas;
$$;

revoke all on function public.assinaturas_a_vencer(int) from public, anon, authenticated;
revoke all on function public.vencer_cobrancas() from public, anon, authenticated;
