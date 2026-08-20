/* ===========================================================================
   AgendaPro — a abertura da tela de entrar

     python3 -m http.server 8099 --directory .
     PLAYWRIGHT=.../node_modules/playwright node tests/abertura.test.mjs

   Uma cortina por cima do login é a coisa mais fácil de deixar quebrada sem
   ninguém notar: ela some da vista mas continua no DOM, e a partir daí todo
   clique morre nela. A tela fica bonita e inútil, e o defeito não aparece em
   nenhuma foto. Por isso quase tudo aqui confere o DEPOIS, não o durante.
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BASE = process.env.BASE || 'http://127.0.0.1:8099/';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m,d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const verdade = (m,c) => c ? ok(m) : nao(m, 'esperava verdadeiro');
const entre = (m,v,a,b) => (v>=a && v<=b) ? ok(`${m} (${v}ms)`)
                                          : nao(m, `${v}ms fora de ${a}–${b}ms`);

const nav = await chromium.launch({ executablePath: CHROMIUM });

console.log('\nA cortina sobe sozinha');
{
  const ctx = await nav.newContext({ viewport:{width:1280,height:860} });
  const p = await ctx.newPage();
  const erros = []; p.on('pageerror', e => erros.push(e.message));

  const t0 = Date.now();
  await p.goto(BASE + 'entrar.html');
  const carregou = Date.now();

  verdade('a cortina está de pé assim que a página abre',
    await p.isVisible('#abertura'));
  verdade('e o logotipo dela é o mesmo arquivo da marca',
    (await p.getAttribute('.abertura-marca','src')).includes('logotipo-branco'));

  await p.waitForSelector('#abertura', { state:'detached', timeout:6000 });
  // 3s de cortina + 0,5s de esmaecimento, contados do fim do carregamento.
  entre('sai por volta dos 3 segundos', Date.now() - carregou, 2800, 4200);

  verdade('e some do DOM — não fica camada invisível por cima',
    await p.evaluate(() => !document.getElementById('abertura')));
  verdade('o formulário fica clicável depois',
    await p.isEnabled('#btEntrar'));
  verdade('e o cursor já está no campo de e-mail',
    await p.evaluate(() => document.activeElement.id === 'email'));
  verdade('nenhum erro de JavaScript', erros.length === 0);
  await ctx.close();
}

console.log('\nDá para pular');
for (const [como, agir] of [
  ['com um clique', async p => p.mouse.click(640, 430)],
  ['com uma tecla', async p => p.keyboard.press('Escape')],
]) {
  const ctx = await nav.newContext({ viewport:{width:1280,height:860} });
  const p = await ctx.newPage();
  await p.goto(BASE + 'entrar.html');
  await p.waitForTimeout(350);
  const t = Date.now();
  await agir(p);
  await p.waitForSelector('#abertura', { state:'detached', timeout:2500 });
  entre(`${como}, sem esperar os 3 segundos`, Date.now() - t, 0, 1500);
  await ctx.close();
}

{
  // O caso que faz a cortina piscar de volta: o toque acontece quase junto do
  // relógio, e as duas saídas disparam. A segunda reiniciaria a transição.
  const ctx = await nav.newContext({ viewport:{width:1280,height:860} });
  const p = await ctx.newPage();
  await p.goto(BASE + 'entrar.html');
  await p.waitForTimeout(2900);
  await p.mouse.click(640, 430);
  await p.waitForTimeout(1500);
  verdade('tocar em cima da hora não faz a cortina voltar',
    await p.evaluate(() => !document.getElementById('abertura')));
  await ctx.close();
}

console.log('\nE não atrapalha ninguém');
{
  // Sem JavaScript a cortina não pode existir: ficaria por cima do login para
  // sempre, e o sistema viraria uma tela preta que não deixa entrar.
  const ctx = await nav.newContext({ viewport:{width:1280,height:860},
                                     javaScriptEnabled:false });
  const p = await ctx.newPage();
  await p.goto(BASE + 'entrar.html');
  await p.waitForTimeout(400);
  verdade('sem JavaScript, a cortina nem aparece',
    await p.evaluate(() =>
      getComputedStyle(document.getElementById('abertura')).display === 'none'));
  verdade('e o campo de e-mail está à vista', await p.isVisible('#email'));
  await ctx.close();
}
{
  // Quem pediu menos animação no sistema recebe a marca parada e curta.
  const ctx = await nav.newContext({ viewport:{width:1280,height:860},
                                     reducedMotion:'reduce' });
  const p = await ctx.newPage();
  await p.goto(BASE + 'entrar.html');
  await p.waitForTimeout(300);
  verdade('com "menos movimento", a barra de progresso não é desenhada',
    await p.evaluate(() =>
      getComputedStyle(document.querySelector('.abertura-traco')).display === 'none'));
  await p.waitForSelector('#abertura', { state:'detached', timeout:6000 });
  verdade('e a cortina sai do mesmo jeito', true);
  await ctx.close();
}

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou+falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de abertura.`);
