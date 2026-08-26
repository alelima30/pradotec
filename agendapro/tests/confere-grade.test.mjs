/* ===========================================================================
   AgendaPro — a grade confessa quando não mostra o que o contador conta

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/confere-grade.test.mjs

   ── POR QUE ISTO EXISTE ────────────────────────────────────────────────────
   Duas vezes o mesmo sintoma foi relatado com print: o topo dizendo "2
   atendimentos" e a grade vazia embaixo. As causas foram diferentes — horário
   fora da faixa desenhada numa, profissional sem coluna na outra — e as duas
   foram corrigidas.

   O que não dá para corrigir de uma vez é a CLASSE do defeito. São duas
   contas sobre a mesma coisa: `agendaDoDia()` soma o dia inteiro, e o desenho
   percorre colunas e uma faixa de horário. Duas contas separadas voltam a
   discordar um dia.

   Então a tela passa a conferir a si mesma, e esta suíte guarda a conferência
   — não as causas. Ela QUEBRA a grade de propósito e exige que a tela avise.

   ── E O CARIMBO DE VERSÃO ──────────────────────────────────────────────────
   Custou uma volta inteira descobrir que a tela reclamada era a de ontem. O
   navegador serve HTML do cache dele por alguns minutos e nada dizia isso.
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

/* ══════════════════════════════════════════════════════════════════════════
   0. OS DOIS NÚMEROS DE VERSÃO TÊM QUE ANDAR JUNTOS
   ══════════════════════════════════════════════════════════════════════════ */
secao('O carimbo de versão não pode mentir');
{
  const app = fs.readFileSync(path.join(RAIZ, 'app.html'), 'utf8');
  const sw  = fs.readFileSync(path.join(RAIZ, 'sw.js'), 'utf8');
  const noApp = (app.match(/const VERSAO_APP = '([^']+)'/) || [])[1];
  const noSw  = (sw.match(/const VERSAO = 'agendapro-([^']+)'/) || [])[1];
  verdade('o app.html declara uma versão', !!noApp, JSON.stringify(noApp));
  verdade('o sw.js declara uma versão', !!noSw, JSON.stringify(noSw));
  igual('e as duas são a mesma', noApp, noSw);
}

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
await d.criarConta({ email:`conf-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Confere ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte',
  duracaoMin:60, intervaloMin:0, preco:50, ativo:true, aceitaOnline:true });

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');
const CLI = await d.inserir('clientes', { salaoId: SALAO, nome:'Maria Sumida',
  telefone: '11' + (900000000 + Math.floor(Math.random()*99999999)) });
const AG = await d.inserir('agendamentos', { salaoId: SALAO, clienteId: CLI.id,
  profissionalId: PROF.id, inicio:`${AMANHA}T10:00:00${desl}`,
  fim:`${AMANHA}T11:00:00${desl}`, status:'confirmado', origem:'recepcao',
  valorPrevisto: 50 });
await d.inserir('agendamento_servicos', { agendamentoId: AG.id, servicoId: SV.id,
  ordem:1, duracaoMin:60, preco:50, comissaoPct:0 });

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
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(500);

const avisoSumido = () => dono.evaluate(() =>
  (document.getElementById('faltandoNaGrade') || {}).textContent || '');

/* ══════════════════════════════════════════════════════════════════════════
   1. DIA NORMAL: NENHUM AVISO
   ══════════════════════════════════════════════════════════════════════════ */
secao('Em dia normal a tela não inventa aviso');

igual('o cartão está na grade',
  await dono.evaluate(() => document.querySelectorAll('.ag').length), 1);
igual('e nenhum aviso de faltando', (await avisoSumido()).trim(), '');

verdade('a versão aparece na lateral',
  await dono.evaluate(() =>
    (document.getElementById('mVersao').textContent || '').trim().length > 0),
  'sem ela não dá para saber se a tela é a de hoje');

/* ══════════════════════════════════════════════════════════════════════════
   2. GRADE QUEBRADA DE PROPÓSITO
   ══════════════════════════════════════════════════════════════════════════ */
secao('Quebrando o desenho, a tela tem que confessar');

/* Some com a coluna do profissional, deixando o agendamento intocado. É
   exatamente a forma do defeito relatado: o contador soma pela agenda do dia,
   o desenho percorre colunas, e a coluna não está lá.

   Note que o teste NÃO reproduz uma causa já corrigida — ele força a
   discordância entre as duas contas, que é a classe inteira. */
await dono.evaluate(() => {
  window.profsDaGrade = () => [];
  // Sem coluna nenhuma o desenho sai cedo, então deixa uma que não atende
  // ninguém: assim a grade existe e mesmo assim o cartão não cabe nela.
  window.profsDaGrade = () => [{ id:'ninguem', nome:'Fantasma', cor:'#888',
                                 ativo:true, jornada:{} }];
  pintar();
});
await dono.waitForTimeout(400);

igual('o cartão sumiu da grade',
  await dono.evaluate(() => document.querySelectorAll('.ag').length), 0);
igual('mas o topo continua contando', await dono.evaluate(() =>
  Number(document.querySelector('#kpisDia .kpi .v').textContent)), 1);

const texto = await avisoSumido();
verdade('e a tela AVISA que um atendimento não coube',
  /não coube|não couberam/.test(texto),
  'era o silêncio que fazia o dono achar que o sistema perdeu o horário: '
  + JSON.stringify(texto));
verdade('dizendo de quem é', /Maria Sumida/.test(texto), JSON.stringify(texto));
verdade('e com o horário', /10:00/.test(texto), JSON.stringify(texto));

verdade('o aviso tem botão para abrir o atendimento',
  await dono.evaluate(() =>
    document.querySelectorAll('#faltandoNaGrade button').length === 1));

await dono.evaluate(() =>
  document.querySelector('#faltandoNaGrade button').click());
await dono.waitForTimeout(400);
verdade('e o botão abre o detalhe de verdade',
  await dono.evaluate(() =>
    document.getElementById('fundo').classList.contains('on')),
  'aviso que não leva a lugar nenhum é um beco sem saída');

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
