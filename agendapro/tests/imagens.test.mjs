/* ===========================================================================
   Imagens: redução, custo de espaço e o guarda do navegador

   Roda num navegador de verdade, porque a redução usa <canvas> e FileReader —
   não existe em Node. Precisa do servidor de pé:

       python3 -m http.server 8099 --directory .
       node tests/imagens.test.mjs
   =========================================================================== */
// O Playwright não é dependência do projeto — este é o único teste que precisa
// de navegador. O caminho vem do ambiente para não amarrar a máquina de
// ninguém:  PLAYWRIGHT=/caminho/para/node_modules/playwright node tests/imagens.test.mjs
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
const p = await (await nav.newContext()).newPage();
const erros = [];
p.on('pageerror', e => erros.push(e.message));
await p.goto(BASE + 'app.html');
await p.waitForTimeout(700);

console.log('\nO custo de uma imagem no localStorage');

// Base64 infla 4/3 e o UTF-16 dobra: 2,66× o tamanho da imagem. A conta que
// erra aqui deixa o navegador estourar no meio de um salvamento.
const custo = await p.evaluate(() => {
  const url = 'data:image/jpeg;base64,' + 'A'.repeat(4000);
  return { bytes: Imagens.bytesDe(url), custo: Imagens.custoNoNavegador(url),
           tam: url.length };
});
diz(custo.custo === custo.tam * 2,
    'custo no navegador = tamanho da string × 2 (UTF-16)',
    JSON.stringify(custo));
diz(custo.custo > custo.bytes * 2.5,
    'e é bem maior que os bytes da imagem — 2,66× no total',
    `bytes=${custo.bytes} custo=${custo.custo}`);

console.log('\nRedução de uma foto de celular');

// PNG 2400×1600 gerado na página: grande o bastante para provar a redução.
const gerar = async (l, a) => p.evaluate(([l, a]) => {
  const c = document.createElement('canvas');
  c.width = l; c.height = a;
  const x = c.getContext('2d');
  const g = x.createLinearGradient(0, 0, l, a);
  g.addColorStop(0, '#3D6B8E'); g.addColorStop(1, '#8A5A83');
  x.fillStyle = g; x.fillRect(0, 0, l, a);
  return new Promise(ok => c.toBlob(b => {
    window.__arquivo = new File([b], 'foto.png', { type: 'image/png' });
    ok(b.size);
  }, 'image/png'));
}, [l, a]);

const bruto = await gerar(2400, 1600);
console.log(`    (original: ${Math.round(bruto/1024)} KB, 2400×1600)`);

for(const [tipo, ladoMax] of [['logo',256],['capa',1200],['servico',600]]){
  const r = await p.evaluate(async t => {
    const x = await Imagens.reduzir(window.__arquivo, t);
    return { l: x.largura, a: x.altura, kb: Math.round(x.bytes/1024),
             jpeg: x.dataUrl.startsWith('data:image/jpeg'),
             teto: Imagens.MEDIDAS[t].tetoKB };
  }, tipo);
  diz(Math.max(r.l, r.a) === ladoMax,
      `${tipo}: cabe em ${ladoMax}px no lado maior`, `saiu ${r.l}×${r.a}`);
  diz(r.jpeg, `${tipo}: sai como JPEG, não como PNG de 2 MB`);
  diz(r.kb <= r.teto,
      `${tipo}: ${r.kb} KB, dentro do teto de ${r.teto} KB`);
}

console.log('\nO guarda de espaço');

const guarda = await p.evaluate(async () => {
  // Enche o localStorage até perto do teto e tenta guardar mais uma.
  const antes = Imagens.ocupadoNoNavegador();
  const falta = Imagens.TETO_NAVEGADOR - antes;
  const enchimento = 'x'.repeat(Math.max(0, Math.floor(falta / 2) - 5000));
  try{ localStorage.setItem('__enche', enchimento); }
  catch(e){ return { pulou: 'o próprio localStorage recusou: ' + e.name }; }

  const url = 'data:image/jpeg;base64,' + 'A'.repeat(20000);
  let recusou = false, mensagem = '';
  try{ await Imagens.publicar(url, 'salao-1', 'teste'); }
  catch(e){ recusou = true; mensagem = e.message; }
  localStorage.removeItem('__enche');
  return { recusou, mensagem };
});

if(guarda.pulou){
  console.log('  · ' + guarda.pulou);
} else {
  diz(guarda.recusou, 'perto do teto, recusa a imagem em vez de estourar');
  diz(/espaço/i.test(guarda.mensagem || ''),
      'e a mensagem explica o que fazer', guarda.mensagem);
}

const semEspaco = await p.evaluate(async () => {
  try{ await Imagens.publicar('data:image/jpeg;base64,AAAA', 's1', 't'); return 'passou'; }
  catch(e){ return 'recusou'; }
});
diz(semEspaco === 'passou', 'com espaço sobrando, guarda normalmente');

const jaEndereco = await p.evaluate(() =>
  Imagens.publicar('https://exemplo.com/foto.jpg', 's1', 't'));
diz(jaEndereco === 'https://exemplo.com/foto.jpg',
    'endereço que já é URL passa direto, sem reprocessar');

diz(erros.length === 0, 'nenhum erro de JavaScript na página', erros.join(' | '));

await nav.close();
console.log(falhas
  ? `\n✗ ${falhas} falha(s) em ${ok + falhas} verificações.`
  : `\n✓ ${ok} verificações de imagem.`);
process.exit(falhas ? 1 : 0);
