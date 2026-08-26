/* ===========================================================================
   AgendaPro — o convite de equipe, do link ao painel

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/convite.test.mjs

   ── O QUE ESTA SUÍTE PERCORRE ──────────────────────────────────────────────
   O caminho inteiro, com dois navegadores diferentes, porque é assim que
   acontece: a dona gera o link no computador dela, manda pelo WhatsApp, e a
   funcionária abre no celular dela.

     dona abre Equipe → gera o link → funcionária abre o link →
     cria a conta dela → cai dentro do painel do salão

   O teste do banco (tests/equipe.test.sql) já guarda as recusas — link de uso
   único, vencido, revogado, quem não administra. Aqui o que se prova é que a
   TELA leva a pessoa até o fim, porque um convite que só funciona por SQL não
   resolve o problema que ele existe para resolver.
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
const ok  = m => { console.log('  ✓ ' + m); passou++; };
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
await d.criarConta({ email:`conv-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Convite ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

/* ══════════════════════════════════════════════════════════════════════════
   1. A DONA GERA O LINK, PELA TELA
   ══════════════════════════════════════════════════════════════════════════ */
secao('A dona convida pela tela de Equipe');

const dona = await (await nav.newContext({ viewport:{width:1360,height:900} })).newPage();
dona.on('pageerror', e => erros.push('dona: ' + e.message));
await dona.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await dona.goto(BASE + '/app.html');
await dona.waitForTimeout(3500);
await dona.evaluate(() => irPara('equipe'));
await dona.waitForTimeout(1200);

verdade('a seção "Quem entra no sistema" aparece',
  await dona.evaluate(() =>
    /Quem entra no sistema/.test(document.getElementById('cartaoAcessos').textContent)));

// A lista nunca nasce vazia: quem abre esta tela é gestor, e gestor tem
// vínculo. No começo há uma linha só — a da própria dona.
igual('a lista começa com uma pessoa: a própria dona',
  await dona.evaluate(() =>
    document.querySelectorAll('#listaAcessos tbody tr').length), 1);
verdade('marcada como "você"',
  await dona.evaluate(() =>
    /você/.test(document.getElementById('listaAcessos').textContent)));

await dona.evaluate(() => abrirConvite());
await dona.waitForTimeout(400);
await dona.evaluate(() => {
  document.getElementById('vNome').value = 'Rita da recepção';
  document.querySelector('input[name="vPapel"][value="recepcao"]').checked = true;
});
await dona.evaluate(() => gerarConvite());
await dona.waitForTimeout(1500);

const link = await dona.evaluate(() => {
  const c = document.getElementById('vLink');
  return c ? c.value : null;
});
verdade('o link foi gerado', !!link && /convite\.html\?c=/.test(link || ''),
  JSON.stringify(link));
verdade('e a tela avisa que ele é de uso único',
  await dona.evaluate(() =>
    /UMA vez/.test(document.getElementById('vSaida').textContent)));

/* ══════════════════════════════════════════════════════════════════════════
   2. A FUNCIONÁRIA ABRE O LINK, NOUTRO NAVEGADOR
   ══════════════════════════════════════════════════════════════════════════ */
secao('A funcionária abre o link no aparelho dela');

// Contexto separado: sessão, cookies e localStorage próprios. Reaproveitar o
// da dona faria o teste passar por um caminho que não existe na vida real.
const rita = await (await nav.newContext({ viewport:{width:390,height:844} })).newPage();
rita.on('pageerror', e => erros.push('rita: ' + e.message));
await rita.addInitScript(b => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
}, BASE);

const caminho = link.replace(/^https?:\/\/[^/]+/, BASE);
await rita.goto(caminho);
await rita.waitForTimeout(2500);

verdade('ela vê o nome do salão',
  await rita.evaluate(() =>
    /Salão Convite/.test(document.getElementById('convTitulo').textContent)),
  await rita.evaluate(() => document.getElementById('convTitulo').textContent));
verdade('e para que foi convidada',
  await rita.evaluate(() => /Recepção/.test(document.body.textContent)));
verdade('e para quem é o convite',
  await rita.evaluate(() => /Rita da recepção/.test(document.body.textContent)));

verdade('o formulário que abre é o de CRIAR conta',
  await rita.evaluate(() => !!document.getElementById('cSenha')),
  'quem recebe convite quase sempre ainda não tem conta');

/* ══════════════════════════════════════════════════════════════════════════
   3. ELA CRIA A CONTA E CAI DENTRO DO PAINEL
   ══════════════════════════════════════════════════════════════════════════ */
secao('Criar conta e entrar, num gesto só');

await rita.evaluate(m => {
  document.getElementById('cNome').value  = 'Rita Recep';
  document.getElementById('cEmail').value = 'rita-' + m + '@teste.com';
  document.getElementById('cTel').value   = '(11) 98888-1234';
  document.getElementById('cSenha').value = 'minhasenhaboa';
}, marca);
await rita.evaluate(() => criarEAceitar());
await rita.waitForTimeout(5000);

verdade('ela foi levada para o painel',
  /app\.html/.test(rita.url()), rita.url());

// E o que importa mais: o painel é o painel DAQUELE salão.
const oQueRitaVe = await rita.evaluate(async () => {
  await new Promise(r => setTimeout(r, 2500));
  return {
    salao: (document.getElementById('tbSalao') || {}).textContent,
    papel: (document.getElementById('latQuemPapel') || {}).textContent,
  };
});
verdade('no salão certo', /Salão Convite/.test(oQueRitaVe.salao || ''),
  JSON.stringify(oQueRitaVe));
igual('e com o papel de recepção', (oQueRitaVe.papel || '').trim(), 'Recepção');

/* ══════════════════════════════════════════════════════════════════════════
   4. O LINK NÃO SERVE DE NOVO
   ══════════════════════════════════════════════════════════════════════════ */
secao('O mesmo link, uma segunda vez');

const terceiro = await (await nav.newContext({ viewport:{width:390,height:844} })).newPage();
terceiro.on('pageerror', e => erros.push('terceiro: ' + e.message));
await terceiro.addInitScript(b => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
}, BASE);
await terceiro.goto(caminho);
await terceiro.waitForTimeout(2500);

verdade('a página diz que o convite não vale mais',
  await terceiro.evaluate(() =>
    /não vale mais/.test(document.getElementById('convTitulo').textContent)),
  await terceiro.evaluate(() => document.getElementById('convTitulo').textContent));
verdade('e NÃO oferece formulário nenhum',
  await terceiro.evaluate(() => !document.getElementById('cSenha')
                             && !document.getElementById('eSenha')),
  'um formulário aqui é um convite para insistir');

/* ══════════════════════════════════════════════════════════════════════════
   5. A DONA VÊ A RITA NA LISTA, E CONSEGUE TIRAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('A lista da dona, depois');

await dona.evaluate(() => { fecharModal(); pintarAcessos(); });
await dona.waitForTimeout(1800);

verdade('a Rita aparece com acesso',
  await dona.evaluate(() =>
    /Rita Recep/.test(document.getElementById('listaAcessos').textContent)),
  await dona.evaluate(() => document.getElementById('listaAcessos').textContent));

verdade('a própria dona não tem botão de tirar o acesso dela',
  await dona.evaluate(() => {
    const linhas = [...document.querySelectorAll('#listaAcessos tbody tr')];
    const minha = linhas.find(l => /você/.test(l.textContent));
    return !!minha && !minha.querySelector('button');
  }),
  'ficaria de fora da própria casa, sem caminho de volta pela tela');

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
