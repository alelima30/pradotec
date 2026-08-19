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
