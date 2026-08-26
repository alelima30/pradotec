/* ===========================================================================
   AgendaPro — a visão da semana

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/semana.test.mjs

   ── POR QUE ESTA TELA EXISTE ───────────────────────────────────────────────
   A agenda só sabia mostrar um dia. Para saber se quinta está cheia o dono
   tinha que clicar em ‹ › até chegar lá e voltar contando os dias — e é
   olhando a semana que se decide encaixe, folga e promoção de terça vazia.

   ── O QUE ESTA SUÍTE GUARDA ────────────────────────────────────────────────
   Menos a existência da tela e mais as duas formas de ela MENTIR:

     · o topo somando um dia com sete dias de agenda embaixo. É a mesma
       classe de defeito do "1 atendimento e a grade vazia" que já custou
       caro aqui: contador e grade contando coisas diferentes.

     · dois atendimentos ao mesmo tempo, um cobrindo o outro. A semana diria
       que há uma cadeira livre onde há duas ocupadas, e o dono marcaria em
       cima — o banco recusaria depois, na frente da cliente.
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
await d.criarConta({ email:`semana-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Semana ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const pg = exigir('./bancada/node_modules/pg');
const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(
  `update public.assinaturas set plano='time', status='ativa' where salao_id=$1`,
  [SALAO]);

const P1 = (await d.lista('profissionais', { salaoId: SALAO }))[0];
const P2 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Jucelia',
  ativo:true, aceitaOnline:true, comissaoPct:40 });
for(const p of [P1, P2])
  for(let i = 0; i <= 6; i++)
    await d.inserir('jornadas', { profissionalId: p.id, diaSemana:i,
                                  inicio:'08:00', fim:'18:00' });
const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte',
  duracaoMin:60, intervaloMin:0, preco:50, ativo:true, aceitaOnline:true });

// A segunda-feira da semana que vem — futuro, para nada esbarrar em "agora".
function segundaDa(iso){
  const [y,m,dd] = iso.split('-').map(Number);
  const dt = new Date(y, m-1, dd);
  const dow = dt.getDay();
  dt.setDate(dt.getDate() + (dow === 0 ? -6 : 1 - dow));
  return new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
}
const hojeIso = new Date().toISOString().slice(0,10);
const seg = segundaDa(hojeIso);
seg.setDate(seg.getDate() + 7);
const diaMais = n => {
  const x = new Date(seg); x.setDate(x.getDate() + n);
  return `${x.getFullYear()}-${String(x.getMonth()+1).padStart(2,'0')}-${String(x.getDate()).padStart(2,'0')}`;
};
const SEG = diaMais(0), QUA = diaMais(2), DOM = diaMais(6);

const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(SEG + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');

let n = 0;
async function marcar(dia, profId, hIni, hFim){
  const c = await d.inserir('clientes', { salaoId: SALAO, nome:'Cliente ' + (++n),
    telefone: '11' + (900000000 + Math.floor(Math.random()*99999999)) });
  const a = await d.inserir('agendamentos', { salaoId: SALAO, clienteId: c.id,
    profissionalId: profId, inicio:`${dia}T${hIni}:00${desl}`,
    fim:`${dia}T${hFim}:00${desl}`, status:'confirmado', origem:'recepcao',
    valorPrevisto: 50 });
  await d.inserir('agendamento_servicos', { agendamentoId: a.id, servicoId: SV.id,
    ordem:1, duracaoMin:60, preco:50, comissaoPct:0 });
}

// Segunda: duas pessoas ao MESMO tempo — é o caso que uma cobre a outra.
await marcar(SEG, P1.id, '10:00', '11:00');
await marcar(SEG, P2.id, '10:00', '11:00');
// Quarta e domingo, para a semana ter mais de um dia com coisa.
await marcar(QUA, P1.id, '14:00', '15:00');
await marcar(DOM, P2.id, '09:00', '10:00');

const nav = await chromium.launch({ executablePath: CHROMIUM });
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
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, QUA);
await dono.waitForTimeout(500);

/* ══════════════════════════════════════════════════════════════════════════
   1. TROCAR DE VISTA
   ══════════════════════════════════════════════════════════════════════════ */
secao('O botão Dia | Semana');

igual('a agenda abre no dia', await dono.evaluate(() => vistaAgenda), 'dia');
verdade('e os dois botões estão lá',
  await dono.evaluate(() => document.querySelectorAll('#vistas button').length) === 2);

await dono.evaluate(() => trocarVista('semana'));
await dono.waitForTimeout(400);
igual('clicar em Semana troca a vista',
  await dono.evaluate(() => vistaAgenda), 'semana');

igual('e a grade passa a ter sete colunas de dia',
  await dono.evaluate(() => document.querySelectorAll('.col').length), 7);

const rotulo = await dono.evaluate(() =>
  document.getElementById('rotuloDia').textContent.trim());
verdade('o rótulo mostra o período, não um dia', /\d{2}\/\d{2} a \d{2}\/\d{2}/.test(rotulo),
  JSON.stringify(rotulo));

/* ══════════════════════════════════════════════════════════════════════════
   2. O TOPO TEM QUE SOMAR O QUE A GRADE MOSTRA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Contador e grade contando a mesma coisa');

const contador = () => dono.evaluate(() =>
  Number(document.querySelector('#kpisDia .kpi .v').textContent));
const cartoes = () => dono.evaluate(() => document.querySelectorAll('.ag').length);

igual('a semana mostra os quatro atendimentos', await cartoes(), 4);
igual('e o topo conta os quatro', await contador(), 4);
verdade('o rótulo do dinheiro diz "na semana"',
  await dono.evaluate(() =>
    [...document.querySelectorAll('#kpisDia .r')].some(e => /na semana/.test(e.textContent))),
  'com sete dias na tela, "previsto no dia" é mentira');

/* ══════════════════════════════════════════════════════════════════════════
   3. DOIS AO MESMO TEMPO NÃO PODEM SE COBRIR
   ══════════════════════════════════════════════════════════════════════════ */
secao('Segunda tem duas pessoas às 10:00');

const naSegunda = await dono.evaluate(dia => {
  const cols = [...document.querySelectorAll('.col')];
  // A coluna da segunda é a primeira; pego os cartões dela.
  return [...cols[0].querySelectorAll('.ag')].map(el => ({
    left: el.style.left, width: el.style.width, top: el.style.top,
  }));
}, SEG);

igual('os dois cartões estão desenhados', naSegunda.length, 2);
verdade('e em posições horizontais diferentes',
  naSegunda.length === 2 && naSegunda[0].left !== naSegunda[1].left,
  JSON.stringify(naSegunda));
verdade('cada um com menos da largura inteira',
  naSegunda.every(c => /50%/.test(c.width)),
  'com 100% um cobriria o outro: ' + JSON.stringify(naSegunda));

/* ══════════════════════════════════════════════════════════════════════════
   4. NAVEGAR ANDA UMA SEMANA, NÃO UM DIA
   ══════════════════════════════════════════════════════════════════════════ */
secao('As setas andam o que a tela mostra');

const antes = await dono.evaluate(() => diaAtual);
await dono.evaluate(() => mudarDia(1));
await dono.waitForTimeout(300);
const depois = await dono.evaluate(() => diaAtual);
const passos = Math.round((new Date(depois) - new Date(antes)) / 864e5);
igual('› anda sete dias na visão de semana', passos, 7);
igual('e a semana seguinte está vazia', await cartoes(), 0);

await dono.evaluate(() => mudarDia(-1));
await dono.waitForTimeout(300);
igual('‹ volta para a semana com os quatro', await cartoes(), 4);

/* ══════════════════════════════════════════════════════════════════════════
   5. CLICAR NO DIA ABRE O DIA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Do panorama para o detalhe');

await dono.evaluate(() => document.querySelectorAll('.col-h.clicavel')[0].click());
await dono.waitForTimeout(400);
igual('clicar no cabeçalho de segunda volta para a visão de dia',
  await dono.evaluate(() => vistaAgenda), 'dia');
igual('no dia certo', await dono.evaluate(() => diaAtual), SEG);
igual('e o topo volta a contar só aquele dia', await contador(), 2);

/* ══════════════════════════════════════════════════════════════════════════
   6. A REPINTURA NÃO PODE SUJAR O QUE VAI PARA O BANCO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A semana não inventa campo nos agendamentos');

await dono.evaluate(() => trocarVista('semana'));
await dono.waitForTimeout(400);
const campos = await dono.evaluate(() =>
  [...new Set(bd.agendamentos.flatMap(a => Object.keys(a)))]);
verdade('nenhum campo de desenho ficou grudado na linha',
  !campos.some(k => k.startsWith('_')),
  'iria junto na gravação e a linha pareceria mudada a cada repintura: '
  + JSON.stringify(campos));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
await banco.end();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
