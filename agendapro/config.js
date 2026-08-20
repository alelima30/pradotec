/* ===========================================================================
   AgendaPro — configuração
   ---------------------------------------------------------------------------
   ESTE É O ÚNICO ARQUIVO QUE VOCÊ PRECISA EDITAR PARA LIGAR NO SUPABASE.

   Deixe os dois campos vazios e o sistema roda em MODO DEMONSTRAÇÃO, com os
   dados no próprio navegador. Preencha e ele passa a falar com o banco de
   verdade — sem mudar mais nada em lugar nenhum.

   Onde achar os valores:
     Supabase → seu projeto → Settings → API Keys
       url   = Project URL             (https://xxxxxxxx.supabase.co)
       chave = Publishable key         (sb_publishable_...)

   Projeto antigo mostra "anon / public" no lugar de Publishable, e um JWT
   comprido (`eyJhbGciOi...`) no lugar do `sb_publishable_`. As duas servem: o
   dados.js manda a chave só no cabeçalho `apikey`, que é o único lugar onde
   os dois formatos funcionam.

   Esta chave PODE ficar aqui, à vista. Ela não é segredo: é ela que o
   navegador usa para dizer qual projeto é, e quem protege os dados é o RLS
   dentro do banco, não o sigilo da chave. É o mesmo modelo do AdminPro.

   A OUTRA chave — "Secret key" (`sb_secret_...`), ou `service_role` no
   projeto antigo — NUNCA entra em arquivo que vai para o navegador. Ela passa
   por cima de todo o RLS: com ela no código-fonte da página, qualquer pessoa
   lê a agenda e a clientela de todos os salões.
   =========================================================================== */

window.AGENDAPRO = {
  url:   '',   // https://xxxxxxxx.supabase.co
  chave: '',   // sb_publishable_...

  // Aparece no rodapé para você não se confundir entre ensaio e produção.
  ambiente: 'demonstração',
};
