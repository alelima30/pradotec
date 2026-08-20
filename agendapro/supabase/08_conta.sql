-- ===========================================================================
-- AgendaPro — 08: a conta vira perfil
--
-- ── O DEFEITO QUE ISTO CONSERTA ────────────────────────────────────────────
-- O cadastro chamava `/auth/v1/signup`, que cria a linha em `auth.users`, e
-- em seguida `criar_salao()`. Só que `criar_salao()` começa assim:
--
--     if not exists (select 1 from public.perfis where id = v_perfil) then
--       raise exception 'Complete seu cadastro antes de criar o salão.';
--
-- E nada, em lugar nenhum, criava essa linha. Quem se cadastrasse no Supabase
-- de verdade levaria essa frase na cara, com a conta metade criada: existe em
-- `auth.users`, não existe em `perfis`, e não dá para tentar de novo porque o
-- e-mail já está tomado.
--
-- A suíte não pegou porque a bancada de teste inseria em `perfis` no próprio
-- signup, imitando um gatilho que não existia. Terceira vez que a bancada foi
-- mais generosa que a realidade e aprovou código quebrado. Ela também foi
-- corrigida: agora depende deste gatilho, como a produção.
--
-- ── POR QUE UM GATILHO, E NÃO UM INSERT NA TELA ────────────────────────────
-- Porque o navegador não é confiável para completar uma sequência. Entre
-- criar a conta e criar o perfil cabe uma queda de rede, uma aba fechada, um
-- 3G que morre no elevador. O que sobra é o pior estado possível: conta que
-- existe e não serve para nada, com o e-mail preso.
--
-- Aqui as duas coisas nascem na MESMA transação do Supabase. Ou as duas
-- existem, ou nenhuma existe.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Telefone no formato que o banco guarda
--
-- A tela manda o que a pessoa digitou. `(51) 99887-6655`, `51998876655` e
-- `+55 51 99887-6655` são a mesma pessoa, e precisam virar a mesma linha —
-- senão o reencontro pelo telefone, que é como a recepção acha a ficha antiga
-- de alguém, simplesmente não acontece.
-- ---------------------------------------------------------------------------
create or replace function public.para_e164(p_tel text)
returns text language plpgsql immutable set search_path = public as $$
declare v_so text;
begin
  v_so := regexp_replace(coalesce(p_tel, ''), '[^0-9]', '', 'g');
  if v_so = '' then return null; end if;

  -- 10 dígitos = fixo com DDD, 11 = celular. Brasileiro digita sem o país, e
  -- exigir que ele lembre do +55 é exigir que ele erre.
  if length(v_so) in (10, 11) then v_so := '55' || v_so; end if;

  -- Fora disso, ou já veio com país ou está errado. O `check` da coluna dá a
  -- palavra final; aqui só se recusa o que nem chega perto.
  if length(v_so) < 8 or length(v_so) > 15 then return null; end if;
  if left(v_so, 1) = '0' then return null; end if;

  return '+' || v_so;
end $$;

-- ---------------------------------------------------------------------------
-- 2) O gatilho
--
-- Roda depois de a conta nascer, dentro da transação do Supabase Auth.
-- ---------------------------------------------------------------------------
create or replace function public.perfil_ao_criar_conta()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_nome text;
  v_tel  text;
begin
  -- Nome: vem do cadastro. Conta criada pelo painel do Supabase não tem
  -- metadado nenhum, e aí o começo do e-mail serve — é melhor que barrar a
  -- criação por causa de um rótulo.
  v_nome := nullif(btrim(coalesce(v_meta->>'nome', v_meta->>'full_name', '')), '');
  if v_nome is null or length(v_nome) < 2 then
    v_nome := split_part(coalesce(new.email, 'pessoa'), '@', 1);
  end if;
  if length(v_nome) < 2 then v_nome := 'Pessoa'; end if;

  v_tel := public.para_e164(coalesce(v_meta->>'telefone', v_meta->>'phone', new.phone));

  -- Telefone já usado por outra pessoa? Fica nulo, e a conta nasce mesmo
  -- assim. Perder o telefone é um aborrecimento — dá para completar depois
  -- em Meu salão. Barrar o cadastro por causa dele é perder o cliente na
  -- porta, e por um motivo que ele não entenderia.
  if v_tel is not null
     and exists (select 1 from public.perfis where telefone = v_tel) then
    v_tel := null;
  end if;

  insert into public.perfis (id, nome, telefone, email)
       values (new.id, v_nome, v_tel, new.email)
  -- `do nothing` porque este gatilho não pode ser o motivo de um cadastro
  -- falhar. Se a linha já existe, ela já existe.
  on conflict (id) do nothing;

  return new;
end $$;

drop trigger if exists tg_perfil_ao_criar_conta on auth.users;
create trigger tg_perfil_ao_criar_conta
  after insert on auth.users
  for each row execute function public.perfil_ao_criar_conta();

-- ---------------------------------------------------------------------------
-- 3) `telefone` deixa de ser obrigatório
--
-- Era `not null`, e isso partia de uma premissa que só vale num caminho: o de
-- quem se cadastra pela tela, que pede o WhatsApp. Não vale para conta criada
-- no painel do Supabase, não vale para login com Google no dia em que existir,
-- e não vale para quem apenas ainda não informou.
--
-- O índice único continua: dois perfis não podem dividir o mesmo número. No
-- Postgres, nulos não colidem entre si — então "sem telefone" pode acontecer
-- muitas vezes, e "com este telefone" só uma.
-- ---------------------------------------------------------------------------
alter table public.perfis alter column telefone drop not null;

-- ---------------------------------------------------------------------------
-- 4) As contas que já existem sem perfil
--
-- Quem se cadastrou antes deste arquivo ficou com a conta metade criada. Isto
-- conserta essas, e é seguro rodar quantas vezes quiser.
-- ---------------------------------------------------------------------------
insert into public.perfis (id, nome, telefone, email)
select u.id,
       coalesce(
         nullif(btrim(coalesce(u.raw_user_meta_data->>'nome',
                               u.raw_user_meta_data->>'full_name', '')), ''),
         split_part(coalesce(u.email, 'pessoa'), '@', 1)),
       -- Mesmo cuidado do gatilho: telefone repetido vira nulo em vez de
       -- derrubar o conserto inteiro por causa de uma linha.
       (select public.para_e164(u.raw_user_meta_data->>'telefone')
         where not exists (
           select 1 from public.perfis p2
            where p2.telefone = public.para_e164(u.raw_user_meta_data->>'telefone'))),
       u.email
  from auth.users u
 where not exists (select 1 from public.perfis p where p.id = u.id)
on conflict (id) do nothing;

grant execute on function public.para_e164(text) to anon, authenticated;
