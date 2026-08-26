/* ===========================================================================
   AgendaPro — o checkout, do botão até o Pix na tela

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/cobranca.test.mjs

   ── O QUE ESTE ARQUIVO TESTA, E O QUE ELE NÃO TESTA ────────────────────────
   Testa o lado do navegador: o que o painel MANDA, o que ele desenha com o
   que volta, e o que ele faz — e não faz — enquanto o pagamento não cai.

   Não testa a função de borda em si: ela é Deno, fala com a API do Mercado
   Pago, e não roda aqui. A parte dela que dá para testar sozinha — a
   conferência da assinatura do webhook, que é a que segura fraude — está em
   tests/webhook-assinatura.test.js, importando o mesmo módulo que o Deno
   importa. E o que o banco faz com o pagamento está em cobranca.test.sql.

   A borda é interceptada pelo Playwright em vez de emulada na bancada. É de
   propósito: emular criaria uma segunda implementação para divergir da real,
   e o que interessa aqui é justamente o CONTEÚDO da requisição que o painel
   monta — que uma emulação esconderia.
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
const falso   = (m, c, d) => !c ? ok(m) : nao(m, d);
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
await d.criarConta({ email:`cob-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Dona Paula', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Cobrança ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444',
  p_documento:'11222333000181', p_origem:null });
const SALAO = cr[0].salao_id;

const pgLib = exigir('./bancada/node_modules/pg');
const banco = new pgLib.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();

/* ── O painel ─────────────────────────────────────────────────────────── */
const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();
const erros = [], recados = [];
pg.on('pageerror', e => erros.push(e.message));
pg.on('dialog', async dlg => { recados.push(dlg.message()); await dlg.accept(); });

/* A borda, interceptada. Guarda o que o painel mandou e devolve um Pix.

   O `mp_id` é diferente a cada chamada porque no Mercado Pago ele é: cada
   cobrança é um pagamento novo. Reaproveitá-lo aqui esbarrou na unicidade da
   coluna — que é justamente o que torna o aviso repetido inofensivo. */
let pedidos = [];
let nPagamento = 0;
await pg.route('**/functions/v1/criar-cobranca', async rota => {
  const req = rota.request();
  pedidos.push({
    corpo: JSON.parse(req.postData() || '{}'),
    auth: req.headers()['authorization'] || '',
  });
  // Abre a cobrança de verdade no banco, como a borda faria — assim o resto
  // do teste conversa com o mesmo estado que o painel vai reler.
  const b = JSON.parse(req.postData() || '{}');
  const r = await banco.query(
    `select * from public.abrir_cobranca($1, $2, $3, $4)`,
    [b.salaoId, b.plano, b.metodo, d.sessao().usuarioId]);
  const c = r.rows[0];
  const mpId = 'MP-TESTE-' + marca + '-' + (++nPagamento);
  await banco.query(
    `select public.anotar_cobranca($1,$2,$3,$4,$5,$6,$7)`,
    [c.id, mpId, 'pending',
     '00020126580014BR.GOV.BCB.PIX0136teste-copia-e-cola', 'iVBORw0KGgo=', null, null]);
  await rota.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, cobranca: {
      id: c.id, plano: c.plano, valor: c.valor, metodo: c.metodo,
      venceEm: c.vence_em,
      pixCopiaCola: '00020126580014BR.GOV.BCB.PIX0136teste-copia-e-cola',
      pixQrBase64: 'iVBORw0KGgo=', boletoUrl: null, linhaDigitavel: null,
    }}) });
});

await pg.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);

/* ══════════════════════════════════════════════════════════════════════════
   1. O QUE O NAVEGADOR MANDA — E O QUE ELE NÃO MANDA
   ══════════════════════════════════════════════════════════════════════════ */
secao('O painel não escolhe o preço');

await pg.evaluate(() => irPara('plano'));
await pg.waitForTimeout(900);
await pg.evaluate(() => assinar('salao', 'pix'));
await pg.waitForTimeout(2500);

igual('a borda foi chamada uma vez', pedidos.length, 1);
const enviado = pedidos[0] || { corpo:{}, auth:'' };

igual('mandou o salão', enviado.corpo.salaoId, SALAO);
igual('e o código do plano', enviado.corpo.plano, 'salao');
igual('e a forma', enviado.corpo.metodo, 'pix');

/* ⚠ A ASSERÇÃO QUE VALE DINHEIRO.
   Se o navegador mandasse quanto pagar, qualquer pessoa com o console aberto
   assinaria o plano de R$ 297 por um centavo. O preço é lido de `planos`
   dentro do banco — e a prova de que continua assim é que o corpo da
   requisição não tem campo de valor nenhum. */
const camposProibidos = ['valor','preco','precoMes','amount','transaction_amount','total'];
const vazou = camposProibidos.filter(k => k in enviado.corpo);
verdade('e NÃO manda valor nenhum', vazou.length === 0,
  'o navegador mandou ' + JSON.stringify(vazou) + ' — o preço é do servidor');

// Nem o CPF: ele já está no banco, atrás de RLS próprio.
falso('nem o CPF do dono', 'documento' in enviado.corpo || 'cpf' in enviado.corpo);

verdade('e vai com o token da sessão, para a borda saber quem é',
  /^Bearer .+/.test(enviado.auth), JSON.stringify(enviado.auth.slice(0, 12)));

/* ══════════════════════════════════════════════════════════════════════════
   2. O PIX NA TELA
   ══════════════════════════════════════════════════════════════════════════ */
secao('O código aparece para pagar');

const texto = await pg.evaluate(() =>
  (document.getElementById('fundo') || {}).textContent || '');
verdade('a janela mostra o plano e o valor',
  /Salão/.test(texto) && /R\$/.test(texto), texto.slice(0, 200));
igual('o copia-e-cola está na tela',
  await pg.evaluate(() => (document.getElementById('pixCodigo') || {}).value),
  '00020126580014BR.GOV.BCB.PIX0136teste-copia-e-cola');
verdade('e o QR também',
  await pg.evaluate(() => !!document.querySelector('#pgtoCorpo img[src^="data:image/png;base64,"]')));

/* ══════════════════════════════════════════════════════════════════════════
   3. "JÁ PAGUEI" NÃO É UM BOTÃO QUE PAGA
   Um botão que ativasse a assinatura por ter sido clicado seria o produto de
   graça para quem clica. Ele só relê o que o banco sabe.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Clicar em "já paguei" não paga');

await pg.evaluate(() => conferirPagamento());
await pg.waitForTimeout(2500);

const assinatura = async () => (await banco.query(
  `select status, plano, vence_em from public.assinaturas where salao_id = $1`,
  [SALAO])).rows[0];

let a = await assinatura();
igual('a assinatura no banco continua no teste', a.status, 'trial');
igual('e no plano de teste', a.plano, 'trial');
verdade('a tela avisa que ainda não caiu',
  await pg.evaluate(() =>
    /ainda não caiu/i.test(document.getElementById('pgtoRecado').textContent)),
  await pg.evaluate(() => document.getElementById('pgtoRecado').textContent));

/* ══════════════════════════════════════════════════════════════════════════
   4. QUANDO O PAGAMENTO CAI DE VERDADE
   Quem move a assinatura é `registrar_pagamento()`, chamada pelo webhook —
   aqui, chamada direto no banco, que é exatamente o que o webhook faz depois
   de conferir a assinatura HMAC e reler o pagamento na API.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O pagamento confirmado ativa a assinatura');

await banco.query(
  `select public.registrar_pagamento('MP-TESTE-${marca}-1',
     (select valor from public.cobrancas where mp_id = 'MP-TESTE-${marca}-1'),
     'approved')`);

a = await assinatura();
igual('o banco ativou', a.status, 'ativa');
igual('no plano pago', a.plano, 'salao');

recados.length = 0;
await pg.evaluate(() => conferirPagamento());
await pg.waitForTimeout(2500);

verdade('e a tela confirma para o dono',
  recados.some(t => /confirmado/i.test(t)), JSON.stringify(recados));
verdade('a janela fecha sozinha',
  await pg.evaluate(() =>
    !document.getElementById('fundo').classList.contains('on')));

/* ══════════════════════════════════════════════════════════════════════════
   5. A COBRANÇA QUE FICOU ABERTA REAPARECE
   Quem fecha a janela por engano não pode achar que precisa recomeçar — a
   segunda tentativa esbarraria na cobrança que ainda está pendente.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Um Pix esquecido volta a aparecer');

pedidos = [];
await pg.evaluate(() => assinar('equipe', 'pix'));
await pg.waitForTimeout(2500);
await pg.evaluate(() => fecharModal());
await pg.waitForTimeout(300);
await pg.evaluate(() => { telaAtual = 'plano'; pintarPlano(); });
await pg.waitForTimeout(2000);

verdade('o aviso de pagamento em aberto aparece na tela do Plano',
  await pg.evaluate(() => /em aberto/i.test(
    (document.getElementById('cobrancaPendente') || {}).textContent || '')),
  await pg.evaluate(() =>
    (document.getElementById('cobrancaPendente') || {}).textContent || '(vazio)'));

await pg.evaluate(() => reabrirCobranca());
await pg.waitForTimeout(600);
verdade('e o código volta sem chamar a borda de novo',
  await pg.evaluate(() => !!document.getElementById('pixCodigo')));

/* ══════════════════════════════════════════════════════════════════════════
   6. QUEM NÃO É GESTÃO NÃO ASSINA
   ══════════════════════════════════════════════════════════════════════════ */
secao('A recepção não assina pelo salão');

await pg.evaluate(() => fecharModal());
// Rebaixa o vínculo desta conta e recarrega: é o que a recepção enxerga.
await banco.query(
  `update public.vinculos set papel = 'recepcao'
    where salao_id = $1 and perfil_id = $2`, [SALAO, d.sessao().usuarioId]);
await pg.reload();
await pg.waitForTimeout(3500);

const abas = await pg.evaluate(() =>
  [...document.querySelectorAll('#abas .aba')].map(b => b.dataset.chave));
falso('ela nem vê a aba Plano', abas.includes('plano'), JSON.stringify(abas));

pedidos = [];
recados.length = 0;
await pg.evaluate(() => assinar('salao', 'pix'));
await pg.waitForTimeout(1200);
igual('e chamar a função na mão não abre cobrança nenhuma', pedidos.length, 0);
verdade('a tela diz por quê',
  recados.some(t => /proprietário|administrador/i.test(t)), JSON.stringify(recados));

// E o banco recusa mesmo que a tela deixasse passar.
const recusou = await pg.evaluate(async s => {
  try{ await Dados.chamar('minha_cobranca', { p_salao: s }); return null; }
  catch(e){ return e.message || 'recusado'; }
}, SALAO);
verdade('e o BANCO recusa até a leitura da cobrança para ela', recusou !== null,
  'a recepção leu a cobrança do salão');

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await banco.end();
await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
