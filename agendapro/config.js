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
  url:   'https://ialjrnighxntuirzmppt.supabase.co',
  chave: 'sb_publishable_7E1IGSXJdA-U40VKDmlC7g_fBmSeZh1',

  // Aparece no rodapé para você não se confundir entre ensaio e produção.
  ambiente: 'produção',
};

/* ── POR QUE ISTO SAIU DE VAZIO ────────────────────────────────────────────
   Ficou vazio por um tempo de propósito: com o site em demonstração, quem
   entrasse não sujaria o banco de verdade.

   Custou três idas e vindas. A conta criada pela tela ia para o localStorage
   do navegador, o Supabase nunca via nada, e o script de promoção dizia "não
   achei conta com esse e-mail" — verdade que apontava para o lugar errado.

   Agora o sistema fala com o banco de verdade. Isso quer dizer que quem
   abrir o endereço público cria conta e salão AQUI DENTRO. Para um produto
   que ainda não lançou, é o que se quer: dá para usar de verdade, e o RLS
   segura cada um no seu canto — 14 verificações por dentro do banco e 16 por
   fora provam isso.

   Para voltar à demonstração, esvazie as duas linhas acima. Nada mais muda.
   ──────────────────────────────────────────────────────────────────────── */

/* ── A DEMONSTRAÇÃO SOB DEMANDA ────────────────────────────────────────────
   `?demo=1` em qualquer endereço do sistema desliga o banco naquela aba: os
   dados passam a morar no navegador e nada sai dali.

   Serve para duas coisas de uma vez:

   · mostrar o sistema para alguém sem criar salão de verdade no banco — é o
     "ver como funciona" que todo SaaS tem, e agora ele existe sem depender
     de manter um segundo site publicado;
   · deixar os testes de tela exercitarem o modo demonstração mesmo com o
     config apontando para produção. Sem isso, ligar o banco derrubaria a
     suíte de navegador inteira — e a resposta preguiçosa seria apagar os
     testes em vez de consertar a causa.

   Não abre nada: modo demonstração é ACESSO A MENOS, não a mais. Sem URL e
   sem chave, o dados.js nem tenta falar com o Supabase.
   ──────────────────────────────────────────────────────────────────────── */
try{
  if(new URLSearchParams(location.search).get('demo') === '1'){
    window.AGENDAPRO.url = '';
    window.AGENDAPRO.chave = '';
    window.AGENDAPRO.ambiente = 'demonstração';
  }
}catch(e){ /* file:// sem search, ou navegador antigo: segue no modo normal */ }
