-- ===========================================================================
-- AgendaPro — 01_schema.sql
-- Tabelas, chaves e travas. Sem RLS aqui: segurança está no 02_rls.sql.
--
-- Rodar à mão no SQL Editor do Supabase, em ordem (01, 02, 03).
-- Mudança de banco merece revisão antes — mesma política do AdminPro.
--
-- A diferença de fundo em relação ao AdminPro: lá um usuário pertence a UM
-- condomínio (coluna `condominio_id` em `usuarios`). Aqui a mesma pessoa pode
-- ser cliente de vários salões e profissional em outro. Por isso a identidade
-- é global (`perfis`) e o pertencimento é uma tabela à parte (`vinculos`).
-- ===========================================================================

create extension if not exists pgcrypto;

-- btree_gist permite misturar "=" (uuid) com "&&" (intervalo) no mesmo
-- EXCLUDE. É o que torna possível a trava anti-choque da agenda lá embaixo.
create extension if not exists btree_gist;

-- ---------------------------------------------------------------------------
-- 1) O INQUILINO
-- ---------------------------------------------------------------------------

create table if not exists public.saloes (
  id        uuid primary key default gen_random_uuid(),
  -- slug é o endereço público: agendapro.app/agendar/salao-da-ana
  slug      text unique not null check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
  nome      text not null,
  tipo      text not null default 'salao'
            check (tipo in ('salao','barbearia','estetica','manicure','outro')),
  logo      text,
  telefone  text,
  whatsapp  text,
  endereco  jsonb not null default '{}'::jsonb,
  fuso      text not null default 'America/Sao_Paulo',
  status    text not null default 'ativo'
            check (status in ('ativo','suspenso','cancelado')),
  -- Regras do agendamento online: antecedência mínima e máxima, prazo de
  -- cancelamento, se exige sinal. Cabe em JSON porque é configuração que só o
  -- próprio salão lê — não é dado que se cruza em relatório.
  cfg       jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2) QUEM É A PESSOA (global) E ONDE ELA ENTRA (por salão)
-- ---------------------------------------------------------------------------

-- Uma linha por telefone no sistema inteiro. É o espelho de auth.users.
create table if not exists public.perfis (
  id         uuid primary key references auth.users(id) on delete cascade,
  nome       text not null check (length(btrim(nome)) >= 2),
  -- E.164, do jeito que o Supabase Auth guarda: +5511999999999
  telefone   text unique not null check (telefone ~ '^\+[1-9][0-9]{7,14}$'),
  email      text,
  nascimento date,
  foto       text,
  -- Dono da plataforma (você). Enxerga todos os salões, para dar suporte.
  super_admin boolean not null default false,
  criado_em  timestamptz not null default now()
);

-- A mesma pessoa pode ter N vínculos: cliente no salão A, profissional no B.
create table if not exists public.vinculos (
  perfil_id uuid not null references public.perfis(id) on delete cascade,
  salao_id  uuid not null references public.saloes(id) on delete cascade,
  papel     text not null
            check (papel in ('dono','admin','recepcao','profissional','cliente')),
  -- Cliente entra 'ativo' assim que o OTP valida o telefone.
  -- Equipe entra 'pendente' e o dono libera — ninguém vira profissional sozinho.
  status    text not null default 'ativo'
            check (status in ('ativo','pendente','bloqueado')),
  criado_em timestamptz not null default now(),
  primary key (perfil_id, salao_id, papel)
);

create index if not exists ix_vinculos_salao on public.vinculos(salao_id, papel)
  where status = 'ativo';

-- ---------------------------------------------------------------------------
-- 3) O QUE O SALÃO OFERECE
-- ---------------------------------------------------------------------------

create table if not exists public.profissionais (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  -- Sem perfil = profissional que não usa o app; a recepção lança por ele.
  perfil_id     uuid references public.perfis(id) on delete set null,
  nome          text not null,
  apelido       text,
  foto          text,
  cor           text not null default '#7C3AED',  -- cor da coluna na agenda
  comissao_pct  numeric(5,2) not null default 0
                check (comissao_pct between 0 and 100),
  aceita_online boolean not null default true,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create index if not exists ix_prof_salao on public.profissionais(salao_id)
  where ativo;

create table if not exists public.servicos (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  nome          text not null,
  categoria     text,
  descricao     text,
  -- A duração é o coração da agenda: é ela que decide onde o próximo cabe.
  duracao_min   int not null check (duracao_min > 0 and duracao_min <= 600),
  -- Tempo depois do atendimento (arrumar a estação, lavar pincel). Conta na
  -- agenda mas não aparece pro cliente como parte do serviço.
  intervalo_min int not null default 0 check (intervalo_min between 0 and 120),
  preco         numeric(10,2) not null default 0 check (preco >= 0),
  -- null = herda a comissão do profissional
  comissao_pct  numeric(5,2) check (comissao_pct between 0 and 100),
  cor           text,
  aceita_online boolean not null default true,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

create index if not exists ix_serv_salao on public.servicos(salao_id) where ativo;

-- Quem faz o quê. Sem linha aqui, o profissional não aparece como opção.
-- Duração e preço podem ser sobrescritos: a Ana faz mecha em 2h, a Bia em 3h.
create table if not exists public.servicos_profissionais (
  servico_id      uuid not null references public.servicos(id) on delete cascade,
  profissional_id uuid not null references public.profissionais(id) on delete cascade,
  duracao_min     int check (duracao_min > 0 and duracao_min <= 600),
  preco           numeric(10,2) check (preco >= 0),
  primary key (servico_id, profissional_id)
);

-- ---------------------------------------------------------------------------
-- 4) QUANDO O PROFISSIONAL ATENDE
-- ---------------------------------------------------------------------------

-- Jornada semanal. Duas linhas no mesmo dia = intervalo de almoço no meio:
--   seg 09:00-12:00  e  seg 13:00-19:00
create table if not exists public.jornadas (
  id              uuid primary key default gen_random_uuid(),
  profissional_id uuid not null references public.profissionais(id) on delete cascade,
  dia_semana      smallint not null check (dia_semana between 0 and 6), -- 0 = domingo
  inicio          time not null,
  fim             time not null,
  check (fim > inicio)
);

create index if not exists ix_jornada_prof on public.jornadas(profissional_id, dia_semana);

-- Exceção pontual: férias, médico, feriado, ou o salão fechado inteiro.
-- profissional_id nulo = vale para o salão todo.
create table if not exists public.bloqueios (
  id              uuid primary key default gen_random_uuid(),
  salao_id        uuid not null references public.saloes(id) on delete cascade,
  profissional_id uuid references public.profissionais(id) on delete cascade,
  inicio          timestamptz not null,
  fim             timestamptz not null,
  motivo          text,
  criado_em       timestamptz not null default now(),
  check (fim > inicio)
);

create index if not exists ix_bloq_salao on public.bloqueios(salao_id, inicio);

-- ---------------------------------------------------------------------------
-- 5) O CLIENTE DO SALÃO
-- ---------------------------------------------------------------------------

-- Ficha do cliente DENTRO de um salão. A mesma pessoa (mesmo `perfil_id`) tem
-- uma ficha em cada salão que frequenta, com histórico e observações próprias
-- — e um salão não enxerga a ficha do outro.
--
-- perfil_id nulo = cliente que a recepção cadastrou e nunca instalou o app.
-- Quando essa pessoa se cadastrar com o mesmo telefone, os dois se juntam.
create table if not exists public.clientes (
  id         uuid primary key default gen_random_uuid(),
  salao_id   uuid not null references public.saloes(id) on delete cascade,
  perfil_id  uuid references public.perfis(id) on delete set null,
  nome       text not null,
  telefone   text,
  email      text,
  nascimento date,
  obs        text,
  alergias   text,
  -- fórmula de coloração, preferências, alertas. Texto livre por natureza.
  ficha      jsonb not null default '{}'::jsonb,
  criado_em  timestamptz not null default now()
);

-- A mesma pessoa não pode ter duas fichas no mesmo salão.
create unique index if not exists ux_cli_perfil
  on public.clientes(salao_id, perfil_id) where perfil_id is not null;
create unique index if not exists ux_cli_tel
  on public.clientes(salao_id, telefone) where telefone is not null;

-- ---------------------------------------------------------------------------
-- 6) A AGENDA — e a trava que impede horário duplicado
-- ---------------------------------------------------------------------------

create table if not exists public.agendamentos (
  id              uuid primary key default gen_random_uuid(),
  salao_id        uuid not null references public.saloes(id) on delete cascade,
  cliente_id      uuid not null references public.clientes(id) on delete restrict,
  profissional_id uuid not null references public.profissionais(id) on delete restrict,
  inicio          timestamptz not null,
  fim             timestamptz not null,
  status          text not null default 'confirmado'
                  check (status in ('pendente','confirmado','em_atendimento',
                                    'concluido','cancelado','faltou')),
  origem          text not null default 'recepcao'
                  check (origem in ('online','recepcao','whatsapp','profissional')),
  valor_previsto  numeric(10,2) not null default 0,
  obs             text,
  cancelado_motivo text,
  -- Campos do sinal. Ficam aqui desde já, vazios, porque adicionar coluna em
  -- tabela grande depois é bem mais caro que criar junto.
  sinal_exigido   numeric(10,2) not null default 0,
  sinal_pago      numeric(10,2) not null default 0,
  sinal_ref       text,
  criado_por      uuid references public.perfis(id) on delete set null,
  criado_em       timestamptz not null default now(),
  check (fim > inicio),

  -- ── A TRAVA ──────────────────────────────────────────────────────────────
  -- Aqui está a diferença mais importante em relação ao AdminPro. Lá o
  -- conflito de horário é conferido no JavaScript (`hrConflita`), então duas
  -- recepcionistas clicando ao mesmo tempo conseguem marcar o mesmo horário
  -- com o mesmo profissional — o navegador de uma não sabe da outra.
  --
  -- Aqui quem recusa é o banco. Não tem como furar: nem por corrida entre
  -- duas telas, nem chamando a API direto, nem com o JavaScript desligado.
  -- '[)' = fim exclusivo, então 09:00-10:00 e 10:00-11:00 NÃO se chocam.
  --
  -- Cancelado e faltou saem da regra: o horário volta a ficar livre.
  constraint agenda_sem_choque exclude using gist (
    profissional_id with =,
    tstzrange(inicio, fim, '[)') with &&
  ) where (status in ('pendente','confirmado','em_atendimento','concluido'))
);

create index if not exists ix_agend_dia     on public.agendamentos(salao_id, inicio);
create index if not exists ix_agend_prof    on public.agendamentos(profissional_id, inicio);
create index if not exists ix_agend_cliente on public.agendamentos(cliente_id, inicio desc);

-- Um atendimento pode ter vários serviços: corte + barba + sobrancelha.
-- A soma das durações é o que define o `fim` do agendamento.
--
-- Nesta fase, o agendamento inteiro é de UM profissional (a trava acima é por
-- profissional). Serviço com profissional diferente no mesmo horário — a
-- manicure enquanto a tinta age — fica para a fase 2 e vai exigir mover a
-- trava para cá.
create table if not exists public.agendamento_servicos (
  id             uuid primary key default gen_random_uuid(),
  agendamento_id uuid not null references public.agendamentos(id) on delete cascade,
  servico_id     uuid not null references public.servicos(id) on delete restrict,
  ordem          smallint not null default 1,
  -- Copiados no momento da marcação: se o preço da tabela mudar amanhã, o que
  -- foi combinado com o cliente continua valendo.
  duracao_min    int not null check (duracao_min > 0),
  preco          numeric(10,2) not null default 0,
  comissao_pct   numeric(5,2) not null default 0
);

create index if not exists ix_ags_agend on public.agendamento_servicos(agendamento_id);

-- ---------------------------------------------------------------------------
-- 7) COMANDA, PAGAMENTO E COMISSÃO
-- ---------------------------------------------------------------------------

create table if not exists public.produtos (
  id           uuid primary key default gen_random_uuid(),
  salao_id     uuid not null references public.saloes(id) on delete cascade,
  nome         text not null,
  marca        text,
  preco        numeric(10,2) not null default 0 check (preco >= 0),
  custo        numeric(10,2) not null default 0 check (custo >= 0),
  estoque      numeric(10,2) not null default 0,
  comissao_pct numeric(5,2) not null default 0
               check (comissao_pct between 0 and 100),
  ativo        boolean not null default true
);

-- Numeração por salão (comanda 1, 2, 3... em cada salão, não global).
-- Contador com UPDATE atômico: dois caixas fechando junto não tiram o mesmo
-- número, que é o que aconteceria com "select max(numero)+1".
create table if not exists public.contadores (
  salao_id uuid not null references public.saloes(id) on delete cascade,
  nome     text not null,
  valor    bigint not null default 0,
  primary key (salao_id, nome)
);

create or replace function public.proximo_numero(p_salao uuid, p_nome text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.contadores (salao_id, nome, valor)
       values (p_salao, p_nome, 1)
  on conflict (salao_id, nome)
    do update set valor = contadores.valor + 1
  returning valor into v;
  return v;
end $$;

create table if not exists public.comandas (
  id             uuid primary key default gen_random_uuid(),
  salao_id       uuid not null references public.saloes(id) on delete cascade,
  agendamento_id uuid references public.agendamentos(id) on delete set null,
  cliente_id     uuid not null references public.clientes(id) on delete restrict,
  numero         bigint not null,
  status         text not null default 'aberta'
                 check (status in ('aberta','fechada','cancelada')),
  desconto       numeric(10,2) not null default 0 check (desconto >= 0),
  desconto_motivo text,
  aberta_em      timestamptz not null default now(),
  fechada_em     timestamptz,
  aberta_por     uuid references public.perfis(id) on delete set null,
  unique (salao_id, numero)
);

create index if not exists ix_comanda_salao on public.comandas(salao_id, aberta_em desc);

create or replace function public.comanda_numera()
returns trigger language plpgsql as $$
begin
  if new.numero is null then
    new.numero := public.proximo_numero(new.salao_id, 'comanda');
  end if;
  return new;
end $$;

drop trigger if exists tg_comanda_numera on public.comandas;
create trigger tg_comanda_numera before insert on public.comandas
  for each row execute function public.comanda_numera();

create table if not exists public.comanda_itens (
  id              uuid primary key default gen_random_uuid(),
  comanda_id      uuid not null references public.comandas(id) on delete cascade,
  tipo            text not null check (tipo in ('servico','produto')),
  servico_id      uuid references public.servicos(id) on delete set null,
  produto_id      uuid references public.produtos(id) on delete set null,
  descricao       text not null,
  qtd             numeric(10,2) not null default 1 check (qtd > 0),
  preco_unit      numeric(10,2) not null default 0 check (preco_unit >= 0),
  -- Quem executou. É por item, não por comanda: o corte é do João, a
  -- escova é da Ana, e a comissão de cada um sai certa no fim do mês.
  profissional_id uuid references public.profissionais(id) on delete set null,
  comissao_pct    numeric(5,2) not null default 0
                  check (comissao_pct between 0 and 100),
  -- Calculados pelo banco: ninguém soma errado, e não dá pra divergir da tela.
  total           numeric(10,2)
                  generated always as (round(qtd * preco_unit, 2)) stored,
  comissao_valor  numeric(10,2)
                  generated always as (round(qtd * preco_unit * comissao_pct / 100, 2)) stored,
  -- Item tem que apontar para o cadastro certo do seu tipo.
  check ((tipo = 'servico' and produto_id is null)
      or (tipo = 'produto' and servico_id is null))
);

create index if not exists ix_item_comanda on public.comanda_itens(comanda_id);
create index if not exists ix_item_prof on public.comanda_itens(profissional_id);

create table if not exists public.pagamentos (
  id          uuid primary key default gen_random_uuid(),
  comanda_id  uuid not null references public.comandas(id) on delete cascade,
  forma       text not null
              check (forma in ('dinheiro','pix','debito','credito',
                               'transferencia','cortesia','pacote')),
  valor       numeric(10,2) not null check (valor > 0),
  parcelas    smallint not null default 1 check (parcelas >= 1),
  -- Taxa da maquininha: o salão recebe menos do que o cliente pagou.
  taxa        numeric(10,2) not null default 0 check (taxa >= 0),
  recebido_em timestamptz not null default now()
);

create index if not exists ix_pgto_comanda on public.pagamentos(comanda_id);

-- Total da comanda: soma dos itens menos desconto. Vista, não coluna — assim
-- não existe o caso de o total guardado discordar dos itens guardados.
--
-- security_invoker = true é OBRIGATÓRIO aqui. Sem isso a vista roda com os
-- poderes de quem a criou (postgres) e passa por cima do RLS das tabelas de
-- baixo — qualquer pessoa logada leria o faturamento de todos os salões.
-- É o furo mais silencioso que existe no Supabase: a tabela está protegida,
-- a vista sobre ela não está.
create or replace view public.comandas_totais
with (security_invoker = true) as
  select c.id,
         c.salao_id,
         c.numero,
         c.status,
         coalesce(sum(i.total), 0)                 as subtotal,
         c.desconto,
         coalesce(sum(i.total), 0) - c.desconto    as total,
         coalesce(sum(i.comissao_valor), 0)        as comissao_total
    from public.comandas c
    left join public.comanda_itens i on i.comanda_id = c.id
   group by c.id;
