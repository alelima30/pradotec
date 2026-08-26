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
  cor           text not null default '#2563EB',  -- cor da coluna na agenda
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

  -- Tirado da vista sem ser apagado. O porquê está logo abaixo da tabela,
  -- junto da migração para quem já tem o banco instalado.
  arquivado_em    timestamptz,

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
  -- Arquivado também sai: ver `arquivado_em` logo abaixo.
  constraint agenda_sem_choque exclude using gist (
    profissional_id with =,
    tstzrange(inicio, fim, '[)') with &&
  ) where (status in ('pendente','confirmado','em_atendimento','concluido')
           and arquivado_em is null)
);

create index if not exists ix_agend_dia     on public.agendamentos(salao_id, inicio);
create index if not exists ix_agend_prof    on public.agendamentos(profissional_id, inicio);
create index if not exists ix_agend_cliente on public.agendamentos(cliente_id, inicio desc);

-- ── ARQUIVAR EM VEZ DE APAGAR ───────────────────────────────────────────────
-- "Excluir" apagava a linha. Sumia o atendimento, sumiam os serviços dele (o
-- banco apaga em cascata) e sumia a comanda — sem lixeira, sem desfazer.
-- Um clique errado custava o histórico, e o histórico é o que diz quanto o
-- salão faturou.
--
-- Arquivar guarda a linha e a tira da vista. O horário volta a ficar livre na
-- hora (é por isso que `arquivado_em` entra na trava anti-choque acima e em
-- toda conta de ocupação), mas o registro fica — dá para desfazer, e a
-- contabilidade do mês não muda de valor porque alguém errou o clique.
alter table public.agendamentos
  add column if not exists arquivado_em timestamptz;

-- A trava nasceu sem esta coluna nas instalações que já existem. Sem refazer,
-- arquivar não liberaria o horário: o dono apagaria o lançamento errado e
-- continuaria sem conseguir marcar em cima.
do $trava_choque$
begin
  if exists (select 1 from pg_constraint
              where conname = 'agenda_sem_choque'
                and conrelid = 'public.agendamentos'::regclass
                and pg_get_constraintdef(oid) not like '%arquivado_em%') then
    alter table public.agendamentos drop constraint agenda_sem_choque;
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'agenda_sem_choque'
                    and conrelid = 'public.agendamentos'::regclass) then
    alter table public.agendamentos add constraint agenda_sem_choque
      exclude using gist (
        profissional_id with =,
        tstzrange(inicio, fim, '[)') with &&
      ) where (status in ('pendente','confirmado','em_atendimento','concluido')
               and arquivado_em is null);
  end if;
end $trava_choque$;

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
  if new.status not in ('pendente','confirmado','em_atendimento','concluido')
     or new.arquivado_em is not null then
    return new;                    -- cancelado, faltou e arquivado liberam
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
     and a.arquivado_em is null
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
     and a.arquivado_em is null
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
