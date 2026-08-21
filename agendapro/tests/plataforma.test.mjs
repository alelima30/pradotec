/* ===========================================================================
   AgendaPro — o painel da plataforma, pela porta da frente

     bash tests/bancada/subir.sh
     PLAYWRIGHT=.../node_modules/playwright node tests/plataforma.test.mjs

   Os testes SQL provam que a função recusa quem não é da plataforma. Aqui se
   prova o outro lado: que a TELA não vaza nada por conta própria, e que a
   recusa chega ao olho de quem abriu em vez de virar tela branca.

   O caso que mais importa é o do meio: uma dona de salão comum abrindo
   admin.html. A tela carrega — ela é um arquivo estático, não há como
   impedir —, e o que decide é o banco. Se algum dia alguém desenhar a
   permissão na tela em vez de no `is_super()`, este teste cai.
   =========================================================================== */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BANCADA = process.env.BANCADA || 'http://127.0.0.1:8123';
const RAIZ = path.dirname(new URL(import.meta.url).pathname);

let ok = 0, mau = 0;
const diz = (bom, msg, extra) => bom
  ? (ok++, console.log('  ✓ ' + msg))
  : (mau++, console.log('  ✗ ' + msg + (extra ? '\n      ' + extra : '')));

// A bancada serve os arquivos do projeto, então admin.html sai dela já com a
// config apontando para ela mesma — que é o cenário real, tela e banco no
// mesmo lugar.
const nav = await chromium.launch({ executablePath: CHROMIUM });

/* O `dados.js` fora do navegador, com a sessão de alguém na mão. Serve para
   perguntar o que o painel BAIXARIA, sem depender do que a tela desenha —
   o que desce para o navegador é o que importa aqui, não o que aparece. */
function novaAba(sessao){
  const g = { 'agendapro.sessao': JSON.stringify(sessao) };
  const j = { AGENDAPRO:{ url:BANCADA, chave:'chave-de-teste', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'..','dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

async function abrir(sessao){
  const ctx = await nav.newContext({ viewport:{ width:1280, height:900 } });
  await ctx.addInitScript(([base, s]) => {
    window.AGENDAPRO = { url: base, chave: 'chave-de-teste', ambiente: 'bancada' };
    if(s) localStorage.setItem('agendapro.sessao', JSON.stringify(s));
  }, [BANCADA, sessao]);
  const p = await ctx.newPage();
  p.erros = [];
  p.on('pageerror', e => p.erros.push(e.message));
  await p.goto(BANCADA + '/admin.html');
  await p.waitForTimeout(1200);
  return p;
}

// Cria uma conta pela API da bancada e devolve a sessão que o dados.js grava.
async function conta(email){
  const r = await fetch(BANCADA + '/auth/v1/signup', {
    method:'POST', headers:{ apikey:'chave-de-teste', 'Content-Type':'application/json' },
    body: JSON.stringify({ email, password:'senha-de-teste',
                           data:{ nome:'Teste', telefone:'+5511'+Math.floor(1e8+Math.random()*8e8) } }),
  });
  const j = await r.json();
  return { sessao: { token: j.access_token, usuarioId: (j.user||{}).id }, id: (j.user||{}).id };
}

console.log('\nQuem não é da plataforma');

{
  const c = await conta('dona-' + Date.now() + '@teste.com');
  const p = await abrir(c.sessao);
  const txt = await p.textContent('#corpo');
  diz(/não é da plataforma/i.test(txt),
    'a dona de salão vê a recusa explicada, não tela branca', txt.slice(0,120));
  diz(!/Receita do mês/.test(txt),
    'e nenhum número do negócio aparece na tela dela');
  diz(p.erros.length === 0, 'sem erro de JavaScript', p.erros.join(' · '));
  await p.context().close();
}

console.log('\nQuem é');

{
  const c = await conta('plataforma-' + Date.now() + '@teste.com');
  // A promoção só existe por SQL — é o mesmo caminho do promover_admin.sql.
  const { execSync } = exigir('node:child_process');
  execSync(`psql -q -h /tmp -p 5444 -U postgres -d app -c "update public.perfis set super_admin = true where id = '${c.id}'"`);

  const p = await abrir(c.sessao);
  const txt = await p.textContent('#corpo');
  diz(/Receita do mês/.test(txt), 'o painel abre para a conta promovida', txt.slice(0,120));
  diz(/Todos os salões/.test(txt), 'com a lista de salões');
  diz(await p.isVisible('.placar'), 'e os números do topo desenhados');
  diz(p.erros.length === 0, 'sem erro de JavaScript', p.erros.join(' · '));

  // O selo existe para você saber, de relance, que esta aba enxerga tudo.
  diz((await p.textContent('.selo')).includes('PLATAFORMA'),
    'a tela se identifica como a que enxerga todos os salões');
  await p.context().close();

  /* ── O PAINEL DO SALÃO NÃO BAIXA O SALÃO DOS OUTROS ────────────────────
     `is_super()` está em toda policy de leitura, então esta conta ALCANÇA,
     pelo banco, o salão de todo mundo — é de propósito, sem isso não há
     suporte nem cobrança. O que não pode é o app.html arrastar isso para
     dentro do navegador sem ninguém pedir: numa base de teste eram 27
     salões e 15 clientes de terceiros, com telefone e observação, baixados
     na abertura para uma tela que descarta tudo em seguida.

     Acesso ela tem; exposição à toa, não. O painel dela é o admin.html, que
     passa por RPC — o app.html não precisa de uma linha sequer. */
  const bd = await fetch(BANCADA + "/rest/v1/clientes?select=id", {
    headers: { apikey:'k', Authorization: 'Bearer ' + c.sessao.token } })
    .then(r => r.json());
  diz(Array.isArray(bd) && bd.length > 0,
    'pelo banco, a conta da plataforma alcança cliente de outro salão (de propósito)',
    'vieram ' + (Array.isArray(bd) ? bd.length : '?'));

  const janela = novaAba(c.sessao);
  const trazido = await janela.baixar();
  diz(trazido.contaDaPlataforma === true,
    'mas o baixar() do painel para na conta de plataforma, sem puxar nada');
  diz((trazido.clientes || []).length === 0,
    'nenhum cliente de terceiro desce para o navegador dela',
    'vieram ' + (trazido.clientes || []).length);
  diz((trazido.saloes || []).length === 0,
    'nem a lista de salões dos outros', 'vieram ' + (trazido.saloes || []).length);
}

console.log('\nSem banco configurado');

{
  // Deste caso a bancada NÃO serve: ela entrega um config.js próprio,
  // apontando para ela mesma, que sobrescreve qualquer coisa injetada antes.
  // O modo demonstração é justamente o config.js vazio do repositório, então
  // ele só existe no servidor estático comum.
  //
  //     python3 -m http.server 8099 --directory .
  const ESTATICO = process.env.BASE || 'http://127.0.0.1:8099';
  const ctx = await nav.newContext({ viewport:{ width:1280, height:900 } });
  const p = await ctx.newPage();
  const erros = []; p.on('pageerror', e => erros.push(e.message));
  // `?demo=1` desliga o banco nesta aba. Antes bastava o config.js estar
  // vazio; agora que ele aponta para produção, é assim que se chega ao modo
  // demonstração — e é o mesmo caminho que uma pessoa usaria.
  await p.goto(ESTATICO + '/admin.html?demo=1');
  await p.waitForTimeout(600);
  const txt = await p.textContent('#corpo');
  diz(/banco de verdade/i.test(txt),
    'em demonstração, explica que o painel não mede nada', txt.slice(0,120));
  diz(erros.length === 0, 'sem erro de JavaScript', erros.join(' · '));
  await ctx.close();
}

await nav.close();
console.log('');
if(mau){ console.log(`✗ ${mau} de ${ok+mau} falharam.`); process.exit(1); }
console.log(`✓ ${ok} verificações do painel da plataforma.`);
