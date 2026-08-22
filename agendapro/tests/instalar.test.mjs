/* ===========================================================================
   AgendaPro — instalar no celular

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/instalar.test.mjs

   ── DOIS BURACOS, E OS DOIS SÓ APARECIAM NO CELULAR ───────────────────────
   1. O botão "Instalar aplicativo" nascia escondido e só aparecia quando o
      navegador disparava `beforeinstallprompt`. Esse evento é do Chrome. O
      Safari não tem, nunca teve, e a Apple já disse que não vai ter: no
      iPhone instalar é Compartilhar → Adicionar à Tela de Início.

      Ou seja: no aparelho de boa parte dos donos de salão, o único caminho
      para instalar era um botão que nunca aparecia — e a tela de instruções
      que já existia no código não tinha como ser aberta por ninguém.

   2. A página da CLIENTE apontava para o manifesto do sistema, cujo
      `start_url` é `app.html` — o painel do dono. Quem instalasse "a
      Barbearia do Zé" ganhava um ícone que abria "AgendaPro: entre com seu
      e-mail". O ícone com o nome de um negócio abrindo o login de outro.

   Nenhum dos dois quebra teste de tela: a página carrega, não dá erro de
   JavaScript, e tudo parece certo. Só falha na mão de quem tenta instalar.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => a === b ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);

function novaAba(){
  const g = {};
  const j = { AGENDAPRO:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`inst-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Zé Barbeiro', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const criado = await d.chamar('criar_salao', { p_nome_salao:'Barbearia do Zé',
  p_tipo:'barbearia', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const salaoId = criado[0].salao_id, SLUG = criado[0].slug;
const prof = (await d.lista('profissionais', { salaoId }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: prof.id, diaSemana:i,
                                inicio:'09:00', fim:'19:00' });
await d.inserir('servicos', { salaoId, nome:'Corte', duracaoMin:30, preco:45,
                              ativo:true, aceitaOnline:true });

const nav = await chromium.launch({ executablePath: CHROMIUM });

/* ══════════════════════════════════════════════════════════════════════════
   O PAINEL DO DONO

   O Chromium do teste também não dispara `beforeinstallprompt` (ele exige
   engajamento e uma origem instalável de verdade), o que é ótimo: é
   exatamente a condição do iPhone. Se o botão aparecer aqui, aparece lá.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O botão de instalar, sem o evento do Chrome');

const ctx = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
const pg = await ctx.newPage();
const erros = [];
pg.on('pageerror', e => erros.push(e.message));
await pg.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);

verdade('aparece mesmo sem o navegador oferecer instalação',
  await pg.evaluate(() => {
    const b = document.getElementById('btInstalar');
    return !!b && getComputedStyle(b).display !== 'none';
  }), 'era o furo: no iPhone o botão nunca chegava a existir na tela');

/* E tem que ENSINAR, não só existir. O caminho do iPhone é o único que a
   pessoa não descobre sozinha — está escondido atrás do botão Compartilhar. */
await pg.evaluate(() => {
  Object.defineProperty(navigator, 'userAgent', { configurable:true,
    get: () => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
             + 'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1' });
  instalarApp();
});
await pg.waitForTimeout(700);
const naJanela = await pg.evaluate(() => {
  const c = document.getElementById('modalCorpo');
  return c ? c.textContent.replace(/\s+/g, ' ') : '';
});
verdade('e ensina o caminho do iPhone, que ninguém acha sozinho',
  /Compartilhar/.test(naJanela) && /Tela de Início/i.test(naJanela),
  JSON.stringify(naJanela.slice(0, 120)));
verdade('avisando que pelo Chrome do iPhone não dá',
  /Safari/.test(naJanela), 'a pessoa tenta pelo Chrome e conclui que não funciona');
verdade('sem despejar as instruções dos outros aparelhos junto',
  !/menu ⋮/i.test(naJanela),
  'três receitas na mesma tela fazem a pessoa procurar a dela');

igual('sem erro de JavaScript no painel', erros.length ? erros.join(' | ') : 0, 0);
await pg.close();

/* ══════════════════════════════════════════════════════════════════════════
   A PÁGINA DA CLIENTE

   O manifesto tem que ser DESTE salão. É o que decide o que abre quando a
   cliente toca no ícone — e era o painel do dono.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O salão instalado é o salão, não o painel do dono');

const cli = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
const cp = await cli.newPage();
const errosC = [];
cp.on('pageerror', e => errosC.push(e.message));
await cp.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
await cp.goto(BASE + '/agendar.html?salao=' + SLUG);
await cp.waitForTimeout(3000);

const man = await cp.evaluate(async () => {
  const l = document.querySelector('link[rel="manifest"]');
  if(!l) return null;
  const j = await (await fetch(l.getAttribute('href'))).json();
  return { nome: j.name, curto: j.short_name, inicio: j.start_url,
           tema: j.theme_color, icones: (j.icons || []).length,
           apple: (document.querySelector('meta[name="apple-mobile-web-app-title"]') || {}).content };
});
verdade('a página monta um manifesto próprio', !!man, 'continuou no do sistema');
igual('com o nome do salão', man && man.nome, 'Barbearia do Zé');
verdade('e abrindo NO SALÃO, não no painel do dono',
  man && man.inicio.includes('salao=' + SLUG) && !man.inicio.includes('app.html'),
  JSON.stringify(man && man.inicio));
verdade('com a cor do salão na barra do navegador',
  man && /^#[0-9A-Fa-f]{6}$/.test(man.tema || ''), JSON.stringify(man && man.tema));
verdade('e com ícone, senão o Android recusa instalar', man && man.icones >= 1);

/* O nome embaixo do ícone: a tela de início corta por volta de 12 caracteres.
   "Barbearia do" é pior que "Barbearia" — termina numa palavra que não diz
   nada e parece defeito. */
igual('o nome curto não termina em "do"', man && man.apple, 'Barbearia');
verdade('e é o mesmo no manifesto e na meta do iPhone',
  man && man.curto === man.apple, JSON.stringify(man && [man.curto, man.apple]));

igual('sem erro de JavaScript na página da cliente',
  errosC.length ? errosC.join(' | ') : 0, 0);

/* ── O CONVITE, DEPOIS DE MARCAR ──────────────────────────────────────────
   Na capa a pessoa ainda não sabe se vai usar. Depois de marcar, sabe que
   volta — e é aí que o ícone na tela dela vale alguma coisa. */
secao('O convite aparece depois de marcar, não antes');

igual('na capa, nada de convite',
  await cp.evaluate(() => {
    const c = document.getElementById('convitePwa');
    return !c || getComputedStyle(c).display === 'none';
  }), true);

igual('e ele existe para ser mostrado na hora certa',
  await cp.evaluate(() => typeof convidarAInstalar === 'function'
                       && typeof instalarSalao === 'function'), true);

const convite = await cp.evaluate(() => {
  convidarAInstalar();
  const c = document.getElementById('convitePwa');
  return { visivel: getComputedStyle(c).display !== 'none',
           diz: c.textContent.replace(/\s+/g,' ').trim() };
});
verdade('chamado, ele aparece com o nome do salão',
  convite.visivel && /Barbearia do Zé/.test(convite.diz),
  JSON.stringify(convite.diz.slice(0, 90)));

// E "agora não" tem que valer: convite que volta a cada horário marcado vira
// propaganda dentro do app do salão.
const depois = await cp.evaluate(() => {
  dispensarConvite();
  convidarAInstalar();
  const c = document.getElementById('convitePwa');
  return getComputedStyle(c).display === 'none';
});
verdade('e quem diz "agora não" não vê de novo', depois);

await cp.close();
await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de instalação.`);
