/* ===========================================================================
   AgendaPro — service worker
   É o que torna o site instalável e o que faz a agenda abrir sem internet.

   Estratégia: "rede primeiro, cache como rede de segurança".
   O contrário (cache primeiro) é mais rápido, mas foi a causa de um problema
   clássico no AdminPro: a pessoa atualiza a página, o service worker devolve
   a versão velha do cache e ela jura que o sistema não recebeu a correção.
   Numa agenda isso é pior ainda — mostrar horário desatualizado faz o salão
   marcar em cima.

   Então: tenta a rede; se der certo, guarda a cópia e entrega a versão nova.
   Só quando a rede falha é que o cache aparece.
   =========================================================================== */

const VERSAO = 'agendapro-v1';

const ESSENCIAIS = [
  './',
  './app.html',
  './index.html',
  './manifest.webmanifest',
  './icones/icone-192.png',
  './icones/icone-512.png',
];

self.addEventListener('install', ev => {
  // skipWaiting: a versão nova assume na hora, sem esperar todas as abas
  // fecharem. Sem isso, uma correção pode levar dias para chegar em quem
  // deixa o app aberto o dia inteiro — que é justamente a recepção.
  self.skipWaiting();
  ev.waitUntil(
    caches.open(VERSAO)
      .then(c => c.addAll(ESSENCIAIS))
      .catch(e => console.error('[sw] não consegui montar o cache inicial:', e))
  );
});

self.addEventListener('activate', ev => {
  ev.waitUntil((async () => {
    // Limpa versões antigas — senão o armazenamento só cresce.
    const nomes = await caches.keys();
    await Promise.all(nomes.filter(n => n !== VERSAO).map(n => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', ev => {
  const req = ev.request;

  // Só cuidamos de GET do mesmo endereço. Chamada de API (Supabase, quando
  // entrar) passa direto: resposta de banco em cache é receita de dado velho.
  if(req.method !== 'GET') return;
  if(new URL(req.url).origin !== self.location.origin) return;

  ev.respondWith((async () => {
    try{
      const resposta = await fetch(req);
      if(resposta && resposta.ok){
        const copia = resposta.clone();
        caches.open(VERSAO).then(c => c.put(req, copia)).catch(() => {});
      }
      return resposta;
    }catch(e){
      const guardado = await caches.match(req);
      if(guardado) return guardado;
      // Navegação sem rede e sem cópia: devolve a casca do app.
      if(req.mode === 'navigate'){
        const casca = await caches.match('./app.html');
        if(casca) return casca;
      }
      throw e;
    }
  })());
});
