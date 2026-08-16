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
