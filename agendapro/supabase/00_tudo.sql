-- ===========================================================================
-- AgendaPro — INSTALAÇÃO COMPLETA
--
-- Cole ESTE arquivo inteiro no SQL Editor do Supabase e clique em Run.
-- É a junção de 01_schema.sql + 02_rls.sql + 03_onboarding.sql + 04_imagens.sql
-- + 05_agenda.sql,
-- nesta ordem.
--
-- Pode rodar mais de uma vez sem medo: tudo aqui é 'create if not exists',
-- 'create or replace' ou 'drop policy if exists' antes de criar.
--
-- Gerado por supabase/montar.sh — não edite à mão; edite os arquivos de origem.
--
-- Depois de rodar, cole tests/conferir_instalacao.sql para checar.
-- ===========================================================================


-- ###########################################################################
-- ## 01_schema.sql
-- ###########################################################################

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
  -- O tipo não é só rótulo: ele define o VOCABULÁRIO do sistema. Barbearia
  -- diz "barbeiro", esmalteria diz "manicure", clínica diz "paciente". Um
  -- produto só, cinco nichos, sem manter cinco produtos.
  tipo      text not null default 'salao'
            check (tipo in ('salao','barbearia','estetica','manicure',
                            'clinica','tatuagem','pet','outro')),
  -- Imagens do salão. Guardam ENDEREÇO, não bytes: em produção apontam para o
  -- Supabase Storage; na demonstração são `data:` URL no próprio navegador.
  -- Coluna text nos dois casos, então a tela não precisa saber a diferença.
  logo      text,
  capa      text,
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
-- 1b) O QUE O SALÃO PAGA
--
-- O AdminPro não tem isso, e a documentação dele reconhece: "o sistema não
-- sabe quem é o cliente, só qual é o condomínio". Com poucos clientes e Pix
-- na mão aquilo passava. Aqui não passa, porque o preço é por profissional —
-- sem controle, o dono assina o plano de um e cadastra oito.
-- ---------------------------------------------------------------------------

create table if not exists public.planos (
  codigo           text primary key,
  nome             text not null,
  max_profissionais int not null check (max_profissionais > 0),
  preco_mes        numeric(10,2) not null default 0 check (preco_mes >= 0),
  -- Quais módulos o plano libera. Fica em JSON porque é configuração da
  -- plataforma, mexida por nós, não dado que se cruza em relatório.
  recursos         jsonb not null default '{}'::jsonb,
  ativo            boolean not null default true,
  ordem            smallint not null default 0
);

create table if not exists public.assinaturas (
  salao_id     uuid primary key references public.saloes(id) on delete cascade,
  plano        text not null references public.planos(codigo),
  status       text not null default 'trial'
               check (status in ('trial','ativa','inadimplente','cancelada')),
  -- Fim do teste grátis. Passou disso sem virar 'ativa', o salão para.
  trial_ate    date,
  vence_em     date,
  -- Por onde o dono chegou até nós. É a única forma de saber qual parceria
  -- ou anúncio trouxe cliente que paga, em vez de cliente que só olhou.
  origem       text,
  indicado_por text,
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Qual plano vale HOJE para este salão.
--
-- Toda regra de cobrança passa por aqui, e existe um motivo: antes, a data de
-- validade estava escrita dentro do `limite_profissionais`, e só a do teste
-- grátis. A consequência era que uma assinatura 'ativa' com `vence_em` há dois
-- meses continuava valendo o plano inteiro — quem parasse de pagar ficava com
-- tudo, para sempre, até alguém marcar 'inadimplente' na mão. E não havia nada
-- que marcasse.
--
-- Quando a assinatura não está em vigor, o salão NÃO para: ele cai no plano
-- 'gratuito'. É de propósito. Salão que não quer pagar continua usando com um
-- teto; se caísse para nada, o dono voltava para o caderno e a gente perdia o
-- canal por onde ele um dia assina.
create or replace function public.plano_efetivo(p_salao uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select a.plano
       from public.assinaturas a
      where a.salao_id = p_salao
        and (
          (a.status = 'ativa'
             and (a.vence_em is null or a.vence_em >= current_date))
          or
          (a.status = 'trial'
             and (a.trial_ate is null or a.trial_ate >= current_date))
        )),
    'gratuito')
$$;

-- Quantos profissionais este salão pode ter, agora.
create or replace function public.limite_profissionais(p_salao uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(
    (select pl.max_profissionais from public.planos pl
      where pl.codigo = public.plano_efetivo(p_salao)),
    1)                      -- plano sumiu da tabela: trata como o mais apertado
$$;

-- Um recurso do plano, por chave. `recursos` é jsonb porque é configuração
-- nossa, mexida com UPDATE, não dado que entra em relatório.
create or replace function public.recurso_num(p_salao uuid, p_chave text)
returns int language sql stable security definer set search_path = public as $$
  select nullif(pl.recursos ->> p_chave, '')::int
    from public.planos pl where pl.codigo = public.plano_efetivo(p_salao)
$$;

create or replace function public.recurso_bool(p_salao uuid, p_chave text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((pl.recursos ->> p_chave)::boolean, false)
    from public.planos pl where pl.codigo = public.plano_efetivo(p_salao)
$$;

-- Os planos de partida. Preço é decisão comercial e muda com um UPDATE —
-- por isso está em tabela, não espalhado pelo código.
--
-- `agendamentos_mes` ausente (ou null) = sem teto.
--
-- Por que o grátis tem teto de agendamento, e não de funcionalidade: o teto
-- precisa crescer junto com o salão. Cortar a agenda online do plano grátis
-- mataria justamente o que faz o dono adotar o sistema. Já 40 horários por mês
-- é um salão que ainda não é negócio; a 120 ele é, e aí R$ 47 sai de um corte.
--
-- O lembrete no WhatsApp fica de fora do grátis por um motivo de caixa, não de
-- marketing: cada mensagem enviada é dinheiro que sai, por salão que não paga.
insert into public.planos
  (codigo, nome, max_profissionais, preco_mes, ordem, recursos) values
  ('gratuito',  'Grátis',       1,  0.00, 0,
     '{"agendamentos_mes":40,"lembrete_whatsapp":false,"agenda_online":true}'),
  ('trial',     'Teste grátis', 1,  0.00, 1,
     '{"lembrete_whatsapp":true,"agenda_online":true}'),
  ('individual','Individual',   1, 47.00, 2,
     '{"lembrete_whatsapp":true,"agenda_online":true}'),
  ('duo',       'Duo',          2, 87.00, 3,
     '{"lembrete_whatsapp":true,"agenda_online":true}'),
  ('time',      'Time',         3,127.00, 4,
     '{"lembrete_whatsapp":true,"agenda_online":true}'),
  ('equipe',    'Equipe',       5,187.00, 5,
     '{"lembrete_whatsapp":true,"agenda_online":true}'),
  ('salao',     'Salão',       20,297.00, 6,
     '{"lembrete_whatsapp":true,"agenda_online":true}')
on conflict (codigo) do update
   set nome = excluded.nome,
       max_profissionais = excluded.max_profissionais,
       ordem    = excluded.ordem,
       recursos = excluded.recursos;
       -- preço NÃO entra no update: quem já instalou pode ter mexido no dele,
       -- e rodar o schema de novo não pode remarcar o preço de ninguém.

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

-- ⚠ A TRAVA DO PLANO MORA AQUI, e não na tela.
--
-- Limite conferido em JavaScript não é limite: o dono abre o console, chama a
-- API REST do Supabase com a chave que está no HTML e cadastra quantos
-- profissionais quiser no plano de um. Receita vazando sem ninguém ver.
--
-- Como gatilho, a recusa vale para a tela, para a API e para o SQL escrito à
-- mão. A mensagem diz o número e o plano, para o dono saber o que fazer em
-- vez de achar que quebrou.
create or replace function public.checar_limite_profissionais()
returns trigger language plpgsql security definer set search_path = public as $$
declare usados int; limite int; nome_plano text;
begin
  -- Só conta quem está ativo: desativar um barbeiro é a forma legítima de
  -- abrir vaga sem apagar o histórico dele.
  if not new.ativo then return new; end if;
  if tg_op = 'UPDATE' and old.ativo and new.salao_id = old.salao_id then
    return new;   -- já contava antes, nada muda
  end if;

  select count(*) into usados
    from public.profissionais
   where salao_id = new.salao_id and ativo
     and (tg_op = 'INSERT' or id <> new.id);

  limite := public.limite_profissionais(new.salao_id);

  if usados >= limite then
    select pl.nome into nome_plano
      from public.assinaturas a join public.planos pl on pl.codigo = a.plano
     where a.salao_id = new.salao_id;
    raise exception
      'O plano % permite % profissional(is) ativo(s), e o salão já tem %. '
      'Troque de plano ou desative alguém antes de cadastrar mais.',
      coalesce(nome_plano, 'atual'), limite, usados
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists tg_limite_prof on public.profissionais;
create trigger tg_limite_prof
  before insert or update on public.profissionais
  for each row execute function public.checar_limite_profissionais();

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
  -- A foto do serviço é o que faz o cliente escolher: "corte navalhado" não
  -- diz nada, a imagem diz. É o padrão da categoria inteira.
  foto          text,
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

  -- Quem senta na cadeira, quando não é o titular da ficha. Barbearia vive
  -- disso: o pai marca e leva o filho. O nome do menor fica aqui, como texto,
  -- vinculado ao responsável — de propósito.
  --
  -- Cadastrar criança seria criar um titular de dados menor de idade, com
  -- tudo o que a LGPD exige junto (consentimento do responsável, tratamento
  -- específico). Guardar só o primeiro nome dentro do agendamento do pai
  -- resolve a operação sem abrir esse capítulo. O telefone continua sendo o
  -- do responsável, e é para ele que o lembrete vai.
  atendido_nome   text,

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

-- ── A SEGUNDA TRAVA: bloqueio e atendimento não convivem ────────────────────
-- A trava `agenda_sem_choque` só olha agendamento contra agendamento. Almoço,
-- médico e feriado moram noutra tabela, então nada impedia marcar mecha das
-- 9h às 12h15 por cima do almoço das 12h — foi exatamente o que aconteceu nos
-- dados de demonstração, e ninguém percebeu até a tela desenhar um bloco em
-- cima do outro.
--
-- `EXCLUDE` não atravessa duas tabelas, então a regra vira gatilho. Ele roda
-- dos dois lados: ao marcar (contra os bloqueios que já existem) e ao
-- bloquear (contra os atendimentos que já existem), senão dava para furar
-- invertendo a ordem. `profissional_id is null` num bloqueio quer dizer salão
-- inteiro fechado — vale para todo mundo da casa.
create or replace function public.checar_bloqueio_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  motivo_conflito text;
begin
  if new.status not in ('pendente','confirmado','em_atendimento','concluido') then
    return new;                                   -- cancelado e faltou liberam
  end if;

  select coalesce(b.motivo, 'bloqueado') into motivo_conflito
    from public.bloqueios b
   where b.salao_id = new.salao_id
     and (b.profissional_id = new.profissional_id or b.profissional_id is null)
     and tstzrange(b.inicio, b.fim, '[)') && tstzrange(new.inicio, new.fim, '[)')
   limit 1;

  if motivo_conflito is not null then
    raise exception 'Horário indisponível: %', motivo_conflito
      using errcode = 'exclusion_violation';
  end if;
  return new;
end $$;

create or replace function public.checar_agendamento_bloqueio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  select count(*) into n
    from public.agendamentos a
   where a.salao_id = new.salao_id
     and (new.profissional_id is null or a.profissional_id = new.profissional_id)
     and a.status in ('pendente','confirmado','em_atendimento','concluido')
     and tstzrange(a.inicio, a.fim, '[)') && tstzrange(new.inicio, new.fim, '[)');

  if n > 0 then
    raise exception
      'Existe atendimento marcado nesse período (% no total). Remarque antes de bloquear.', n
      using errcode = 'exclusion_violation';
  end if;
  return new;
end $$;

drop trigger if exists tg_agend_vs_bloqueio on public.agendamentos;
create trigger tg_agend_vs_bloqueio
  before insert or update of inicio, fim, profissional_id, status
  on public.agendamentos
  for each row execute function public.checar_bloqueio_agendamento();

drop trigger if exists tg_bloqueio_vs_agend on public.bloqueios;
create trigger tg_bloqueio_vs_agend
  before insert or update of inicio, fim, profissional_id
  on public.bloqueios
  for each row execute function public.checar_agendamento_bloqueio();

-- ── O TETO DO PLANO GRÁTIS ──────────────────────────────────────────────────
-- Nem todo salão vai assinar, e tudo bem: o grátis é plano de verdade, não
-- castigo. Mas ele precisa de um limite que cresça junto com o salão, senão o
-- plano Individual não vende para ninguém — um profissional com tudo liberado
-- é exatamente o que o grátis já dá.
--
-- O teto é por MÊS DO ATENDIMENTO, não por data de cadastro: é assim que o
-- dono lê ("quantos horários eu tenho em outubro"). Cancelado e faltou não
-- contam — cancelar devolve a vaga, que é o justo.
--
-- Roda só quando o plano tem teto. Nos planos pagos, `recurso_num` devolve
-- null e a função sai na primeira linha, sem contar nada.
create or replace function public.checar_limite_agendamentos()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  teto   int;
  usados int;
  v_fuso text;
  v_ini  timestamptz;
  v_fim  timestamptz;
  -- Nomes com prefixo por obrigação, não por gosto: `fim` colide com
  -- `agendamentos.fim` e o Postgres derruba o INSERT inteiro com "column
  -- reference is ambiguous". Aconteceu aqui, e travou toda marcação no plano
  -- grátis até o teste pegar.
begin
  if new.status not in ('pendente','confirmado','em_atendimento','concluido') then
    return new;
  end if;

  teto := public.recurso_num(new.salao_id, 'agendamentos_mes');
  if teto is null then return new; end if;                    -- plano sem teto

  -- O mês é o do salão, não o do servidor. Sem isto, um atendimento das 22h
  -- do dia 31 em São Paulo cairia no mês seguinte, porque o PostgREST fala
  -- UTC — é o mesmo erro que já apareceu na lista de espera.
  select coalesce(sl.fuso, 'America/Sao_Paulo') into v_fuso
    from public.saloes sl where sl.id = new.salao_id;

  v_ini := (date_trunc('month', new.inicio at time zone v_fuso)) at time zone v_fuso;
  v_fim := (v_ini at time zone v_fuso + interval '1 month') at time zone v_fuso;

  select count(*) into usados
    from public.agendamentos a
   where a.salao_id = new.salao_id
     and a.status in ('pendente','confirmado','em_atendimento','concluido')
     and a.inicio >= v_ini and a.inicio < v_fim
     and (tg_op = 'INSERT' or a.id <> new.id);

  if usados >= teto then
    raise exception
      'O plano Grátis permite % horários por mês, e este mês já tem %. '
      'Assine um plano para continuar marcando.', teto, usados
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists tg_limite_agendamentos on public.agendamentos;
create trigger tg_limite_agendamentos
  before insert or update of inicio, status, salao_id
  on public.agendamentos
  for each row execute function public.checar_limite_agendamentos();

-- ── A VAGA DO PLANO, COBRADA NA HORA DE USAR ────────────────────────────────
-- Primeira tentativa aqui foi prender a TROCA de plano: recusar o rebaixamento
-- enquanto sobrasse gente ativa. Estava errado por dois motivos, e os dois
-- apareceram no teste.
--
-- 1) Quem troca de plano é a plataforma — a policy não deixa o dono escrever
--    em `assinaturas`. Ou seja, a trava só atrapalhava quem precisava rebaixar
--    de verdade: cancelamento, falta de pagamento, fim de contrato.
-- 2) E não pegava o caso mais comum de todos. Teste grátis vence sozinho: a
--    data passa, `plano_efetivo` muda, e não existe UPDATE nenhum para
--    interceptar. O salão ficava com os 3 profissionais atendendo num plano
--    de 1, para sempre.
--
-- A regra certa é sobre USAR a vaga, não sobre contratá-la: um profissional
-- fora da cota do plano não recebe agendamento. Isso cobre expiração,
-- rebaixamento e chamada direta na API com uma regra só, e a plataforma nunca
-- fica presa.
--
-- Quem está dentro da cota: os N mais antigos entre os ativos. É estável (não
-- muda de um dia para o outro) e na prática guarda a vaga de quem começou —
-- que quase sempre é o próprio dono, cadastrado pelo `criar_salao`.
create or replace function public.profissional_na_cota(p_prof uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select posicao <= public.limite_profissionais(salao_id)
      from (
        select p.id, p.salao_id,
               row_number() over (partition by p.salao_id
                                  order by p.criado_em, p.id) as posicao
          from public.profissionais p
         where p.ativo
           and p.salao_id = (select salao_id from public.profissionais where id = p_prof)
      ) r
     where r.id = p_prof
  ), false)
$$;

create or replace function public.checar_cota_profissional()
returns trigger language plpgsql security definer set search_path = public as $$
declare nome_prof text; nome_plano text; limite int;
begin
  if new.status not in ('pendente','confirmado','em_atendimento','concluido') then
    return new;
  end if;
  if public.profissional_na_cota(new.profissional_id) then return new; end if;

  select p.nome into nome_prof
    from public.profissionais p where p.id = new.profissional_id;
  limite := public.limite_profissionais(new.salao_id);
  select pl.nome into nome_plano
    from public.planos pl where pl.codigo = public.plano_efetivo(new.salao_id);

  raise exception
    '% está fora do seu plano. O % cobre % profissional(is) na agenda. '
    'Assine um plano maior, ou desative outra pessoa para abrir a vaga.',
    coalesce(nome_prof, 'Este profissional'),
    coalesce(nome_plano, 'plano atual'), limite
    using errcode = 'check_violation';
end $$;

drop trigger if exists tg_cota_profissional on public.agendamentos;
create trigger tg_cota_profissional
  before insert or update of profissional_id, status
  on public.agendamentos
  for each row execute function public.checar_cota_profissional();

-- O gatilho antigo sai de cena. `drop if exists` para quem já instalou a
-- versão anterior não ficar com os dois.
drop trigger if exists tg_rebaixamento on public.assinaturas;
drop function if exists public.checar_rebaixamento();

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
-- 6b) LISTA DE ESPERA
--
-- Dia cheio é o momento em que a maioria dos sistemas perde o cliente: mostra
-- "sem horário" e o cara fecha a página. Aqui ele deixa o nome, e quando
-- alguém cancela o salão já sabe para quem oferecer.
--
-- Vale dos dois lados: o cliente não some, e a cadeira vaga não fica vazia —
-- que é o buraco de faturamento que ninguém enxerga, porque cancelamento não
-- aparece em relatório nenhum.
-- ---------------------------------------------------------------------------

create table if not exists public.lista_espera (
  id              uuid primary key default gen_random_uuid(),
  salao_id        uuid not null references public.saloes(id) on delete cascade,
  cliente_id      uuid not null references public.clientes(id) on delete cascade,
  -- Nulo = aceita qualquer profissional. Quem aceita qualquer um entra na
  -- frente na hora de oferecer, porque a vaga que surgir serve para ele.
  profissional_id uuid references public.profissionais(id) on delete cascade,
  -- O que a pessoa queria fazer, para o salão saber se a vaga cabe.
  servicos        jsonb not null default '[]'::jsonb,
  duracao_min     int not null default 30 check (duracao_min > 0),
  -- Faixa de interesse. Mesma data nos dois campos = "só esse dia".
  de              date not null,
  ate             date not null,
  -- Turno preferido: 'manha', 'tarde', 'noite' ou 'qualquer'.
  turno           text not null default 'qualquer'
                  check (turno in ('manha','tarde','noite','qualquer')),
  obs             text,
  status          text not null default 'aguardando'
                  check (status in ('aguardando','avisado','atendido','desistiu','expirou')),
  avisado_em      timestamptz,
  criado_em       timestamptz not null default now(),
  check (ate >= de)
);

-- A ordem de atendimento é a ordem de chegada. Índice parcial porque só
-- interessa quem ainda está esperando.
create index if not exists ix_espera_fila
  on public.lista_espera(salao_id, de, criado_em)
  where status = 'aguardando';

create index if not exists ix_espera_cliente on public.lista_espera(cliente_id);

-- Quem está esperando por uma vaga que acabou de abrir. O salão chama esta
-- função depois de um cancelamento; ela devolve a fila em ordem de chegada,
-- já filtrada por quem serve para aquele buraco.
-- ⚠ TUDO AQUI ACONTECE NO FUSO DO SALÃO, e isso não é detalhe.
--
-- `inicio` é timestamptz, guardado em UTC. `extract(hour from ...)` e o cast
-- `::date` usam o fuso da SESSÃO, não o do salão — e a sessão do PostgREST
-- roda em UTC. Escrito do jeito ingênuo, um horário das 9h de São Paulo vira
-- 12h para o Postgres, e quem pediu "manhã" nunca é chamado.
--
-- Foi assim que este bug apareceu: o teste "vaga de manhã chama quem pediu
-- manhã" falhou na primeira execução. Na produção ele não falharia alto —
-- só chamaria as pessoas erradas, calado, para sempre.
--
-- Por isso a conversão explícita com `at time zone`, que transforma o
-- timestamptz no horário de parede daquele salão.
create or replace function public.espera_para_vaga(
  p_salao uuid, p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns setof public.lista_espera
language sql stable as $$
  with tz as (
    select coalesce(nullif(fuso, ''), 'America/Sao_Paulo') as nome
      from public.saloes where id = p_salao
  ),
  parede as (   -- o horário como quem está no salão o lê no relógio
    select (p_inicio at time zone (select nome from tz)) as quando
  )
  select e.*
    from public.lista_espera e
   where e.salao_id = p_salao
     and e.status = 'aguardando'
     and (e.profissional_id is null or e.profissional_id = p_profissional)
     and (select quando from parede)::date between e.de and e.ate
     -- O serviço precisa caber no buraco que abriu.
     and e.duracao_min <= extract(epoch from (p_fim - p_inicio)) / 60
     and (e.turno = 'qualquer'
          or (e.turno = 'manha'
              and extract(hour from (select quando from parede)) < 12)
          or (e.turno = 'tarde'
              and extract(hour from (select quando from parede)) between 12 and 17)
          or (e.turno = 'noite'
              and extract(hour from (select quando from parede)) >= 18))
   order by
     -- Quem aceita qualquer profissional primeiro: a vaga serve para ele com
     -- certeza, e chamar quem só quer a Ana quando vagou o Zé é perder tempo.
     (e.profissional_id is null) desc,
     e.criado_em
$$;

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

-- ###########################################################################
-- ## 02_rls.sql
-- ###########################################################################

-- ===========================================================================
-- AgendaPro — 02_rls.sql
-- A segurança de verdade. Rodar DEPOIS do 01_schema.sql.
--
-- Mesma filosofia do AdminPro: quem protege o dado não é o JavaScript da
-- página, é a regra dentro do banco. O Supabase expõe uma API REST pública
-- sobre estas tabelas — qualquer pessoa com a chave anônima (que está no HTML,
-- e tudo bem) pode chamar direto do navegador, sem passar pela nossa tela.
-- Se o RLS deixar, o dado sai.
--
-- A mudança em relação ao AdminPro: lá a pergunta era "qual é o seu
-- condomínio?", uma coluna só. Aqui é "você tem vínculo com ESTE salão, e em
-- que papel?" — porque a mesma pessoa pode ser cliente em um e profissional
-- em outro.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) AS PERGUNTAS QUE AS POLICIES FAZEM
--
-- Todas são `security definer` porque precisam ler `vinculos` — e `vinculos`
-- também tem RLS. Sem definer, a função cairia na própria regra que ela existe
-- para responder (recursão infinita, erro na primeira consulta).
-- `set search_path = public` fecha a porta de sequestro de nome de tabela.
-- ---------------------------------------------------------------------------

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select super_admin from public.perfis where id = auth.uid()), false)
$$;

-- Papel mais alto que a pessoa tem neste salão. Null = nenhum vínculo ativo.
create or replace function public.papel_no_salao(p_salao uuid) returns text
language sql stable security definer set search_path = public as $$
  select papel
    from public.vinculos
   where perfil_id = auth.uid()
     and salao_id  = p_salao
     and status    = 'ativo'
   order by array_position(
     array['dono','admin','recepcao','profissional','cliente'], papel)
   limit 1
$$;

create or replace function public.tem_acesso(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) is not null
$$;

-- Equipe = trabalha no salão. Cliente NÃO é equipe.
create or replace function public.e_equipe(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super()
      or papel_no_salao(p_salao) in ('dono','admin','recepcao','profissional')
$$;

-- Quem manda: mexe em serviço, preço, profissional e comissão.
create or replace function public.e_gestor(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) in ('dono','admin')
$$;

-- Recepção e gestão veem a agenda inteira; profissional vê a dele.
create or replace function public.ve_agenda_toda(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) in ('dono','admin','recepcao')
$$;

-- A ficha DESTA pessoa NESTE salão. É o que amarra o cliente logado aos
-- próprios agendamentos, sem deixá-lo perto dos agendamentos dos outros.
create or replace function public.meu_cliente_id(p_salao uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.clientes
   where salao_id = p_salao and perfil_id = auth.uid()
   limit 1
$$;

-- O profissional logado, dentro deste salão.
create or replace function public.meu_profissional_id(p_salao uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.profissionais
   where salao_id = p_salao and perfil_id = auth.uid() and ativo
   limit 1
$$;

-- ── Três atalhos para a comanda, e o motivo de existirem ──────────────────
--
-- A policy de `comandas` precisa saber se o profissional tem item nela; a de
-- `comanda_itens` precisa saber de que salão é a comanda. Escritas como
-- subconsulta comum, uma dispara a policy da outra e o Postgres para com
-- "infinite recursion detected in policy" — foi o que aconteceu aqui.
--
-- Sendo `security definer`, estas funções não passam pelo RLS, e o ciclo se
-- rompe. São de leitura e devolvem um dado só, então não abrem porta nenhuma.
create or replace function public.salao_da_comanda(p_comanda uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select salao_id from public.comandas where id = p_comanda
$$;

create or replace function public.cliente_da_comanda(p_comanda uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select cliente_id from public.comandas where id = p_comanda
$$;

create or replace function public.tenho_item_na_comanda(p_comanda uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.comanda_itens i
      join public.comandas c on c.id = i.comanda_id
     where i.comanda_id = p_comanda
       and i.profissional_id = meu_profissional_id(c.salao_id))
$$;

-- ---------------------------------------------------------------------------
-- 2) LIGAR O RLS EM TUDO
--
-- Tabela sem RLS no Supabase é tabela aberta na internet. A lista abaixo tem
-- que cobrir TODA tabela do 01_schema.sql — se criar tabela nova, volte aqui.
-- ---------------------------------------------------------------------------

alter table public.saloes                 enable row level security;
alter table public.perfis                 enable row level security;
alter table public.vinculos               enable row level security;
alter table public.profissionais          enable row level security;
alter table public.servicos               enable row level security;
alter table public.servicos_profissionais enable row level security;
alter table public.jornadas               enable row level security;
alter table public.bloqueios              enable row level security;
alter table public.clientes               enable row level security;
alter table public.agendamentos           enable row level security;
alter table public.agendamento_servicos   enable row level security;
alter table public.lista_espera           enable row level security;
alter table public.produtos               enable row level security;
alter table public.comandas               enable row level security;
alter table public.comanda_itens          enable row level security;
alter table public.pagamentos             enable row level security;
alter table public.contadores             enable row level security;
alter table public.planos                 enable row level security;
alter table public.assinaturas            enable row level security;

-- ---------------------------------------------------------------------------
-- 3) SALÃO
-- ---------------------------------------------------------------------------

drop policy if exists salao_ler on public.saloes;
create policy salao_ler on public.saloes for select to authenticated
  using ( tem_acesso(id) );

drop policy if exists salao_gerir on public.saloes;
create policy salao_gerir on public.saloes for update to authenticated
  using ( e_gestor(id) ) with check ( e_gestor(id) );

-- Criar e apagar salão é ato da plataforma, não do salão.
drop policy if exists salao_criar on public.saloes;
create policy salao_criar on public.saloes for insert to authenticated
  with check ( is_super() );

-- ---------------------------------------------------------------------------
-- 3b) PLANO E ASSINATURA
--
-- A tabela de planos é vitrine: todo mundo logado pode ler, porque é o que a
-- tela de "trocar de plano" mostra. Quem MEXE é só a plataforma.
--
-- A assinatura o dono lê — precisa saber até quando vai o teste e quanto
-- paga — mas não escreve. Deixar o dono editar a própria assinatura é o
-- mesmo que deixar o cliente digitar o preço: ele se põe no plano de 20
-- profissionais em dois cliques.
-- ---------------------------------------------------------------------------

-- Preço é público. A página de cadastro mostra os planos ANTES de existir
-- login — se `anon` não lê esta tabela, o visitante vê a tela de preços
-- vazia e vai embora. Foi assim que este furo apareceu: a bancada de teste
-- respondeu "permission denied for table planos" ao carregar a página.
drop policy if exists plano_ler on public.planos;
create policy plano_ler on public.planos for select to anon, authenticated
  using ( ativo or is_super() );

drop policy if exists plano_gerir on public.planos;
create policy plano_gerir on public.planos for all to authenticated
  using ( is_super() ) with check ( is_super() );

drop policy if exists assin_ler on public.assinaturas;
create policy assin_ler on public.assinaturas for select to authenticated
  using ( e_gestor(salao_id) );

drop policy if exists assin_gerir on public.assinaturas;
create policy assin_gerir on public.assinaturas for all to authenticated
  using ( is_super() ) with check ( is_super() );

-- ---------------------------------------------------------------------------
-- 4) PERFIL — a identidade global
--
-- Ninguém lê o perfil de ninguém. Nem a recepção: para ela existe a ficha do
-- cliente (`clientes`), que é a cópia daquele salão. Assim o telefone que a
-- pessoa deu na barbearia não aparece no salão do outro lado da rua.
-- ---------------------------------------------------------------------------

drop policy if exists perfil_meu on public.perfis;
create policy perfil_meu on public.perfis for select to authenticated
  using ( id = auth.uid() or is_super() );

drop policy if exists perfil_editar on public.perfis;
create policy perfil_editar on public.perfis for update to authenticated
  using ( id = auth.uid() )
  -- Ninguém se promove a dono da plataforma editando o próprio perfil.
  with check ( id = auth.uid()
               and super_admin = (select p.super_admin from public.perfis p
                                   where p.id = auth.uid()) );

-- O cadastro em si é feito pelo gatilho do 03 (a partir do auth.users),
-- não por INSERT vindo do navegador. Por isso não existe policy de insert.

-- ---------------------------------------------------------------------------
-- 5) VÍNCULOS — quem entra em qual salão
-- ---------------------------------------------------------------------------

drop policy if exists vinc_meus on public.vinculos;
create policy vinc_meus on public.vinculos for select to authenticated
  using ( perfil_id = auth.uid() or e_equipe(salao_id) );

-- Virar CLIENTE de um salão é livre: é o que acontece quando a pessoa abre o
-- link e agenda pela primeira vez. Virar equipe, não — o dono precisa liberar.
drop policy if exists vinc_virar_cliente on public.vinculos;
create policy vinc_virar_cliente on public.vinculos for insert to authenticated
  with check ( perfil_id = auth.uid() and papel = 'cliente' and status = 'ativo' );

drop policy if exists vinc_gerir on public.vinculos;
create policy vinc_gerir on public.vinculos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

-- ---------------------------------------------------------------------------
-- 6) CATÁLOGO — profissionais, serviços, jornada
--
-- Cliente logado LÊ (precisa escolher com quem e o quê), só a gestão ESCREVE.
-- ---------------------------------------------------------------------------

drop policy if exists prof_ler on public.profissionais;
create policy prof_ler on public.profissionais for select to authenticated
  using ( tem_acesso(salao_id) );
drop policy if exists prof_gerir on public.profissionais;
create policy prof_gerir on public.profissionais for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists serv_ler on public.servicos;
create policy serv_ler on public.servicos for select to authenticated
  using ( tem_acesso(salao_id) );
drop policy if exists serv_gerir on public.servicos;
create policy serv_gerir on public.servicos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists sp_ler on public.servicos_profissionais;
create policy sp_ler on public.servicos_profissionais for select to authenticated
  using ( exists (select 1 from public.servicos s
                   where s.id = servico_id and tem_acesso(s.salao_id)) );
drop policy if exists sp_gerir on public.servicos_profissionais;
create policy sp_gerir on public.servicos_profissionais for all to authenticated
  using ( exists (select 1 from public.servicos s
                   where s.id = servico_id and e_gestor(s.salao_id)) )
  with check ( exists (select 1 from public.servicos s
                        where s.id = servico_id and e_gestor(s.salao_id)) );

drop policy if exists jor_ler on public.jornadas;
create policy jor_ler on public.jornadas for select to authenticated
  using ( exists (select 1 from public.profissionais p
                   where p.id = profissional_id and tem_acesso(p.salao_id)) );
drop policy if exists jor_gerir on public.jornadas;
create policy jor_gerir on public.jornadas for all to authenticated
  using ( exists (select 1 from public.profissionais p
                   where p.id = profissional_id
                     and (e_gestor(p.salao_id) or p.perfil_id = auth.uid())) )
  with check ( exists (select 1 from public.profissionais p
                        where p.id = profissional_id
                          and (e_gestor(p.salao_id) or p.perfil_id = auth.uid())) );

-- Bloqueio é só da equipe: o motivo ("consulta médica") é assunto interno.
-- O cliente descobre que o horário sumiu pela função de horários livres, sem
-- saber por quê — que é exatamente o certo.
drop policy if exists bloq_equipe on public.bloqueios;
create policy bloq_equipe on public.bloqueios for select to authenticated
  using ( e_equipe(salao_id) );
drop policy if exists bloq_gerir on public.bloqueios;
create policy bloq_gerir on public.bloqueios for all to authenticated
  using ( e_gestor(salao_id)
          or profissional_id = meu_profissional_id(salao_id) )
  with check ( e_gestor(salao_id)
               or profissional_id = meu_profissional_id(salao_id) );

-- ---------------------------------------------------------------------------
-- 7) CLIENTE — a ficha
-- ---------------------------------------------------------------------------

drop policy if exists cli_equipe on public.clientes;
create policy cli_equipe on public.clientes for all to authenticated
  using ( e_equipe(salao_id) ) with check ( e_equipe(salao_id) );

-- O cliente vê e edita a PRÓPRIA ficha — e só os campos dele. Note que
-- `obs`, `alergias` e `ficha` ficam visíveis para ele: é dado dele, LGPD
-- manda deixar ver. Se um dia a equipe quiser anotação interna que o cliente
-- não lê, isso vira outra tabela — não um campo escondido nesta.
drop policy if exists cli_eu on public.clientes;
create policy cli_eu on public.clientes for select to authenticated
  using ( perfil_id = auth.uid() );

-- Virar cliente de um salão é ato da própria pessoa: é o que acontece na
-- primeira vez que ela marca pelo link. Sem esta policy o autoatendimento
-- simplesmente não funciona — e era o caso: o furo só apareceu no teste
-- ponta a ponta contra um Postgres de verdade, porque no modo demonstração
-- não existe RLS para barrar.
--
-- É seguro: o `with check` amarra a ficha ao próprio perfil, então ninguém
-- cria ficha em nome de outra pessoa. E o índice único impede duplicar.
drop policy if exists cli_eu_criar on public.clientes;
create policy cli_eu_criar on public.clientes for insert to authenticated
  with check ( perfil_id = auth.uid() );

drop policy if exists cli_eu_editar on public.clientes;
create policy cli_eu_editar on public.clientes for update to authenticated
  using ( perfil_id = auth.uid() )
  with check ( perfil_id = auth.uid() );

-- ---------------------------------------------------------------------------
-- 8) AGENDA — a policy mais importante do sistema
--
-- Aqui é onde um erro custa caro. Uma policy generosa do tipo
--   using ( tem_acesso(salao_id) )
-- pareceria certa na tela (o app só mostra o que é do cliente), e vazaria
-- nome, telefone e histórico de TODA a clientela para qualquer pessoa
-- cadastrada — bastaria chamar a API REST direto do navegador.
--
-- Por isso o cliente enxerga exatamente os agendamentos cujo `cliente_id`
-- é a ficha dele, e nada mais. Horário livre ele obtém pela função do
-- 03_funcoes_agenda.sql, que devolve horários — não devolve linhas.
-- ---------------------------------------------------------------------------

drop policy if exists agenda_ler on public.agendamentos;
create policy agenda_ler on public.agendamentos for select to authenticated
  using (
       ve_agenda_toda(salao_id)                          -- dono, admin, recepção
    or profissional_id = meu_profissional_id(salao_id)   -- o profissional, a dele
    or cliente_id      = meu_cliente_id(salao_id)        -- o cliente, os dele
  );

-- ⚠ NUNCA use `for all` numa tabela onde a leitura é restrita.
--
-- `for all` vale também para SELECT, e o Postgres soma as policies permissivas
-- com OU. Uma policy de escrita `for all using (e_equipe(salao_id))` colocada
-- ao lado da `agenda_ler` acima ANULA a restrição de leitura: a profissional,
-- que é equipe, volta a enxergar a agenda das colegas.
--
-- Foi exatamente isso que aconteceu na primeira versão deste arquivo, e quem
-- pegou foi o caso 'a profissional vê a própria agenda' do 02_rls.test.sql.
-- Por isso escrita vai separada, verbo por verbo.
--
-- Cliente não escreve aqui: ele passa pela função `agendar()`, que confere
-- jornada, bloqueio e antecedência. Sem isso marcaria 3h da manhã de domingo,
-- com o preço que ele mesmo escolhesse.
drop policy if exists agenda_equipe on public.agendamentos;
drop policy if exists agenda_criar on public.agendamentos;
create policy agenda_criar on public.agendamentos for insert to authenticated
  with check ( e_equipe(salao_id) );

-- Remarcar o atendimento de outra pessoa é coisa da recepção. O profissional
-- mexe no que é dele.
drop policy if exists agenda_editar on public.agendamentos;
create policy agenda_editar on public.agendamentos for update to authenticated
  using ( ve_agenda_toda(salao_id)
          or profissional_id = meu_profissional_id(salao_id) )
  with check ( ve_agenda_toda(salao_id)
               or profissional_id = meu_profissional_id(salao_id) );

drop policy if exists agenda_apagar on public.agendamentos;
create policy agenda_apagar on public.agendamentos for delete to authenticated
  using ( ve_agenda_toda(salao_id) );

drop policy if exists ags_ler on public.agendamento_servicos;
create policy ags_ler on public.agendamento_servicos for select to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id
                     and ( ve_agenda_toda(a.salao_id)
                        or a.profissional_id = meu_profissional_id(a.salao_id)
                        or a.cliente_id      = meu_cliente_id(a.salao_id) )) );

-- Mesma armadilha da tabela de cima: escrita separada, para não reabrir a
-- leitura restrita da `ags_ler`.
drop policy if exists ags_equipe on public.agendamento_servicos;
drop policy if exists ags_criar on public.agendamento_servicos;
create policy ags_criar on public.agendamento_servicos for insert to authenticated
  with check ( exists (select 1 from public.agendamentos a
                        where a.id = agendamento_id and e_equipe(a.salao_id)) );

drop policy if exists ags_editar on public.agendamento_servicos;
create policy ags_editar on public.agendamento_servicos for update to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id and e_equipe(a.salao_id)) )
  with check ( exists (select 1 from public.agendamentos a
                        where a.id = agendamento_id and e_equipe(a.salao_id)) );

drop policy if exists ags_apagar on public.agendamento_servicos;
create policy ags_apagar on public.agendamento_servicos for delete to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id and e_equipe(a.salao_id)) );

-- ---------------------------------------------------------------------------
-- 8b) LISTA DE ESPERA
--
-- Mesma regra da agenda: a equipe vê a fila inteira, o cliente vê só o lugar
-- dele. Uma fila aberta diria a todo mundo quem mais quer horário naquele
-- salão — e com nome e ficha junto, porque `cliente_id` leva a `clientes`.
-- ---------------------------------------------------------------------------

drop policy if exists espera_ler on public.lista_espera;
create policy espera_ler on public.lista_espera for select to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- Entrar na fila é ato do próprio cliente, ou da recepção por telefone.
drop policy if exists espera_entrar on public.lista_espera;
create policy espera_entrar on public.lista_espera for insert to authenticated
  with check ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- O cliente desiste; a equipe move o status conforme chama e atende.
drop policy if exists espera_mexer on public.lista_espera;
create policy espera_mexer on public.lista_espera for update to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) )
  with check ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

drop policy if exists espera_apagar on public.lista_espera;
create policy espera_apagar on public.lista_espera for delete to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- ---------------------------------------------------------------------------
-- 9) DINHEIRO — comanda, itens, pagamento, produto
--
-- Profissional vê o que é dele (a comissão dele). Faturamento do salão é da
-- gestão. Cliente vê a própria conta, que é o recibo dele.
-- ---------------------------------------------------------------------------

drop policy if exists prod_ler on public.produtos;
create policy prod_ler on public.produtos for select to authenticated
  using ( e_equipe(salao_id) );
drop policy if exists prod_gerir on public.produtos;
create policy prod_gerir on public.produtos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists com_ler on public.comandas;
create policy com_ler on public.comandas for select to authenticated
  using ( ve_agenda_toda(salao_id)
          or cliente_id = meu_cliente_id(salao_id)
          or tenho_item_na_comanda(id) );

drop policy if exists com_caixa on public.comandas;
create policy com_caixa on public.comandas for all to authenticated
  using ( ve_agenda_toda(salao_id) ) with check ( ve_agenda_toda(salao_id) );

drop policy if exists item_ler on public.comanda_itens;
create policy item_ler on public.comanda_itens for select to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id))
          or cliente_da_comanda(comanda_id)
               = meu_cliente_id(salao_da_comanda(comanda_id))
          or profissional_id
               = meu_profissional_id(salao_da_comanda(comanda_id)) );

-- Terceira ocorrência da mesma armadilha, e a de consequência mais
-- constrangedora: com `for all` aqui, um profissional leria a comissão de
-- todos os colegas — o item guarda `comissao_pct` e `comissao_valor`.
drop policy if exists item_caixa on public.comanda_itens;
drop policy if exists item_criar on public.comanda_itens;
create policy item_criar on public.comanda_itens for insert to authenticated
  with check ( e_equipe(salao_da_comanda(comanda_id)) );

drop policy if exists item_editar on public.comanda_itens;
create policy item_editar on public.comanda_itens for update to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) )
  with check ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

drop policy if exists item_apagar on public.comanda_itens;
create policy item_apagar on public.comanda_itens for delete to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

drop policy if exists pgto_ler on public.pagamentos;
create policy pgto_ler on public.pagamentos for select to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id))
          or cliente_da_comanda(comanda_id)
               = meu_cliente_id(salao_da_comanda(comanda_id)) );

drop policy if exists pgto_caixa on public.pagamentos;
create policy pgto_caixa on public.pagamentos for all to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) )
  with check ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

-- `contadores` fica com RLS ligado e SEM nenhuma policy: ninguém alcança pelo
-- navegador. Só a função `proximo_numero`, que é security definer, escreve
-- ali. Se alguém pudesse editar, daria para repetir número de comanda.

-- ---------------------------------------------------------------------------
-- 10) A VITRINE PÚBLICA (sem login)
--
-- A página de agendamento precisa mostrar o salão, os serviços e quem atende
-- ANTES de a pessoa se cadastrar. Isso sai por vistas de colunas escolhidas a
-- dedo — nunca liberando a tabela para `anon`.
--
-- Repare no que NÃO está aqui: preço de custo, comissão, telefone de cliente,
-- e nada de agendamento. O que é público é o cardápio, não a casa inteira.
-- ---------------------------------------------------------------------------

create or replace view public.saloes_publicos as
  select id, slug, nome, tipo, logo, whatsapp, endereco, fuso
    from public.saloes where status = 'ativo';

create or replace view public.servicos_publicos as
  select s.id, s.salao_id, s.nome, s.categoria, s.descricao,
         s.duracao_min, s.preco
    from public.servicos s
    join public.saloes sa on sa.id = s.salao_id
   where s.ativo and s.aceita_online and sa.status = 'ativo';

create or replace view public.profissionais_publicos as
  select p.id, p.salao_id, coalesce(p.apelido, p.nome) as nome, p.foto,
         array(select sp.servico_id from public.servicos_profissionais sp
                where sp.profissional_id = p.id) as servicos
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.ativo and p.aceita_online and sa.status = 'ativo';

-- ── A LIMPEZA VEM ANTES DE QUALQUER GRANT ─────────────────────────────────
-- Precisa estar AQUI, e não lá embaixo junto do resto das permissões: um
-- `revoke all on all tables` alcança as vistas também, e colocado depois ele
-- apagaria os três grants logo abaixo. Zerar primeiro, distribuir depois.
--
-- O que se zera: o Supabase liga por padrão a opção "Automatically expose new
-- tables", que dá ALL — select, insert, update, delete, truncate — para
-- `anon` e `authenticated` em toda tabela nova do schema `public`. Quer dizer
-- que no momento em que o 01_schema.sql cria as tabelas, elas já nascem com o
-- balcão aberto, antes deste arquivo dizer qualquer coisa.
--
-- Conferido num projeto de verdade: as 20 tabelas apareceram liberadas para
-- `anon`. Ninguém leu nada — o RLS segurou, e escrever levou "new row
-- violates row-level security policy". A dona do salão também não conseguiu
-- se promover de plano: `update 0`.
--
-- Mas depender só do RLS é usar uma camada quando dá para ter duas. Com o
-- grant no lugar, UMA policy escrita com pressa — um `using (true)` num
-- sábado à noite — vira vazamento público na hora. Sem o grant, a mesma
-- policy descuidada continua inalcançável: quem não fez login nem chega na
-- tabela para a policy ser consultada.
--
-- E fazer isso em SQL, e não na caixinha da interface, é o que mantém o banco
-- certo mesmo que a opção esteja ligada, mesmo que alguém religue depois, e
-- mesmo num projeto criado por outra pessoa.
-- ---------------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;

-- E as tabelas que ainda não existem. `alter default privileges` sem `for
-- role` vale para o papel que está rodando isto — o `postgres`, que é o que o
-- SQL Editor usa e o mesmo para quem o Supabase definiu o padrão permissivo.
-- Sem esta linha, a próxima tabela nasceria aberta de novo.
alter default privileges in schema public
  revoke all on tables from anon, authenticated;

-- Agora sim, o que cada um recebe de volta.
grant select on public.saloes_publicos        to anon, authenticated;
grant select on public.servicos_publicos      to anon, authenticated;
grant select on public.profissionais_publicos to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11) PERMISSÕES DE TABELA
--
-- O RLS filtra LINHA; o grant decide se a pessoa chega na TABELA. Precisa dos
-- dois. `anon` não recebe nada: quem não fez login só enxerga as vistas acima.
-- A zeragem que garante esse "nada" está mais acima, antes dos grants das
-- vistas — se estivesse aqui, apagaria os três.
-- ---------------------------------------------------------------------------

grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on
  public.saloes, public.perfis, public.vinculos, public.profissionais,
  public.servicos, public.servicos_profissionais, public.jornadas,
  public.bloqueios, public.clientes, public.agendamentos,
  public.agendamento_servicos, public.lista_espera, public.produtos,
  public.comandas, public.comanda_itens, public.pagamentos
  to authenticated;

grant select on public.comandas_totais to authenticated;
grant select on public.planos to anon, authenticated;
grant select on public.assinaturas to authenticated;

revoke all on public.contadores from anon, authenticated;

-- ###########################################################################
-- ## 03_onboarding.sql
-- ###########################################################################

-- ===========================================================================
-- AgendaPro — 03_onboarding.sql
-- O dono se cadastra sozinho. Rodar DEPOIS do 01 e do 02.
--
-- O problema que este arquivo resolve: a policy `salao_criar` só deixa
-- `is_super()` inserir salão, e isso está certo — criar inquilino é ato da
-- plataforma. Mas se só a plataforma cria, alguém precisa atender o telefone
-- toda vez que um barbeiro quiser testar às 23h de domingo.
--
-- A saída é uma função `security definer`: ela passa por cima do RLS, mas
-- faz exatamente uma coisa, com as regras todas dentro. O dono não ganha
-- permissão de escrever em `saloes`; ele ganha permissão de chamar ESTA
-- função, que escreve por ele do jeito certo.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) O APELIDO DO SALÃO NO ENDEREÇO
-- ---------------------------------------------------------------------------

-- "Barbearia Os Meninos dá Vila" -> "barbearia-os-meninos-da-vila"
-- `unaccent` resolveria isso, mas é extensão a mais para instalar; a
-- tradução literal cobre o português e não deixa dependência pendurada.
create or replace function public.virar_slug(p_texto text)
returns text language sql immutable as $$
  select trim(both '-' from
    regexp_replace(
      regexp_replace(
        lower(translate(coalesce(p_texto,''),
          'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
          'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn')),
        '[^a-z0-9]+', '-', 'g'),
      '-{2,}', '-', 'g'))
$$;

-- O apelido está livre? A tela pergunta enquanto a pessoa digita, então
-- precisa ser alcançável por quem ainda não fez login.
create or replace function public.slug_disponivel(p_slug text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'
     and not exists (select 1 from public.saloes where slug = p_slug)
$$;

-- Sugere um apelido livre a partir do nome. Se "barbearia-do-ze" já existe,
-- tenta "barbearia-do-ze-2", e assim por diante — em vez de devolver erro e
-- deixar a pessoa adivinhando.
create or replace function public.sugerir_slug(p_nome text)
returns text language plpgsql stable security definer set search_path = public as $$
declare base text; tentativa text; i int := 1;
begin
  base := left(public.virar_slug(p_nome), 40);
  if length(base) < 3 then base := 'salao'; end if;
  tentativa := base;
  while exists (select 1 from public.saloes where slug = tentativa) loop
    i := i + 1;
    tentativa := base || '-' || i;
    if i > 200 then                       -- rede, para não girar à toa
      tentativa := base || '-' || substr(md5(random()::text), 1, 6);
      exit;
    end if;
  end loop;
  return tentativa;
end $$;

-- Documento fiscal fica separado, com RLS próprio: é o dado mais sensível
-- do cadastro do dono e não tem por que morar perto do resto.
create table if not exists public.documentos_cobranca (
  salao_id  uuid primary key references public.saloes(id) on delete cascade,
  documento text not null check (documento ~ '^[0-9]{11}$|^[0-9]{14}$'),
  criado_em timestamptz not null default now()
);

alter table public.documentos_cobranca enable row level security;

drop policy if exists doc_ler on public.documentos_cobranca;
create policy doc_ler on public.documentos_cobranca for select to authenticated
  using ( e_gestor(salao_id) );

-- Só a plataforma escreve. O dono manda o documento pela função de cadastro;
-- depois disso, mudar CPF de contrato é assunto de suporte, não de tela.
drop policy if exists doc_gerir on public.documentos_cobranca;
create policy doc_gerir on public.documentos_cobranca for all to authenticated
  using ( is_super() ) with check ( is_super() );

grant select on public.documentos_cobranca to authenticated;

-- ---------------------------------------------------------------------------
-- 2) CRIAR O SALÃO
--
-- Uma chamada faz tudo o que precisa acontecer junto: o salão, a assinatura
-- em teste, o vínculo de dono e o primeiro profissional. Se qualquer parte
-- falhar, nada fica pela metade — é uma função, logo uma transação.
--
-- Meia criação seria o pior resultado possível: um salão sem dono é um
-- registro que ninguém alcança nem para apagar, porque o RLS pede vínculo.
-- ---------------------------------------------------------------------------

create or replace function public.criar_salao(
  p_nome_salao   text,
  p_tipo         text default 'salao',
  p_slug         text default null,
  p_telefone     text default null,
  p_documento    text default null,      -- CPF ou CNPJ, para a cobrança
  p_origem       text default null,      -- por onde a pessoa nos achou
  p_indicado_por text default null
)
returns table (salao_id uuid, slug text)
language plpgsql security definer set search_path = public as $$
declare
  v_perfil uuid := auth.uid();
  v_slug   text;
  v_salao  uuid;
  v_dias   int := 7;                      -- duração do teste grátis
begin
  if v_perfil is null then
    raise exception 'Faça login antes de criar o salão.'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.perfis where id = v_perfil) then
    raise exception 'Complete seu cadastro antes de criar o salão.'
      using errcode = 'foreign_key_violation';
  end if;

  if length(btrim(coalesce(p_nome_salao,''))) < 2 then
    raise exception 'Dê um nome ao estabelecimento.'
      using errcode = 'check_violation';
  end if;

  -- Uma pessoa dona de muitos salões é possível (rede de barbearias), mas
  -- dezenas viram fábrica de teste grátis. O limite é folgado de propósito.
  if (select count(*) from public.vinculos
       where perfil_id = v_perfil and papel = 'dono') >= 10 then
    raise exception 'Você já tem 10 estabelecimentos. Fale com a gente para abrir mais.'
      using errcode = 'check_violation';
  end if;

  v_slug := coalesce(nullif(btrim(p_slug), ''), public.sugerir_slug(p_nome_salao));
  v_slug := public.virar_slug(v_slug);

  if not public.slug_disponivel(v_slug) then
    -- Não devolve erro seco: escolhe o próximo livre e avisa qual ficou.
    v_slug := public.sugerir_slug(v_slug);
  end if;

  insert into public.saloes (slug, nome, tipo, telefone, whatsapp, status)
  values (v_slug, btrim(p_nome_salao),
          coalesce(nullif(p_tipo,''), 'salao'),
          p_telefone, p_telefone, 'ativo')
  returning id into v_salao;

  insert into public.assinaturas
    (salao_id, plano, status, trial_ate, origem, indicado_por)
  values (v_salao, 'trial', 'trial', current_date + v_dias,
          p_origem, p_indicado_por);

  insert into public.vinculos (perfil_id, salao_id, papel, status)
  values (v_perfil, v_salao, 'dono', 'ativo');

  -- O dono também atende, na esmagadora maioria dos casos. Já entra como o
  -- primeiro profissional — e é justamente o 1 que o teste grátis permite.
  insert into public.profissionais (salao_id, perfil_id, nome, comissao_pct)
  select v_salao, v_perfil, p.nome, 100 from public.perfis p where p.id = v_perfil;

  -- O documento é da COBRANÇA, não do salão: guardar CPF junto do cadastro
  -- público seria expor documento em tabela que o cliente final lê.
  --
  -- ⚠ Repare no `documentos_cobranca.salao_id` escrito por extenso. Esta
  -- função declara `returns table (salao_id …)`, e isso cria uma variável de
  -- saída com o MESMO NOME da coluna. Um `where salao_id = …` solto aqui
  -- dentro para o Postgres com "column reference is ambiguous" — foi
  -- exatamente o que aconteceu na primeira versão. Dentro de plpgsql com
  -- OUT params, qualifique sempre.
  -- Insert simples, sem `on conflict`: o salão nasceu duas linhas acima,
  -- então não existe documento para conflitar. E o alvo do `on conflict` é
  -- um dos poucos lugares do SQL que NÃO aceita qualificação por tabela,
  -- então ali a ambiguidade não teria conserto.
  if p_documento is not null and btrim(p_documento) <> '' then
    insert into public.documentos_cobranca (salao_id, documento)
    values (v_salao, regexp_replace(p_documento, '\D', '', 'g'));
  end if;

  return query select v_salao, v_slug;
end $$;

-- ---------------------------------------------------------------------------
-- 3) QUEM PODE CHAMAR O QUÊ
--
-- `criar_salao` é a única porta pela qual alguém de fora cria inquilino, e
-- é por isso que ela é curta e fechada. Já a consulta de apelido precisa
-- abrir para quem ainda não entrou: a tela de cadastro pergunta enquanto a
-- pessoa digita, antes de existir login.
-- ---------------------------------------------------------------------------

revoke all on function public.criar_salao(text,text,text,text,text,text,text) from public;
grant execute on function public.criar_salao(text,text,text,text,text,text,text)
  to authenticated;

grant execute on function public.slug_disponivel(text) to anon, authenticated;
grant execute on function public.sugerir_slug(text)    to anon, authenticated;
grant execute on function public.virar_slug(text)      to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) O QUE O DONO VÊ DA PRÓPRIA CONTA
--
-- Uma vista só, para a tela de assinatura não precisar de quatro consultas.
-- `security_invoker` é obrigatório: sem isso a vista roda com os poderes de
-- quem a criou e um dono leria a conta do outro.
-- ---------------------------------------------------------------------------

create or replace view public.minha_assinatura
with (security_invoker = true) as
  select a.salao_id,
         s.nome        as salao_nome,
         s.slug,
         s.tipo,
         a.plano,
         pl.nome       as plano_nome,
         pl.preco_mes,
         pl.max_profissionais,
         a.status,
         a.trial_ate,
         a.vence_em,
         (select count(*) from public.profissionais p
           where p.salao_id = a.salao_id and p.ativo) as profissionais_ativos,
         case when a.status = 'trial' and a.trial_ate is not null
              then greatest(a.trial_ate - current_date, 0) end as dias_de_teste
    from public.assinaturas a
    join public.saloes s  on s.id = a.salao_id
    join public.planos pl on pl.codigo = a.plano;

grant select on public.minha_assinatura to authenticated;

-- ###########################################################################
-- ## 04_imagens.sql
-- ###########################################################################

-- ===========================================================================
-- AgendaPro — imagens do salão (Supabase Storage)
-- ---------------------------------------------------------------------------
-- Logo, foto da fachada/equipe e foto por serviço. São três imagens com o
-- mesmo destino e a mesma regra, então um balde só resolve.
--
-- O balde é PÚBLICO para leitura, e isso é escolha, não descuido: essas fotos
-- existem para aparecer na vitrine, que abre antes de qualquer login. Uma
-- imagem atrás de autenticação numa página pública é imagem que não carrega.
--
-- O que NÃO é público é a escrita. Só quem é dono ou gerente do salão escreve,
-- e só dentro da pasta do próprio salão.
--
-- Convenção de caminho — é ela que a policy usa para saber de quem é o arquivo:
--
--     <salao_id>/logo.jpg
--     <salao_id>/capa.jpg
--     <salao_id>/servico-<servico_id>.jpg
--
-- A primeira pasta é sempre o uuid do salão. Sem isso, qualquer dono logado
-- sobrescreveria a logo do salão do vizinho.
--
-- Rode DEPOIS do 01, 02 e 03.
-- ===========================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('salao', 'salao', true, 3145728,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
   set public             = excluded.public,
       file_size_limit    = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

-- O limite de 3 MB é a última linha de defesa. O navegador já reduz a imagem
-- antes de enviar (imagens.js), mas quem chama a API direto não passa por lá —
-- e um balde sem limite é conta de armazenamento crescendo sozinha.

-- ---------------------------------------------------------------------------
-- De qual salão é este arquivo
-- ---------------------------------------------------------------------------
-- `storage.foldername(name)` devolve as pastas do caminho. A primeira é o uuid
-- do salão. O regexp antes do cast não é preciosismo: um arquivo solto na raiz
-- do balde, ou numa pasta com nome qualquer, faria o `::uuid` levantar exceção
-- dentro da policy — e policy que levanta exceção derruba a consulta inteira,
-- em vez de simplesmente negar.
create or replace function public.salao_do_arquivo(p_nome text)
returns uuid language sql immutable set search_path = public, storage as $$
  select case
    when (storage.foldername(p_nome))[1] ~*
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then (storage.foldername(p_nome))[1]::uuid
  end
$$;

-- ---------------------------------------------------------------------------
-- Policies do balde
-- ---------------------------------------------------------------------------
drop policy if exists img_ler      on storage.objects;
drop policy if exists img_enviar   on storage.objects;
drop policy if exists img_trocar   on storage.objects;
drop policy if exists img_apagar   on storage.objects;

-- Ler: qualquer um, inclusive quem nunca fez login. É a vitrine.
create policy img_ler on storage.objects for select to anon, authenticated
  using ( bucket_id = 'salao' );

-- Escrever: só gestor, só na pasta do próprio salão.
create policy img_enviar on storage.objects for insert to authenticated
  with check (
    bucket_id = 'salao'
    and public.e_gestor(public.salao_do_arquivo(name))
  );

create policy img_trocar on storage.objects for update to authenticated
  using      ( bucket_id = 'salao' and public.e_gestor(public.salao_do_arquivo(name)) )
  with check ( bucket_id = 'salao' and public.e_gestor(public.salao_do_arquivo(name)) );

create policy img_apagar on storage.objects for delete to authenticated
  using ( bucket_id = 'salao' and public.e_gestor(public.salao_do_arquivo(name)) );

grant execute on function public.salao_do_arquivo(text) to anon, authenticated;

-- ###########################################################################
-- ## 05_agenda.sql
-- ###########################################################################

-- ===========================================================================
-- AgendaPro — 05: a agenda pública
--
-- Este arquivo existe por um motivo só: hoje quem calcula horário livre é o
-- JavaScript de `agendar.html`, contra o localStorage. Isso funciona para
-- conhecer o sistema e não funciona para nada além disso — o link que o dono
-- copia no fim do cadastro abre vazio no celular da cliente, porque o dado
-- mora no navegador dele.
--
-- Aqui a conta passa a ser do banco. Duas funções:
--
--   horarios_livres()  — que horas cabem, para este profissional, neste dia
--   agendar()          — marca, ou explica por que não deu
--
-- ── POR QUE `security definer` ─────────────────────────────────────────────
-- Quem abre o link é `anon`: não fez login, e o RLS não deixa ele chegar em
-- `agendamentos`, `jornadas` nem `bloqueios` — e está certo, porque a lista de
-- clientes do salão não é pública. Mas o horário vago é. Estas funções rodam
-- com o dono delas, olham o que precisam, e devolvem SÓ o horário.
--
-- Toda função aqui leva `set search_path = public`. Sem isso, quem consegue
-- criar uma tabela num schema que venha antes no caminho consegue fazer a
-- função `security definer` ler a tabela dele em vez da nossa.
--
-- ── A REGRA QUE NÃO SE NEGOCIA ─────────────────────────────────────────────
-- A duração e o preço NUNCA vêm do navegador. `agendar()` recebe a LISTA DE
-- SERVIÇOS e soma a duração aqui dentro. Se recebesse `duracao_min`, qualquer
-- pessoa com o console aberto marcaria uma escova de 3 horas ocupando 15
-- minutos da agenda — e a cadeira estaria vendida em dobro no dia seguinte.
-- Mesma coisa com o preço: chega do banco, não do formulário.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Peças pequenas
-- ---------------------------------------------------------------------------

-- Telefone só serve para achar a mesma pessoa de novo se for guardado sempre
-- do mesmo jeito. Existe um índice único em (salao_id, telefone): sem
-- normalizar, "(51) 99887-6655" e "51998876655" viram duas fichas da mesma
-- cliente, e o histórico dela racha no meio.
create or replace function public.so_digitos(p_texto text)
returns text language sql immutable set search_path = public as $$
  select nullif(regexp_replace(coalesce(p_texto, ''), '[^0-9]', '', 'g'), '')
$$;

-- Até quando o salão aceita marcação. Serve para dois problemas reais: quem
-- marca para daqui a seis meses quase sempre falta, e agenda aberta até o
-- infinito tira do dono a liberdade de mudar jornada, preço ou equipe.
create or replace function public.dias_liberados(p_salao uuid)
returns int language sql stable set search_path = public as $$
  select greatest(1, least(365,
    coalesce((select (cfg->>'diasLiberados')::int from public.saloes
               where id = p_salao and cfg->>'diasLiberados' ~ '^[0-9]+$'), 30)))
$$;

-- Hoje NO FUSO DO SALÃO, que não é o fuso de quem está olhando. Uma cliente
-- em Portugal abrindo o link de um salão de Porto Alegre às 3h da manhã dela
-- tem que ver o dia que é lá, não o dela.
create or replace function public.hoje_no_salao(p_salao uuid)
returns date language sql stable set search_path = public as $$
  select (now() at time zone coalesce(
           (select fuso from public.saloes where id = p_salao),
           'America/Sao_Paulo'))::date
$$;

-- ---------------------------------------------------------------------------
-- 2) Quanto tempo leva, quanto custa
--
-- A duração é a soma de `duracao_min + intervalo_min` de cada serviço. O
-- intervalo (arrumar a estação, lavar pincel) conta na agenda mas não aparece
-- para o cliente como parte do serviço — se não contasse, o profissional
-- chegaria atrasado no próximo por construção.
--
-- `servicos_profissionais` pode sobrescrever duração e preço: a Ana faz mecha
-- em 2h, a Bia em 3h. Quando há linha para aquele par, ela manda.
-- ---------------------------------------------------------------------------
create or replace function public.duracao_dos_servicos(
  p_profissional uuid, p_servicos uuid[])
returns int language sql stable set search_path = public as $$
  select coalesce(sum(
           coalesce(sp.duracao_min, s.duracao_min) + s.intervalo_min), 0)::int
    from public.servicos s
    left join public.servicos_profissionais sp
           on sp.servico_id = s.id and sp.profissional_id = p_profissional
   where s.id = any(p_servicos)
$$;

create or replace function public.preco_dos_servicos(
  p_profissional uuid, p_servicos uuid[])
returns numeric language sql stable set search_path = public as $$
  select coalesce(sum(coalesce(sp.preco, s.preco)), 0)::numeric(10,2)
    from public.servicos s
    left join public.servicos_profissionais sp
           on sp.servico_id = s.id and sp.profissional_id = p_profissional
   where s.id = any(p_servicos)
$$;

-- Este profissional faz TODOS estes serviços?
--
-- Sem nenhuma linha em `servicos_profissionais`, considera-se que ele faz
-- tudo. É como um salão pequeno começa — um profissional, cinco serviços,
-- nenhum cruzamento cadastrado — e exigir o cadastro antes de usar é o tipo
-- de exigência que faz o dono desistir na primeira tarde.
create or replace function public.profissional_faz(
  p_profissional uuid, p_servicos uuid[])
returns boolean language sql stable set search_path = public as $$
  select case
    when not exists (select 1 from public.servicos_profissionais
                      where profissional_id = p_profissional) then true
    else not exists (
      select 1 from unnest(p_servicos) as pedido(id)
       where not exists (
         select 1 from public.servicos_profissionais sp
          where sp.profissional_id = p_profissional and sp.servico_id = pedido.id))
  end
$$;

-- ---------------------------------------------------------------------------
-- 3) O salão aceita marcação online agora?
--
-- Uma função só, porque as duas pontas precisam da MESMA resposta.
-- `horarios_livres()` usa para não oferecer, e `agendar()` usa para não
-- aceitar. Se cada uma tivesse a sua cópia da regra, um dia elas discordariam
-- — e o jeito de descobrir seria uma cliente vendo "13:00 disponível" e
-- levando "esse horário não está mais livre" ao clicar.
--
-- Devolve null quando está tudo certo, ou o motivo em português.
-- ---------------------------------------------------------------------------
create or replace function public.porque_nao_agenda(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_salao uuid;
  v_hoje  date;
begin
  if p_servicos is null or cardinality(p_servicos) = 0 then
    return 'Escolha pelo menos um serviço.';
  end if;

  select p.salao_id into v_salao
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional
     and p.ativo and p.aceita_online
     and sa.status = 'ativo';

  if v_salao is null then
    return 'Este profissional não está atendendo pela agenda online.';
  end if;

  -- O profissional existe e está ativo, mas o salão caiu para um plano que
  -- não comporta a equipe inteira. O gatilho de cota recusaria a marcação lá
  -- na frente; melhor não oferecer o horário do que oferecer e voltar atrás.
  if not public.profissional_na_cota(p_profissional) then
    return 'Este profissional não está atendendo pela agenda online.';
  end if;

  if not public.recurso_bool(v_salao, 'agenda_online') then
    return 'Este salão não está aceitando marcação pela internet.';
  end if;

  -- Todo serviço pedido tem que ser deste salão, estar ativo e aceitar
  -- online. Sem esta conferência, dá para marcar um serviço de OUTRO salão
  -- colando o id na chamada — e o preço que entraria na comanda seria o de lá.
  if exists (
    select 1 from unnest(p_servicos) as pedido(id)
     where not exists (
       select 1 from public.servicos s
        where s.id = pedido.id and s.salao_id = v_salao
          and s.ativo and s.aceita_online))
  then
    return 'Um dos serviços escolhidos não está disponível.';
  end if;

  if not public.profissional_faz(p_profissional, p_servicos) then
    return 'Este profissional não faz todos os serviços escolhidos.';
  end if;

  v_hoje := public.hoje_no_salao(v_salao);

  if p_data < v_hoje then
    return 'Essa data já passou.';
  end if;

  if p_data > v_hoje + public.dias_liberados(v_salao) then
    return format('A agenda está liberada até %s.',
                  to_char(v_hoje + public.dias_liberados(v_salao), 'DD/MM/YYYY'));
  end if;

  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4) horarios_livres()
--
-- Devolve os inícios possíveis, em timestamptz. A tela formata no fuso do
-- salão (que vem em `saloes_publicos.fuso`), não no fuso do aparelho.
--
-- O passo é de 15 minutos e a última vaga é a que ainda TERMINA dentro da
-- jornada: com jornada até 19:00 e serviço de 40 minutos, 18:20 é oferecido e
-- 18:30 não. Duas linhas de jornada no mesmo dia significam almoço no meio, e
-- o laço trata cada uma por vez — por isso o horário do almoço simplesmente
-- não existe na lista, em vez de aparecer e ser recusado depois.
-- ---------------------------------------------------------------------------
create or replace function public.horarios_livres(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns setof timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_salao   uuid;
  v_fuso    text;
  v_duracao int;
  v_passo   constant interval := '15 minutes';
  -- Ninguém quer receber "disponível: daqui a 4 minutos". Meia hora é o
  -- mínimo para a pessoa conseguir sair de casa.
  v_cedo_demais constant interval := '30 minutes';
  j         record;
  v_ini     timestamptz;
  v_fim     timestamptz;
  v_ate     timestamptz;
begin
  if public.porque_nao_agenda(p_profissional, p_data, p_servicos) is not null then
    return;
  end if;

  select p.salao_id, sa.fuso into v_salao, v_fuso
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;

  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  if v_duracao <= 0 then return; end if;

  for j in
    select inicio, fim from public.jornadas
     where profissional_id = p_profissional
       and dia_semana = extract(dow from p_data)::smallint
     order by inicio
  loop
    -- A hora da jornada é hora de parede ("09:00 de segunda"). Vira instante
    -- no fuso do salão — e é isso que faz a agenda continuar certa na semana
    -- em que o horário de verão muda, porque o salão abre às 9 dos dois lados
    -- da virada, não "9 menos uma hora".
    v_ini := ((p_data + j.inicio) at time zone v_fuso);
    v_ate := ((p_data + j.fim)    at time zone v_fuso);

    while v_ini + make_interval(mins => v_duracao) <= v_ate loop
      v_fim := v_ini + make_interval(mins => v_duracao);

      if v_ini >= now() + v_cedo_demais
         and not exists (
           select 1 from public.agendamentos a
            where a.profissional_id = p_profissional
              and a.status in ('pendente','confirmado','em_atendimento','concluido')
              and tstzrange(a.inicio, a.fim, '[)') && tstzrange(v_ini, v_fim, '[)'))
         and not exists (
           select 1 from public.bloqueios b
            where b.salao_id = v_salao
              and (b.profissional_id = p_profissional or b.profissional_id is null)
              and tstzrange(b.inicio, b.fim, '[)') && tstzrange(v_ini, v_fim, '[)'))
      then
        return next v_ini;
      end if;

      v_ini := v_ini + v_passo;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5) agendar()
--
-- Marca de verdade. Recebe a lista de serviços, nunca a duração nem o preço.
--
-- Quem chama é `anon` (cliente sem login) ou `authenticated` (cliente com
-- conta). Nos dois casos a ficha do cliente é achada ou criada pelo telefone,
-- dentro daquele salão — o índice único (salao_id, telefone) garante que não
-- nasça ficha repetida, e `so_digitos()` garante que ele funcione.
-- ---------------------------------------------------------------------------
create or replace function public.agendar(
  p_profissional  uuid,
  p_inicio        timestamptz,
  p_servicos      uuid[],
  p_nome          text,
  p_telefone      text,
  p_atendido_nome text default null,
  p_obs           text default null)
returns table (id uuid, inicio timestamptz, fim timestamptz, valor numeric)
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

  -- 10 dígitos = fixo com DDD, 11 = celular. Abaixo disso é engano de
  -- digitação, e telefone errado é agendamento que vira falta: ninguém
  -- consegue avisar a pessoa de nada.
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

  -- A MESMA função que decidiu o que mostrar decide o que aceitar. Ninguém
  -- passa por aqui só porque montou a chamada na mão.
  v_motivo := public.porque_nao_agenda(p_profissional, v_data, p_servicos);
  if v_motivo is not null then
    raise exception '%', v_motivo using errcode = 'check_violation';
  end if;

  -- E o horário pedido tem que ser um dos que a função oferece. Isto fecha de
  -- uma vez o encaixe fora da jornada, o horário no meio do almoço, o que já
  -- está ocupado, o que cai em bloqueio e o "daqui a 4 minutos" — sem repetir
  -- nenhuma dessas regras aqui, que é como elas acabariam divergindo.
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

  -- ── A ficha do cliente ───────────────────────────────────────────────────
  -- Quem está logado leva o agendamento para o perfil dele; quem não está
  -- fica só com nome e telefone, e os dois se juntam no dia em que essa
  -- pessoa criar conta com o mesmo número.
  v_perfil := auth.uid();

  select c.id into v_cliente from public.clientes c
   where c.salao_id = v_salao and c.telefone = v_tel;

  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (v_salao, v_perfil, v_nome, v_tel)
      returning clientes.id into v_cliente;
  elsif v_perfil is not null then
    -- Reencontrou a ficha e agora sabe de quem é. Só preenche o que falta:
    -- sobrescrever o nome apagaria a correção que a recepção fez na ficha.
    update public.clientes
       set perfil_id = coalesce(perfil_id, v_perfil)
     where clientes.id = v_cliente;
  end if;

  -- ── Freio de spam ────────────────────────────────────────────────────────
  -- Marcação online sem senha é um formulário aberto na internet. Sem limite,
  -- um número só entope a agenda inteira de um salão em dois minutos — e o
  -- prejuízo é do dono, que passa o dia ligando para horários fantasma.
  --
  -- Três marcações futuras em aberto atende a cliente de verdade (o corte
  -- desta semana, a escova do casamento, a manutenção do mês) e trava quem
  -- está brincando. Cancelou ou foi atendida, libera vaga na conta.
  select count(*) into v_abertos from public.agendamentos a
   where a.cliente_id = v_cliente
     and a.status in ('pendente','confirmado')
     and a.inicio > now();

  if v_abertos >= 3 then
    raise exception 'Você já tem 3 horários marcados aqui. Cancele um antes de marcar outro.'
      using errcode = 'check_violation';
  end if;

  -- ── A marcação ───────────────────────────────────────────────────────────
  begin
    insert into public.agendamentos
      (salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
       valor_previsto, atendido_nome, obs, criado_por)
    values
      (v_salao, v_cliente, p_profissional, p_inicio, v_fim, 'confirmado', 'online',
       v_valor, nullif(btrim(coalesce(p_atendido_nome, '')), ''),
       nullif(btrim(coalesce(p_obs, '')), ''), v_perfil)
    returning agendamentos.id into v_agend;
  exception
    -- Duas pessoas clicando no mesmo horário no mesmo segundo. A função de
    -- horários livres viu vago para as duas; quem separa é a trava do banco,
    -- e a segunda chega aqui. O erro cru do Postgres fala em "conflicting key
    -- value violates exclusion constraint" — a cliente merece outra frase.
    when exclusion_violation then
      raise exception 'Alguém acabou de marcar esse horário. Escolha outro, por favor.'
        using errcode = 'check_violation';
  end;

  -- Duração, preço e comissão são COPIADOS agora. Se o salão reajustar a
  -- tabela amanhã, o que foi combinado com a cliente hoje continua valendo —
  -- e a comissão do profissional é calculada sobre o combinado, não sobre o
  -- preço novo.
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

  return query select v_agend, p_inicio, v_fim, v_valor;
end $$;

-- ---------------------------------------------------------------------------
-- 6) Quem pode chamar
--
-- `anon` precisa das duas: a cliente que abre o link não fez login, e obrigar
-- cadastro antes de marcar é o jeito mais rápido de perder a marcação.
--
-- Note que `anon` continua SEM chegar em `agendamentos`, `clientes`,
-- `jornadas` e `bloqueios` — o grant é da função, não das tabelas. Ele
-- consegue marcar e consegue ver horário vago; não consegue ler a agenda do
-- salão nem a lista de clientes.
-- ---------------------------------------------------------------------------
revoke all on function public.horarios_livres(uuid, date, uuid[]) from public;
revoke all on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  from public;
revoke all on function public.porque_nao_agenda(uuid, date, uuid[]) from public;

grant execute on function public.horarios_livres(uuid, date, uuid[])
  to anon, authenticated;
grant execute on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  to anon, authenticated;
grant execute on function public.porque_nao_agenda(uuid, date, uuid[])
  to anon, authenticated;
grant execute on function public.dias_liberados(uuid)   to anon, authenticated;
grant execute on function public.hoje_no_salao(uuid)    to anon, authenticated;
grant execute on function public.so_digitos(text)       to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7) Conserto na vitrine pública
--
-- `profissionais_publicos` mostrava todo profissional ativo que aceita
-- online, sem olhar a cota do plano. O salão que caiu do plano de 5 para o
-- gratuito continuava com os 5 na tela: a cliente escolhia a Bia, e o gatilho
-- de cota recusava na hora de marcar. Erro do lado errado do funil.
-- ---------------------------------------------------------------------------
create or replace view public.profissionais_publicos as
  select p.id, p.salao_id, coalesce(p.apelido, p.nome) as nome, p.foto,
         array(select sp.servico_id from public.servicos_profissionais sp
                where sp.profissional_id = p.id) as servicos
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.ativo and p.aceita_online and sa.status = 'ativo'
     and public.profissional_na_cota(p.id);

grant select on public.profissionais_publicos to anon, authenticated;

-- ###########################################################################
-- ## 06_vitrine.sql
-- ###########################################################################

-- ===========================================================================
-- AgendaPro — 06: a vitrine de UM salão
--
-- ── O PROBLEMA QUE ESTE ARQUIVO FECHA ──────────────────────────────────────
-- As vistas `saloes_publicos`, `servicos_publicos` e `profissionais_publicos`
-- estavam liberadas para `anon` sem nenhum filtro. Funcionava, e o isolamento
-- entre donos continuava intacto: nenhum salão lia agendamento, cliente ou
-- faturamento de outro — isso o RLS garante e os testes provam.
--
-- Mas havia outra coisa vazando, e não é dado de cliente: é a SUA LISTA DE
-- CLIENTES. Qualquer pessoa com a chave publicável — que fica à vista no
-- código da página, de propósito — pedia
--
--     GET /rest/v1/saloes_publicos
--
-- e recebia TODOS os salões da plataforma, com nome, endereço e WhatsApp. Um
-- concorrente monta com isso uma lista de prospecção pronta: exatamente quem
-- usa o AgendaPro, onde fica e por onde falar. Você levou meses para reunir
-- essa lista; ela sai numa requisição.
--
-- ── O QUE MUDA ─────────────────────────────────────────────────────────────
-- A cliente chega por um link com o apelido do salão. Ela NUNCA precisa de um
-- catálogo — precisa de um salão, o dela. Então o catálogo deixa de existir
-- para quem não fez login, e no lugar entra esta função, que só responde
-- quando alguém já sabe o apelido.
--
-- Isso não torna o apelido secreto: quem tem o link tem o salão, e é assim
-- que deve ser. O que muda é que ninguém mais ENUMERA. Descobrir um salão
-- passa a exigir já conhecê-lo.
--
-- Vem tudo de uma vez — salão, serviços e profissionais — em vez de três
-- idas ao servidor. No 3G da cliente, isso é a diferença entre a tela abrir
-- e a tela demorar.
-- ===========================================================================

create or replace function public.vitrine(p_slug text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'salao', jsonb_build_object(
      'id', s.id, 'slug', s.slug, 'nome', s.nome, 'tipo', s.tipo,
      'logo', s.logo, 'capa', s.capa,
      'telefone', s.telefone, 'whatsapp', s.whatsapp,
      'endereco', s.endereco, 'fuso', s.fuso,
      -- A tela precisa saber até quando desenhar o calendário. Sai daqui
      -- pronto, já com o limite aplicado, para a tela não ter que repetir a
      -- regra — e não ter como discordar dela.
      'diasLiberados', public.dias_liberados(s.id)
    ),

    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'nome', v.nome, 'categoria', v.categoria,
               'descricao', v.descricao, 'duracaoMin', v.duracao_min,
               'preco', v.preco, 'foto', v.foto)
             order by v.categoria nulls last, v.nome)
        from public.servicos v
       where v.salao_id = s.id and v.ativo and v.aceita_online), '[]'::jsonb),

    'profissionais', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'nome', coalesce(p.apelido, p.nome),
               'foto', p.foto,
               -- Lista vazia = faz tudo. É como um salão pequeno começa, e a
               -- tela já trata assim.
               'servicos', (select coalesce(jsonb_agg(sp.servico_id), '[]'::jsonb)
                              from public.servicos_profissionais sp
                             where sp.profissional_id = p.id))
             order by p.criado_em, p.id)
        from public.profissionais p
       where p.salao_id = s.id and p.ativo and p.aceita_online
         -- A cota do plano vale aqui também: profissional fora da cota não
         -- pode aparecer como opção, senão a cliente escolhe e leva um erro
         -- do gatilho na cara ao confirmar.
         and public.profissional_na_cota(p.id)), '[]'::jsonb)
  )
  from public.saloes s
  where s.slug = p_slug and s.status = 'ativo'
$$;

-- ---------------------------------------------------------------------------
-- Fechar o catálogo
--
-- As vistas continuam existindo — o painel do dono e relatórios futuros usam
-- —, mas param de ser alcançáveis por quem não fez login. E também por quem
-- fez: criar conta leva dois minutos, então deixar aberto para
-- `authenticated` seria a mesma porta com um degrau na frente.
-- ---------------------------------------------------------------------------
revoke all on public.saloes_publicos        from anon, authenticated;
revoke all on public.servicos_publicos      from anon, authenticated;
revoke all on public.profissionais_publicos from anon, authenticated;

revoke all on function public.vitrine(text) from public;
grant execute on function public.vitrine(text) to anon, authenticated;
