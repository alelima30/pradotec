-- ===========================================================================
-- AgendaPro — a conta vira perfil (08_conta.sql)
--
-- O cadastro cria a conta em `auth.users` e logo depois chama criar_salao(),
-- que exige um perfil. Nada criava esse perfil: quem se cadastrasse no
-- Supabase de verdade levava "Complete seu cadastro antes de criar o salão"
-- com a conta metade criada e o e-mail preso.
--
-- A suíte inteira estava verde porque a bancada de teste inseria em `perfis`
-- no próprio signup, imitando um gatilho que não existia. O que se prova aqui
-- é o gatilho de verdade, no banco de verdade.
-- ===========================================================================

\set ON_ERROR_STOP on
\o /dev/null

\echo ''
\echo 'A conta nasce com perfil'

do $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data)
       values (v_id, 'dona@salao.com',
               '{"nome":"Ana Souza","telefone":"(51) 99887-6655"}'::jsonb);

  perform t_verdade('o perfil aparece sozinho, sem ninguém inserir',
    exists (select 1 from public.perfis where id = v_id));

  perform t_texto('com o nome que a tela mandou',
    (select nome from public.perfis where id = v_id), 'Ana Souza');

  -- (51) 99887-6655, 51998876655 e +55 51 99887-6655 são a mesma pessoa. Se
  -- virassem linhas diferentes, o reencontro pelo telefone — que é como a
  -- recepção acha a ficha antiga de alguém — simplesmente não aconteceria.
  perform t_texto('e o telefone já em E.164, com o +55 que ninguém digita',
    (select telefone from public.perfis where id = v_id), '+5551998876655');

  perform t_texto('o e-mail vem junto',
    (select email from public.perfis where id = v_id), 'dona@salao.com');
end $$;

\echo ''
\echo 'E nasce mesmo quando falta alguma coisa'

do $$
declare v_id uuid := gen_random_uuid();
begin
  -- Conta criada pelo painel do Supabase: nenhum metadado.
  insert into auth.users (id, email) values (v_id, 'sozinho@exemplo.com');

  perform t_verdade('conta sem metadado nenhum também ganha perfil',
    exists (select 1 from public.perfis where id = v_id));
  perform t_texto('e o nome sai do começo do e-mail',
    (select nome from public.perfis where id = v_id), 'sozinho');
  perform t_verdade('com o telefone em branco, que agora é permitido',
    (select telefone from public.perfis where id = v_id) is null);
end $$;

do $$
declare v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data)
       values (v_a, 'primeiro@x.com', '{"nome":"Primeiro","telefone":"11988887777"}'::jsonb);
  -- O MESMO telefone, outra pessoa. Barrar o cadastro aqui seria perder o
  -- cliente na porta por um motivo que ele não entenderia.
  insert into auth.users (id, email, raw_user_meta_data)
       values (v_b, 'segundo@x.com', '{"nome":"Segundo","telefone":"11988887777"}'::jsonb);

  perform t_verdade('telefone repetido não derruba o cadastro do segundo',
    exists (select 1 from public.perfis where id = v_b));
  perform t_verdade('o segundo fica sem telefone, e completa depois',
    (select telefone from public.perfis where id = v_b) is null);
  perform t_texto('e o primeiro continua com o número',
    (select telefone from public.perfis where id = v_a), '+5511988887777');
end $$;

\echo ''
\echo 'A conversão do telefone'

do $$ begin
  perform t_texto('celular com DDD ganha o +55',
                  public.para_e164('51998876655'), '+5551998876655');
  perform t_texto('com máscara, idem',
                  public.para_e164('(51) 99887-6655'), '+5551998876655');
  perform t_texto('fixo de 10 dígitos também',
                  public.para_e164('5133334444'), '+555133334444');
  perform t_texto('quem já mandou com país fica como está',
                  public.para_e164('+55 51 99887-6655'), '+5551998876655');
  perform t_verdade('curto demais vira nulo em vez de lixo',
                    public.para_e164('99887') is null);
  perform t_verdade('vazio vira nulo', public.para_e164('') is null);
  perform t_verdade('nulo continua nulo', public.para_e164(null) is null);
end $$;

\echo ''
\echo 'O caminho inteiro do cadastro'

do $$
declare v_id uuid := gen_random_uuid(); v_slug text;
begin
  -- É esta sequência que quebrava: criar conta, e em seguida criar o salão.
  insert into auth.users (id, email, raw_user_meta_data)
       values (v_id, 'novo@salao.com',
               '{"nome":"Novo Dono","telefone":"11955554444"}'::jsonb);

  perform set_config('request.jwt.claim.sub', v_id::text, true);
  set local role authenticated;

  -- criar_salao() devolve uma TABELA (salao_id, slug), não um escalar.
  select c.slug into v_slug
    from public.criar_salao(p_nome_salao := 'Salão Novo', p_tipo := 'salao') c;

  perform t_verdade('criar_salao() não reclama mais de cadastro incompleto',
                    v_slug is not null);
  perform t_texto('e o apelido do link sai do nome do salão',
                  v_slug, 'salao-novo');
end $$;

select t_ok('conta: tudo conferido');
