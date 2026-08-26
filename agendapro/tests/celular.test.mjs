/* ===========================================================================
   Celular: o que quebra numa tela de 390px

   Três defeitos que só aparecem no telefone e que ninguém vê testando no
   monitor. Estão aqui porque os três já aconteceram neste projeto:

   1. ROLAGEM LATERAL. Uma tabela de 610px empurrava a página inteira, e o
      cabeçalho ia junto. A causa era `min-width:auto` implícito em item flex.
   2. ALVO DE TOQUE pequeno demais. O dedo tem uns 9mm; botão de 30px erra.
   3. TEXTO MIÚDO. 10px é legível na mesa e não é no braço esticado.

   Precisa do servidor de pé:
       python3 -m http.server 8099 --directory .
       PLAYWRIGHT=.../node_modules/playwright node tests/celular.test.mjs
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BASE = process.env.BASE || 'http://127.0.0.1:8099/';

let ok = 0, falhas = 0;
const diz = (bom, msg, extra) => {
  if(bom){ ok++; console.log('  ✓ ' + msg); }
  else { falhas++; console.log('  ✗ ' + msg + (extra ? '\n      ' + extra : '')); }
};

const nav = await chromium.launch({ executablePath: CHROMIUM });
// iPhone SE é o piso realista: quem tem telefone pequeno é quem mais precisa.
const ctx = await nav.newContext({ viewport:{width:375,height:667},
                                   isMobile:true, hasTouch:true });
const p = await ctx.newPage();
const erros = [];
p.on('pageerror', e => erros.push(e.message));
p.on('console', m => { if(m.type()==='error') erros.push(m.text()); });

const medir = () => p.evaluate(() => ({
  vaza: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  alvos: [...document.querySelectorAll('button,select,a[href],input:not([type=hidden])')]
    .filter(e => { const r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && (r.height < 40 || r.width < 40); })
    .map(e => e.tagName.toLowerCase() + '.' + (e.className||'').toString().split(' ')[0]),
  miudo: [...document.querySelectorAll('body *')]
    .filter(e => e.children.length === 0 && e.textContent.trim()
              && e.offsetParent !== null
              && parseFloat(getComputedStyle(e).fontSize) < 11)
    .map(e => e.tagName.toLowerCase() + ' @' + getComputedStyle(e).fontSize),
}));

/* ── NADA PODE COBRIR O BOTÃO DO MENU ─────────────────────────────────────
   No celular a lateral é gaveta, e a gaveta abre por um botão só. Coberto,
   não há segunda porta: a pessoa fica presa na aba em que estiver.

   Aconteceu de verdade, e por um caminho que ninguém procuraria: o cartão de
   foto montava a classe com o NOME DO CAMPO (`class="foto-previa fundo"`), e
   já existia um `.fundo` global nesta página — o véu do modal,
   `position:fixed; inset:0`. A prévia do campo novo virou uma camada fixa
   cobrindo o canto de cima da tela.

   A suíte pegou, mas só porque o clique seguinte falhou por timeout — trinta
   segundos para dizer "algo está por cima". Esta pergunta responde na hora, e
   diz o nome de quem está ali. */
console.log('\nO app do salão, em 375px');
await p.goto(BASE + 'app.html?demo=1');
await p.waitForTimeout(900);

const abas = ['Agenda','Caixa','Relatórios','Clientes','Serviços','Equipe',
              'Meu salão','Plano'];
for(const aba of abas){
  if(aba !== 'Agenda'){
    await p.locator('.menu-botao').click();
    await p.waitForTimeout(300);
    await p.locator('.aba', { hasText: aba }).click();
    await p.waitForTimeout(450);
  }
  // Antes de medir a aba: o botão que leva à PRÓXIMA continua alcançável?
  const cobrindo = await p.evaluate(() => {
    const b = document.querySelector('.menu-botao');
    if(!b) return null;
    const c = b.getBoundingClientRect();
    const emCima = document.elementFromPoint(c.x + c.width/2, c.y + c.height/2);
    return (emCima && (emCima === b || b.contains(emCima))) ? null
         : (emCima ? (emCima.tagName + '.' + String(emCima.className)) : 'nada');
  });
  diz(cobrindo === null,
    `${aba}: o botão do menu não está coberto por nada`, 'quem está ali: ' + cobrindo);

  const r = await medir();
  diz(r.vaza === 0, `${aba}: a página não rola para o lado`,
      `sobram ${r.vaza}px — quase sempre é min-width:auto em item flex`);
  diz(r.alvos.length === 0, `${aba}: nenhum alvo de toque abaixo de 40px`,
      r.alvos.join(', '));
  diz(r.miudo.length === 0, `${aba}: nenhum texto abaixo de 11px`,
      [...new Set(r.miudo)].join(', '));
}

console.log('\nA tabela vira cartão, e o cartão traz os rótulos');
await p.locator('.menu-botao').click(); await p.waitForTimeout(300);
await p.locator('.aba', { hasText: 'Serviços' }).click(); await p.waitForTimeout(450);
const cartao = await p.evaluate(() => {
  const tr = document.querySelector('.tabela tbody tr');
  if(!tr) return null;
  const td = [...tr.children];
  return {
    empilhado: getComputedStyle(tr).display === 'block',
    cabecaOculta: getComputedStyle(document.querySelector('.tabela thead')).display === 'none',
    // toda célula menos a primeira (o título) e a de ações precisa de rótulo
    semRotulo: td.slice(1, -1).filter(e => !e.getAttribute('data-r')).length,
    rotulos: td.slice(1, -1).map(e => e.getAttribute('data-r')),
  };
});
diz(cartao && cartao.empilhado, 'a linha da tabela empilha como cartão');
diz(cartao && cartao.cabecaOculta, 'o cabeçalho da tabela some — o rótulo foi para a célula');
diz(cartao && cartao.semRotulo === 0,
    `toda célula tem o nome da coluna (${(cartao?.rotulos||[]).join(', ')})`,
    `${cartao?.semRotulo} sem rótulo`);

console.log('\nA agenda rola dentro dela mesma');
await p.locator('.menu-botao').click(); await p.waitForTimeout(300);
await p.locator('.aba', { hasText: 'Agenda' }).click(); await p.waitForTimeout(450);
const grade = await p.evaluate(() => {
  const w = document.querySelector('.grade-wrap');
  return { rola: w.scrollWidth > w.clientWidth + 1,
           overflow: getComputedStyle(w).overflowX,
           pagina: document.documentElement.scrollWidth
                 - document.documentElement.clientWidth };
});
diz(grade.rola, 'a grade tem mais coluna do que cabe — é o caso que interessa');
diz(grade.overflow === 'auto' || grade.overflow === 'scroll',
    'e ela mesma rola', 'overflow-x: ' + grade.overflow);
diz(grade.pagina === 0, 'sem arrastar a página junto');

console.log('\nO app do cliente e o cadastro');
// `demo=1` em todas: estas medidas são de LAYOUT, e layout não deve depender
// de o banco estar no ar. Sem isso, a suíte de celular passaria a exigir
// internet e rede boa para dizer se um botão tem 44px.
for(const [url, nome] of [['agendar.html?salao=studio-bella&demo=1','vitrine do cliente'],
                          ['criar.html?demo=1','cadastro do dono']]){
  await p.goto(BASE + url); await p.waitForTimeout(900);
  const r = await medir();
  diz(r.vaza === 0, `${nome}: não rola para o lado`, `sobram ${r.vaza}px`);
  diz(r.alvos.length === 0, `${nome}: nenhum alvo abaixo de 40px`, r.alvos.join(', '));
}

diz(erros.length === 0, 'nenhum erro de JavaScript em nenhuma tela', erros.join(' | '));

await nav.close();
console.log(falhas
  ? `\n✗ ${falhas} falha(s) em ${ok + falhas} verificações.`
  : `\n✓ ${ok} verificações de celular.`);
process.exit(falhas ? 1 : 0);
