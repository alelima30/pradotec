/* ===========================================================================
   AgendaPro — configuração
   ---------------------------------------------------------------------------
   ESTE É O ÚNICO ARQUIVO QUE VOCÊ PRECISA EDITAR PARA LIGAR NO SUPABASE.

   Deixe os dois campos vazios e o sistema roda em MODO DEMONSTRAÇÃO, com os
   dados no próprio navegador. Preencha e ele passa a falar com o banco de
   verdade — sem mudar mais nada em lugar nenhum.

   Onde achar os valores:
     Supabase → seu projeto → Settings → API
       url   = Project URL          (https://xxxxxxxx.supabase.co)
       chave = Project API keys → anon / public

   A chave anônima PODE ficar aqui, à vista. Ela não é segredo: é ela que o
   navegador usa para se apresentar, e quem protege os dados é o RLS dentro
   do banco, não o sigilo da chave. É o mesmo modelo do AdminPro.

   A chave `service_role` é outra história — essa NUNCA entra em arquivo que
   vai para o navegador. Ela passa por cima de todo o RLS.
   =========================================================================== */

window.AGENDAPRO = {
  url:   '',   // https://xxxxxxxx.supabase.co
  chave: '',   // eyJhbGciOi...

  // Aparece no rodapé para você não se confundir entre ensaio e produção.
  ambiente: 'demonstração',
};
