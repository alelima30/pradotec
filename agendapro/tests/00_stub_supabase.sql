-- Só para TESTE LOCAL / CI. Nunca rode isto no Supabase.
--
-- O Supabase já traz o schema `auth` com a tabela `users` e a função
-- `auth.uid()`. Num Postgres cru eles não existem, então recriamos o mínimo
-- para o schema real carregar sem alteração nenhuma.
--
-- auth.uid() aqui lê uma variável de sessão, o que deixa o teste "logar" como
-- qualquer usuário:  set local request.jwt.claim.sub = '<uuid>';

create schema if not exists auth;

-- `raw_user_meta_data` e `phone` existem no Supabase de verdade e o gatilho
-- do 08_conta.sql lê os dois: é de lá que saem o nome e o telefone que a tela
-- de cadastro mandou. Sem eles aqui, o gatilho seria testado sem os dados que
-- ele existe para ler — e passaria dizendo nada.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  phone              text,
  raw_user_meta_data jsonb
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


-- ---------------------------------------------------------------------------
-- storage — o mínimo para o 04_imagens.sql instalar num Postgres cru
--
-- No Supabase estas tabelas já existem, criadas pela extensão de Storage. Aqui
-- recriamos só a forma, para as policies do balde poderem ser testadas sem
-- subir um Supabase inteiro. Não guardam arquivo nenhum: guardam o CAMINHO,
-- que é sobre o que as policies decidem.
-- ---------------------------------------------------------------------------
create schema if not exists storage;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);

create table if not exists storage.objects (
  id        uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name      text not null,
  owner     uuid,
  unique (bucket_id, name)
);

alter table storage.objects enable row level security;

-- Quebra o caminho em pastas, do jeito que o Supabase faz:
--   'abc/logo.jpg'  ->  {abc}
-- A última parte é o arquivo e fica de fora.
create or replace function storage.foldername(name text)
returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1 : array_length(string_to_array(name, '/'), 1) - 1]
$$;

grant usage on schema storage to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
grant select, insert, update, delete on storage.objects to anon, authenticated;
