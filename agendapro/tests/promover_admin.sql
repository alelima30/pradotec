-- ===========================================================================
-- AgendaPro — promover alguém a dono da plataforma
--
--   Supabase → seu projeto → SQL Editor → cole isto → troque o e-mail → Run
--
-- ---------------------------------------------------------------------------
-- POR QUE ISTO SÓ EXISTE AQUI, E NÃO NUMA TELA
--
-- Uma conta `super_admin` lê a clientela, a agenda e o faturamento de TODOS
-- os salões da plataforma. É a única credencial do sistema cuja perda não tem
-- conserto parcial.
--
-- Se houvesse um caminho pela aplicação — um botão, uma rota, uma chamada de
-- API — esse caminho seria o alvo, e um dia alguém acharia a ponta solta. Não
-- havendo caminho nenhum, a única porta é o painel do Supabase, que já exige
-- a senha do projeto.
--
-- Isso não é teoria: o teste em tests/02_rls.test.sql tenta o caminho óbvio,
-- e ele fecha —
--
--     ✓ não consegue se tornar dona da plataforma
--     ✓ não consegue se dar o papel de dona do salão
--
-- ---------------------------------------------------------------------------
-- ANTES DE RODAR, DUAS DECISÕES
--
-- 1. USE UMA CONTA SEPARADA da que você usa como dono de salão.
--    Não é burocracia: é o tamanho do estrago quando algo dá errado. Sessão
--    esquecida aberta, tela emprestada para alguém ver, celular perdido — o
--    prejuízo é do tamanho da conta que estava logada. Com contas separadas,
--    o dia a dia acontece na conta pequena.
--
-- 2. LIGUE A VERIFICAÇÃO EM DOIS PASSOS nessa conta.
--    Supabase → Authentication → Providers → MFA. Senha sozinha protege
--    contra quem tenta; segundo fator protege contra quem já conseguiu a
--    senha, que é o caso que importa.
-- ===========================================================================

-- ── PASSO 1 ────────────────────────────────────────────────────────────────
-- Crie a conta normalmente pela tela de cadastro do sistema, com o e-mail que
-- vai ser o seu de administrador. Ela nasce como qualquer outra: sem poder
-- nenhum além do próprio salão.

-- ── PASSO 2 ────────────────────────────────────────────────────────────────
-- Troque o e-mail abaixo pelo seu e rode. O `where` casa pelo e-mail em
-- auth.users, então não há chance de promover a pessoa errada por engano de
-- uuid copiado pela metade.

do $$
declare
  v_email text := 'TROQUE-PELO-SEU@EMAIL.COM';   -- ← só isto muda
  v_id    uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);

  if v_id is null then
    raise exception E'Não achei conta com o e-mail %.\n'
      '  Crie a conta primeiro pela tela de cadastro do sistema,\n'
      '  depois rode isto de novo.', v_email;
  end if;

  -- O perfil nasce junto com a conta. Se por algum motivo não existir, criar
  -- aqui é melhor que falhar — o objetivo é ter um administrador, não ser
  -- exigente com a ordem dos acontecimentos.
  --
  -- `telefone` é obrigatório e único em `perfis`, e no caminho normal ele vem
  -- do cadastro. Aqui, no caminho de exceção, entra um marcador reconhecível
  -- em vez de um número inventado que um dia colidiria com o de uma cliente
  -- de verdade.
  insert into public.perfis (id, nome, telefone, super_admin)
       values (v_id, split_part(v_email, '@', 1),
               '+' || (900000000000 + (abs(hashtext(v_id::text)) % 999999))::text,
               true)
  on conflict (id) do update set super_admin = true;

  raise notice '✓ % agora é dono da plataforma (id %)', v_email, v_id;
end $$;

-- ── PASSO 3 ────────────────────────────────────────────────────────────────
-- Confira. Esta lista tem que ter exatamente as pessoas que você quer, e
-- nenhuma a mais — inclusive daqui a um ano, quando você não lembrar mais
-- quem promoveu.

select p.id,
       u.email,
       p.nome,
       p.criado_em as perfil_criado_em
  from public.perfis p
  join auth.users u on u.id = p.id
 where p.super_admin
 order by p.criado_em;

-- ---------------------------------------------------------------------------
-- PARA TIRAR O PODER DE ALGUÉM
--
--   update public.perfis set super_admin = false
--    where id = (select id from auth.users where lower(email) = lower('fulano@x.com'));
--
-- Tirar o super_admin NÃO apaga a conta nem os salões da pessoa: ela volta a
-- ser um dono de salão comum. É de propósito — a saída tem que ser tão barata
-- quanto a entrada, senão ninguém revoga acesso quando deveria.
-- ---------------------------------------------------------------------------
