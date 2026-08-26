/* ===========================================================================
   AgendaPro — falar com a cliente no WhatsApp

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/whatsapp.test.mjs

   O telefone que a cliente digita ao marcar tem o rótulo "WhatsApp" na tela
   dela — é por ali que ela espera ser chamada. Guardar esse número e obrigar
   o dono a copiar, abrir o aplicativo e colar é jogar fora o único dado que
   o agendamento já tem.

   O que esta suíte vigia, e que é onde isso costuma quebrar:

     · o número montado para o `wa.me` (sem código de país, a conversa abre
       com ninguém, e o WhatsApp só diz "número inválido");
     · o botão não existir quando não há telefone — botão que avisa do
       problema DEPOIS do clique é pior que botão ausente;
     · e o alvo de toque: o cartão de 30 minutos tem 30px de altura, e um
       botão dentro dele no celular seria um alvo de 22px em cima justamente
       do cartão que o dedo quer abrir.
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
await d.criarConta({ email:`zap-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Zap ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte', duracaoMin:60,
  intervaloMin:0, preco:70, ativo:true, aceitaOnline:true });

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');

// Uma cliente que marcou pelo link, com o WhatsApp que ela digitou.
await fetch(BASE + '/rest/v1/rpc/agendar', {
  method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
  body: JSON.stringify({ p_profissional: PROF.id,
    p_inicio: `${AMANHA}T14:00:00${desl}`, p_servicos:[SV.id],
    p_nome:'Maria Aparecida', p_telefone:'(11) 96666-5555' }) });

// E uma ficha SEM telefone, lançada pela recepção — acontece o tempo todo.
const semTel = await d.inserir('clientes', { salaoId: SALAO, nome:'Sem Telefone' });
await d.inserir('agendamentos', { salaoId: SALAO, clienteId: semTel.id,
  profissionalId: PROF.id, inicio: `${AMANHA}T16:00:00${desl}`,
  fim: `${AMANHA}T17:00:00${desl}`, status:'confirmado', origem:'recepcao' });

const nav = await chromium.launch({ executablePath: CHROMIUM });

/* ══════════════════════════════════════════════════════════════════════════
   O NÚMERO — a parte que quebra calada
   ══════════════════════════════════════════════════════════════════════════ */
secao('O número que vai para o wa.me');

const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const dono = await ctx.newPage();
const erros = [];
dono.on('pageerror', e => erros.push(e.message));
await dono.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await dono.goto(BASE + '/app.html');
await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(800);

const n = (t) => dono.evaluate(x => numeroWhatsapp(x), t);
igual('celular com DDD ganha o 55 do Brasil', await n('(11) 96666-5555'), '5511966665555');
igual('fixo de 10 dígitos também',            await n('11 3333-4444'),    '551133334444');
igual('quem já veio com o 55 não ganha outro', await n('+55 11 96666-5555'), '5511966665555');
igual('e o que já está limpo passa igual',     await n('5511966665555'),  '5511966665555');
igual('vazio não vira número', await n(''), null);
igual('nem só traços e parênteses', await n('() -'), null);
igual('nem um número curto demais para ser telefone', await n('99999'), null);

/* ══════════════════════════════════════════════════════════════════════════
   NA AGENDA
   ══════════════════════════════════════════════════════════════════════════ */
secao('O atalho no cartão da agenda, no computador');

igual('os dois atendimentos estão na grade',
  await dono.evaluate(() => document.querySelectorAll('.ag').length), 2);

const zaps = await dono.evaluate(() =>
  [...document.querySelectorAll('.ag')].map(c => ({
    quem: c.querySelector('b').textContent.trim(),
    tem: !!c.querySelector('.ag-zap'),
  })));
const daMaria = zaps.find(z => /Maria/.test(z.quem));
const semNum  = zaps.find(z => /Sem Telefone/.test(z.quem));
verdade('quem tem WhatsApp ganha o atalho no cartão', daMaria && daMaria.tem,
  JSON.stringify(zaps));
verdade('e quem NÃO tem telefone não ganha botão nenhum', semNum && !semNum.tem,
  'botão que avisa do problema depois do clique é pior que botão ausente');

// O clique não pode abrir o detalhe junto: são duas ações diferentes.
const abriuDetalhe = await dono.evaluate(() => {
  const b = document.querySelector('.ag-zap');
  if(!b) return 'sem botão';
  let abriu = false;
  const original = window.open;
  window.open = () => { abriu = true; return null; };
  b.click();
  window.open = original;
  const veu = document.getElementById('fundo');
  return { abriuZap: abriu, abriuJanela: veu.classList.contains('on') };
});
verdade('clicar nele abre a conversa', abriuDetalhe.abriuZap, JSON.stringify(abriuDetalhe));
verdade('e NÃO abre o detalhe do agendamento por baixo', !abriuDetalhe.abriuJanela,
  'o clique vazaria para o cartão e a pessoa acabaria com duas coisas abertas');

// O endereço montado: é isto que decide se a conversa abre com alguém.
const url = await dono.evaluate(() => {
  const a = bd.agendamentos.find(x => /Maria/.test(nomeCliente(x.clienteId)));
  let capturado = null;
  const original = window.open;
  window.open = (u) => { capturado = u; return null; };
  falarNoWhatsapp(a.id);
  window.open = original;
  return capturado;
});
verdade('o endereço é o do WhatsApp, com o número completo',
  /^https:\/\/wa\.me\/5511966665555\?/.test(url || ''), JSON.stringify(url));
verdade('e leva um recado já escrito, com o nome de quem vai receber',
  /Maria/.test(decodeURIComponent(url || '')), decodeURIComponent(url || ''));
verdade('dizendo de qual horário se trata',
  /14:00/.test(decodeURIComponent(url || '')), decodeURIComponent(url || ''));

/* ══════════════════════════════════════════════════════════════════════════
   NO DETALHE DO AGENDAMENTO
   ══════════════════════════════════════════════════════════════════════════ */
secao('E dentro do atendimento aberto');

await dono.evaluate(() => {
  const a = bd.agendamentos.find(x => /Maria/.test(nomeCliente(x.clienteId)));
  abrirDetalhe(a.id);
});
await dono.waitForTimeout(600);
const noDetalhe = await dono.evaluate(() => {
  const b = [...document.querySelectorAll('#modalPe button')]
    .find(x => /whats/i.test(x.textContent));
  if(!b) return null;
  const r = b.getBoundingClientRect();
  return { largura: Math.round(r.width), altura: Math.round(r.height),
           temIcone: !!b.querySelector('svg') };
});
verdade('o botão "Falar no WhatsApp" está lá', !!noDetalhe,
  'era o pedido: abrir o atendimento e falar direto com a cliente');
verdade('com o ícone desenhado, não um <span> vazio',
  noDetalhe && noDetalhe.temIcone,
  'o data-ico precisa virar SVG depois de o modal ser escrito');
verdade('e do tamanho de um botão de verdade',
  noDetalhe && noDetalhe.altura >= 40 && noDetalhe.largura >= 40,
  JSON.stringify(noDetalhe));

await dono.evaluate(() => fecharModal());
await dono.waitForTimeout(300);

// Ficha sem telefone: o botão não aparece nem aqui.
await dono.evaluate(() => {
  const a = bd.agendamentos.find(x => /Sem Telefone/.test(nomeCliente(x.clienteId)));
  abrirDetalhe(a.id);
});
await dono.waitForTimeout(600);
igual('e some quando a ficha não tem telefone',
  await dono.evaluate(() => [...document.querySelectorAll('#modalPe button')]
    .filter(x => /whats/i.test(x.textContent)).length), 0);
await dono.evaluate(() => fecharModal());

igual('nenhum erro de JavaScript no painel',
  erros.length ? erros.join(' | ') : 0, 0);
await dono.close();

/* ══════════════════════════════════════════════════════════════════════════
   NO CELULAR — o atalho do cartão NÃO pode existir
   ══════════════════════════════════════════════════════════════════════════ */
secao('No celular, o caminho é outro — de propósito');

const cel = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
const fone = await cel.newPage();
await fone.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await fone.goto(BASE + '/app.html');
await fone.waitForTimeout(3500);
await fone.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await fone.waitForTimeout(800);

const noCelular = await fone.evaluate(() =>
  [...document.querySelectorAll('.ag-zap')]
    .filter(b => { const r = b.getBoundingClientRect(); return r.width > 0 && r.height > 0; })
    .length);
igual('o atalho do cartão não é desenhado no celular', noCelular, 0,
  'seria um alvo de 22px em cima do cartão que o dedo quer abrir');

// E o caminho de lá funciona: tocar o cartão abre o detalhe com o botão grande.
await fone.evaluate(() => {
  const a = bd.agendamentos.find(x => /Maria/.test(nomeCliente(x.clienteId)));
  abrirDetalhe(a.id);
});
await fone.waitForTimeout(600);
const noFone = await fone.evaluate(() => {
  const b = [...document.querySelectorAll('#modalPe button')]
    .find(x => /whats/i.test(x.textContent));
  if(!b) return null;
  const r = b.getBoundingClientRect();
  return { largura: Math.round(r.width), altura: Math.round(r.height) };
});
verdade('mas o botão grande do detalhe está lá, e é alcançável com o dedo',
  noFone && noFone.altura >= 40 && noFone.largura >= 40, JSON.stringify(noFone));

await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de WhatsApp.`);
