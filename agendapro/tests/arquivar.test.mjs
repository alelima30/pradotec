/* ===========================================================================
   AgendaPro — arquivar em vez de apagar

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/arquivar.test.mjs

   ── O QUE MUDOU, E POR QUÊ ─────────────────────────────────────────────────
   "Excluir" apagava a linha. Sumia o atendimento, sumiam os serviços dele (o
   banco apaga em cascata) e sumia a comanda — sem lixeira e sem desfazer. Um
   clique errado custava o histórico, e é o histórico que diz quanto o salão
   faturou no mês.

   Agora arquiva: a linha fica, `arquivado_em` recebe a hora, e a tela deixa
   de mostrar. As duas metades dessa promessa são o que esta suíte guarda:

     1. O REGISTRO NÃO PODE SUMIR. Se a linha for apagada, não há desfazer
        possível e o mês perde valor sem ninguém perceber.

     2. O HORÁRIO TEM QUE FICAR LIVRE NA HORA. Arquivar um lançamento errado
        e continuar sem conseguir marcar em cima seria pior que apagar — o
        dono ficaria com uma vaga fantasma que só ele não enxerga. Quem
        garante isso é a trava do BANCO, refeita com `arquivado_em is null`;
        por isso o teste marca de verdade por cima, e não confere só a tela.
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
await d.criarConta({ email:`arq-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Arquivo ' + marca,
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

const CLI = await d.inserir('clientes', { salaoId: SALAO, nome:'Maria Teste',
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
dono.on('dialog', dlg => dlg.accept());          // o dono confirma o arquivamento
await dono.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await dono.goto(BASE + '/app.html');
await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(500);

const cartoes = () => dono.evaluate(() => document.querySelectorAll('.ag').length);
const contador = () => dono.evaluate(() =>
  Number(document.querySelector('#kpisDia .kpi .v').textContent));
const linhasNoBanco = async () =>
  (await d.lista('agendamentos', { salaoId: SALAO })).length;
const servicosNoBanco = async () =>
  (await d.lista('agendamento_servicos', {})).filter(x => x.agendamentoId === AG.id).length;

/* ══════════════════════════════════════════════════════════════════════════
   1. ANTES
   ══════════════════════════════════════════════════════════════════════════ */
secao('O atendimento está na agenda');
igual('um cartão na grade', await cartoes(), 1);
igual('e o topo conta um', await contador(), 1);

/* ══════════════════════════════════════════════════════════════════════════
   2. ARQUIVAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('Arquivar tira da vista e NÃO apaga');

await dono.evaluate(i => excluirAgendamento(i), AG.id);
await dono.waitForTimeout(2500);

igual('saiu da grade', await cartoes(), 0);
igual('e o topo deixou de contar', await contador(), 0);
igual('mas a linha continua no banco', await linhasNoBanco(), 1);
igual('e os serviços dela também', await servicosNoBanco(), 1);

const noBanco = (await d.lista('agendamentos', { salaoId: SALAO }))[0];
verdade('com a hora do arquivamento gravada', !!noBanco.arquivadoEm,
  JSON.stringify(noBanco.arquivadoEm));
igual('sem mexer no status', noBanco.status, 'confirmado');

verdade('e o dono tem um botão de desfazer na tela',
  await dono.evaluate(() => !!document.getElementById('recadoDesfazer')),
  'sem tela de arquivados, aviso sem desfazer é um beco sem saída');

/* ══════════════════════════════════════════════════════════════════════════
   3. O HORÁRIO TEM QUE FICAR LIVRE — QUEM DIZ ISSO É O BANCO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A vaga volta a ficar livre na hora');

const outra = await d.inserir('clientes', { salaoId: SALAO, nome:'Outra',
  telefone: '11' + (800000000 + Math.floor(Math.random()*99999999)) });
let deu = null;
try {
  await d.inserir('agendamentos', { salaoId: SALAO, clienteId: outra.id,
    profissionalId: PROF.id, inicio:`${AMANHA}T10:00:00${desl}`,
    fim:`${AMANHA}T11:00:00${desl}`, status:'confirmado', origem:'recepcao',
    valorPrevisto: 50 });
} catch(e){ deu = e.message; }
verdade('outra cliente consegue marcar no mesmo horário', deu === null,
  'a trava do banco continua segurando a vaga do arquivado: ' + deu);

/* ══════════════════════════════════════════════════════════════════════════
   4. DESFAZER, QUANDO DÁ E QUANDO NÃO DÁ
   ══════════════════════════════════════════════════════════════════════════ */
secao('Desfazer avisa quando a vaga já foi tomada');

await dono.reload(); await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(500);

const recados = [];
dono.removeAllListeners('dialog');
dono.on('dialog', async dlg => { recados.push(dlg.message()); await dlg.accept(); });

await dono.evaluate(i => desarquivarAgendamento(i), AG.id);
await dono.waitForTimeout(1500);

igual('o horário ocupado continua com uma pessoa só', await cartoes(), 1);
verdade('e o dono é avisado do porquê',
  recados.some(t => /já foi ocupado/.test(t)), JSON.stringify(recados));

// Libera a vaga e tenta de novo.
await dono.evaluate(() => {
  const outro = bd.agendamentos.find(a => !a.arquivadoEm);
  outro.arquivadoEm = new Date().toISOString();
  salvar();
});
await dono.waitForTimeout(2000);
recados.length = 0;
await dono.evaluate(i => desarquivarAgendamento(i), AG.id);
await dono.waitForTimeout(2000);

igual('com a vaga livre, o desfazer traz o atendimento de volta', await cartoes(), 1);
const voltou = (await d.lista('agendamentos', { salaoId: SALAO }))
  .find(a => a.id === AG.id);
verdade('e o banco também esqueceu o arquivamento', !voltou.arquivadoEm,
  JSON.stringify(voltou.arquivadoEm));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
