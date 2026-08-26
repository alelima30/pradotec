/* ===========================================================================
   AgendaPro — o cartão do atendimento tem que ser LEGÍVEL nos dois temas

     PLAYWRIGHT=/caminho/node_modules/playwright node tests/cartao-legivel.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   Relatado com dois prints da MESMA agenda: no tema escuro os nomes das
   clientes apareciam nos cartões; no tema claro a grade estava vazia, com o
   topo contando "2 atendimentos".

   A causa não era a grade. O cartão saía com `background:${p.cor}` e
   `color:#fff` fixo no CSS. Quando `p.cor` não é uma cor válida — vazia,
   nula, qualquer coisa — o navegador DESCARTA a declaração e o cartão fica
   transparente. No escuro, letra branca sobre a grade escura continua
   legível e ninguém percebe. No claro é branco no branco: o atendimento
   some da tela enquanto o contador continua contando.

   ── COMO ESTA SUÍTE MEDE ───────────────────────────────────────────────────
   Não olhando o HTML, e não conferindo se `p.cor` existe: conferindo se dá
   para LER. Mede a luminância do fundo e a da letra, computados pelo
   navegador, e exige 4.5:1 — a régua da WCAG para texto. Um teste que só
   olhasse o atributo aprovaria letra amarela em fundo branco.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BASE || 'http://127.0.0.1:8099/';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const secao = t => console.log('\n' + t);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();
const erros = [];
pg.on('pageerror', e => erros.push(e.message));
await pg.goto(BASE + 'app.html?demo=1');
await pg.waitForTimeout(2500);

/* A cor efetiva atrás de um elemento: sobe pelos pais até achar quem não é
   transparente. É isso que o olho enxerga, e é o que o cartão sem fundo
   fazia — herdar o branco da grade e some com a letra branca por cima. */
const MEDIR = `(el) => {
  const num = c => (c.match(/[\\d.]+/g) || []).map(Number);
  const opaco = c => { const v = num(c); return v.length >= 4 ? v[3] > 0.05 : v.length === 3; };
  let fundo = null;
  for(let n = el; n; n = n.parentElement){
    const c = getComputedStyle(n).backgroundColor;
    if(c && opaco(c)){ fundo = num(c).slice(0,3); break; }
  }
  if(!fundo) fundo = [255,255,255];
  const letra = num(getComputedStyle(el).color).slice(0,3);
  const lum = ([r,g,b]) => [r,g,b].map(v => { const c = v/255;
      return c <= 0.03928 ? c/12.92 : Math.pow((c+0.055)/1.055, 2.4); })
      .reduce((s,v,i) => s + [0.2126,0.7152,0.0722][i]*v, 0);
  const a = lum(fundo), b = lum(letra);
  return { contraste: (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05),
           fundo: fundo.join(','), letra: letra.join(',') };
}`;

async function medirCartoes(){
  return pg.evaluate(([medidor]) => {
    const medir = eval(medidor);
    return [...document.querySelectorAll('.ag b')].map(b => ({
      texto: b.textContent.trim().slice(0, 24), ...medir(b),
    }));
  }, [MEDIR]);
}

for(const tema of ['claro', 'escuro']){
  secao(`Tema ${tema}`);

  await pg.evaluate(t => {
    // Um profissional SEM cor gravada: é exatamente o estado que apagava o
    // cartão. O teste não pergunta se isso pode acontecer — força.
    const p = bd.profissionais.find(x => x.salaoId === salaoAtual);
    p.cor = '';
    // O tema é posto DIRETO no atributo, não por `trocarTema()`: aquele
    // alterna a partir do que está lá, e num documento sem `data-tema` a
    // primeira volta ia parar no tema errado — os dois laços mediam o
    // escuro, e a asserção de contraste passava sem nunca ver o claro.
    document.documentElement.setAttribute('data-tema', t);
    telaAtual = 'agenda';
    const ag = doSalao(bd.agendamentos)[0];
    if(ag) diaAtual = ag.data;
    pintar();
  }, tema);
  await pg.waitForTimeout(500);

  const fundoDaPagina = await pg.evaluate(() =>
    getComputedStyle(document.body).backgroundColor);
  const claro = (fundoDaPagina.match(/\d+/g) || []).slice(0,3)
                  .reduce((a,b) => a + Number(b), 0) > 380;
  verdade(`${tema}: a página está mesmo no tema ${tema}`,
    claro === (tema === 'claro'),
    `fundo do body: ${fundoDaPagina} — medir o tema errado aprova o defeito`);

  const cartoes = await medirCartoes();
  verdade(`${tema}: há cartão na grade para medir`, cartoes.length > 0,
    'sem cartão o resto desta seção não prova nada');

  const ilegiveis = cartoes.filter(c => c.contraste < 4.5);
  verdade(`${tema}: todo nome de cliente é legível no cartão`,
    cartoes.length > 0 && ilegiveis.length === 0,
    ilegiveis.map(c => `"${c.texto}" — ${c.contraste.toFixed(2)}:1 `
      + `(letra ${c.letra} sobre fundo ${c.fundo})`).join('; '));

  const transparente = await pg.evaluate(() => {
    const el = document.querySelector('.ag');
    if(!el) return null;
    const c = getComputedStyle(el).backgroundColor;
    const v = (c.match(/[\d.]+/g) || []).map(Number);
    return v.length >= 4 ? v[3] : 1;
  });
  verdade(`${tema}: o cartão tem fundo próprio, não o da grade`,
    transparente !== null && transparente > 0.05,
    'fundo transparente é o que fazia o cartão sumir no tema claro');
}

secao('Sem erro de JavaScript');
verdade('nenhum erro no console', erros.length === 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
