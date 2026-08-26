/* ===========================================================================
   AgendaPro — "Meu salão" em duas abas, com a prévia sempre à vista

     PLAYWRIGHT=/caminho/node_modules/playwright node tests/abas-salao.test.mjs

   ── O QUE MUDOU, E POR QUÊ ─────────────────────────────────────────────────
   "Meu salão" era uma página só, com três cartões empilhados: dados,
   aparência e identidade visual.

   A prévia do celular gruda ao lado da APARÊNCIA. Mas a identidade visual —
   logo, foto do salão, galeria, fundo — ficava DEPOIS dela, num cartão de
   largura inteira. Ou seja: trocar a capa, que é a maior mudança visual que
   existe na página da cliente, era feito com a prévia fora da tela.

   Agora as duas coisas que mudam a cara da página moram na mesma aba, na
   mesma coluna que rola, contra a mesma prévia grudada.

   ── O QUE ESTA SUÍTE GUARDA ────────────────────────────────────────────────
   Não a existência das abas: a PROMESSA delas. Ela rola a coluna até as
   imagens e exige que a prévia continue na tela. E exige que a aba escolhida
   sobreviva a uma repintura, porque `pintarSalao()` refaz o innerHTML inteiro
   a cada foto trocada — sem lembrar, escolher uma capa jogaria o dono de
   volta para a aba de dados no meio do trabalho.
   =========================================================================== */
import { createRequire } from 'node:module';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BASE = process.env.BASE || 'http://127.0.0.1:8099/';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => a === b ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1400, height:900 } });
const pg = await ctx.newPage();
const erros = [];
pg.on('pageerror', e => erros.push(e.message));
await pg.goto(BASE + 'app.html?demo=1');
await pg.waitForTimeout(2600);
await pg.evaluate(() => { document.documentElement.setAttribute('data-tema','claro');
                          irPara('salao'); });
await pg.waitForTimeout(700);

const visivel = sel => pg.evaluate(s => {
  const el = document.querySelector(s);
  if(!el) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}, sel);

const secaoChamada = titulo => pg.evaluate(t =>
  [...document.querySelectorAll('#painelSalao .secao')]
    .find(h => h.textContent.includes(t)) ? true : false, titulo);

/* ══════════════════════════════════════════════════════════════════════════
   1. AS DUAS ABAS
   ══════════════════════════════════════════════════════════════════════════ */
secao('Meu salão abre em Dados');

igual('a aba inicial é a de dados',
  await pg.evaluate(() => subAbaSalao), 'dados');
igual('há duas abas',
  await pg.evaluate(() => document.querySelectorAll('#subAbasSalao button').length), 2);
verdade('os dados do estabelecimento estão à vista',
  await visivel('#cNome'));
verdade('e a prévia do celular NÃO ocupa espaço nesta aba',
  !(await visivel('.ap-previa')),
  'a aba de dados não tem o que prever');

/* ══════════════════════════════════════════════════════════════════════════
   2. APARÊNCIA E IDENTIDADE NA MESMA ABA
   ══════════════════════════════════════════════════════════════════════════ */
secao('A aba de aparência junta as duas coisas que mudam a cara da página');

await pg.evaluate(() => trocarAbaSalao('aparencia'));
await pg.waitForTimeout(600);

verdade('a prévia do celular aparece', await visivel('.ap-previa'));
verdade('as escolhas de aparência estão lá', await secaoChamada('Aparência do link'));
verdade('e a identidade visual TAMBÉM', await secaoChamada('Identidade visual'));
verdade('os dados do estabelecimento saíram da vista', !(await visivel('#cNome')),
  'as duas abas mostrando tudo ao mesmo tempo não separam nada');

verdade('a identidade visual está DENTRO da coluna que rola',
  await pg.evaluate(() => {
    const h = [...document.querySelectorAll('#painelSalao .secao')]
      .find(x => x.textContent.includes('Identidade visual'));
    return !!h && document.querySelector('.ap-controles').contains(h);
  }),
  'fora dela, ela não rola contra a prévia — que é o ponto da mudança');

/* ══════════════════════════════════════════════════════════════════════════
   3. A PROMESSA: ROLAR ATÉ AS IMAGENS SEM PERDER A PRÉVIA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Rolando até a foto do salão, a prévia continua na tela');

const aoRolar = await pg.evaluate(async () => {
  const alvo = [...document.querySelectorAll('#painelSalao .foto-txt b')]
    .find(b => b.textContent.includes('Foto do salão'));
  alvo.scrollIntoView({ block:'center' });
  await new Promise(r => setTimeout(r, 500));
  const p = document.querySelector('.ap-previa').getBoundingClientRect();
  const a = alvo.getBoundingClientRect();
  return {
    alvoNaTela: a.top >= 0 && a.bottom <= innerHeight,
    previaNaTela: p.top < innerHeight && p.bottom > 0,
    previaAltura: Math.round(p.height),
  };
});

verdade('o campo da foto do salão está na tela', aoRolar.alvoNaTela,
  JSON.stringify(aoRolar));
verdade('e a prévia continua visível ao lado', aoRolar.previaNaTela,
  'trocar a capa com a prévia fora da tela é mexer às cegas: '
  + JSON.stringify(aoRolar));
verdade('com altura de verdade, não uma tira', aoRolar.previaAltura > 200,
  JSON.stringify(aoRolar));

/* ══════════════════════════════════════════════════════════════════════════
   4. A ABA SOBREVIVE À REPINTURA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Trocar uma imagem não joga o dono de volta para Dados');

// `pintarSalao()` refaz o innerHTML inteiro — é o que roda depois de cada
// foto escolhida ou removida.
await pg.evaluate(() => pintarSalao());
await pg.waitForTimeout(500);

igual('a aba continua em aparência',
  await pg.evaluate(() => subAbaSalao), 'aparencia');
verdade('e a identidade visual continua à vista',
  await secaoChamada('Identidade visual'));
verdade('a pastilha da aba certa está marcada',
  await pg.evaluate(() => {
    const b = document.querySelector('#subAbasSalao button[data-sub="aparencia"]');
    return b.classList.contains('on') && b.getAttribute('aria-current') === 'true';
  }),
  'sem a marca, o dono não sabe em qual aba está');

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
