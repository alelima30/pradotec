-- Só para TESTE LOCAL / CI. Nunca rode isto no Supabase.
--
-- O Supabase já traz o schema `auth` com a tabela `users` e a função
-- `auth.uid()`. Num Postgres cru eles não existem, então recriamos o mínimo
-- para o schema real carregar sem alteração nenhuma.
--
-- auth.uid() aqui lê uma variável de sessão, o que deixa o teste "logar" como
-- qualquer usuário:  set local request.jwt.claim.sub = '<uuid>';

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- No Supabase estes papéis já existem; o RLS os cita nas policies.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;
