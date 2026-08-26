/* ===========================================================================
   AgendaPro — o relatório do mês, do balcão até a tela

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/relatorios.test.mjs

   ── O DEFEITO QUE ESTE ARQUIVO EXISTE PARA NÃO DEIXAR VOLTAR ───────────────
   O `relatorios.test.sql` já confere a conta: ele mesmo insere comandas
   FECHADAS e prova que a soma bate. Passava, e passava certo — e mesmo assim
   o relatório de um salão de verdade voltava ZERADO.

   O motivo estava do lado de cá: a comanda nascia `aberta` e a tela nunca a
   fechava. `receber()` empilhava o pagamento e pronto. O dinheiro estava
   gravado, o mês estava vazio, e nenhum dos dois lados acusava — porque cada
   teste olhava só a sua metade.

   Então aqui não se insere comanda fechada. Aqui se ATENDE: abre a comanda
   pela agenda, registra o pagamento, clica em fechar. E antes disso o
   relatório é conferido ZERADO de propósito — é essa asserção que impede
   este arquivo de aprovar um `fecharComanda()` que não faça nada.
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

/* ── O CENÁRIO, com contas que dá para fazer de cabeça ─────────────────────
   Ana  · corte  100,00 · comissão 40%  →  40,00
   Bia  · mecha  200,00 · comissão 50%  → 100,00
   Faturamento: 300,00 · comissões: 140,00 · ticket médio: 150,00
   Mais um atendimento marcado que a cliente FALTOU, de 80,00 previstos: é
   o que "ficou na mesa", e conta pelo dia do atendimento, não do pagamento.
   ────────────────────────────────────────────────────────────────────────── */
const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`rel-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Dona Rita', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Relatório ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

// Duas profissionais é o mínimo para provar que a comissão sai por PESSOA.
// O trial permite uma; o plano se troca pelo banco, que é o que a assinatura
// de verdade faria.
const pg_ = exigir('./bancada/node_modules/pg');
const banco = new pg_.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(
  `update public.assinaturas set plano='time', status='ativa' where salao_id=$1`,
  [SALAO]);

const ANA = (await d.lista('profissionais', { salaoId: SALAO }))[0];
await d.atualizar('profissionais', ANA.id, { nome:'Ana', comissaoPct: 40 });
const BIA = await d.inserir('profissionais', { salaoId: SALAO, nome:'Bia',
  comissaoPct: 50, ativo:true, aceitaOnline:true, cor:'#7C3AED' });
for(const p of [ANA, BIA])
  for(let i = 0; i <= 6; i++)
    await d.inserir('jornadas', { profissionalId: p.id, diaSemana:i,
                                  inicio:'08:00', fim:'20:00' });

const CORTE = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte',
  duracaoMin:60, intervaloMin:0, preco:100, ativo:true, aceitaOnline:true,
  comissaoPct: 40 });
const MECHA = await d.inserir('servicos', { salaoId: SALAO, nome:'Mecha',
  duracaoMin:60, intervaloMin:0, preco:200, ativo:true, aceitaOnline:true,
  comissaoPct: 50 });

// Hoje, no fuso do salão — é o dia que a tela abre e o período que ela soma.
const HOJE = new Intl.DateTimeFormat('en-CA',
  { timeZone:'America/Sao_Paulo' }).format(new Date());
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(HOJE + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');

const fone = () => '11' + (900000000 + Math.floor(Math.random()*99999999));
const CLI1 = await d.inserir('clientes', { salaoId: SALAO, nome:'Cliente Um',   telefone: fone() });
const CLI2 = await d.inserir('clientes', { salaoId: SALAO, nome:'Cliente Dois', telefone: fone() });
const CLI3 = await d.inserir('clientes', { salaoId: SALAO, nome:'Cliente Três', telefone: fone() });

async function marcar(cli, prof, sv, hora, status, valor){
  const ag = await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cli.id,
    profissionalId: prof.id, inicio:`${HOJE}T${hora}:00:00${desl}`,
    fim:`${HOJE}T${String(Number(hora)+1).padStart(2,'0')}:00:00${desl}`,
    status, origem:'recepcao', valorPrevisto: valor });
  await d.inserir('agendamento_servicos', { agendamentoId: ag.id, servicoId: sv.id,
    ordem:1, duracaoMin:60, preco: valor, comissaoPct: sv.comissaoPct });
  return ag;
}
const AG1 = await marcar(CLI1, ANA, CORTE, '09', 'concluido', 100);
const AG2 = await marcar(CLI2, BIA, MECHA, '11', 'concluido', 200);
await marcar(CLI3, ANA, CORTE, '15', 'faltou', 80);

/* ── O painel ─────────────────────────────────────────────────────────── */
const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();
const erros = [], recados = [];
pg.on('pageerror', e => erros.push(e.message));
pg.on('dialog', async dlg => { recados.push(dlg.message()); await dlg.accept(); });
await pg.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);
await pg.evaluate(dd => { diaAtual = dd; }, HOJE);

const relatorioDoBanco = () => d.chamar('relatorio',
  { p_salao: SALAO, p_de: HOJE, p_ate: HOJE });

/* ══════════════════════════════════════════════════════════════════════════
   1. ANTES DE FECHAR: O MÊS ESTÁ VAZIO — E TEM QUE ESTAR
   Sem esta seção, todo o resto passaria mesmo se `fecharComanda()` fosse uma
   função vazia: bastaria a comanda já nascer contando.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Comanda aberta não é faturamento');

await pg.evaluate(a => comandaDoAgendamento(a), AG1.id);
await pg.waitForTimeout(2500);

const comandas1 = await d.lista('comandas', { salaoId: SALAO });
igual('a comanda foi criada no banco', comandas1.length, 1);
igual('e ela nasce ABERTA', comandas1[0].status, 'aberta');
verdade('sem hora de fechamento', !comandas1[0].fechadaEm,
  JSON.stringify(comandas1[0].fechadaEm));

const antes = await relatorioDoBanco();
igual('o relatório do dia ainda está zerado', Number(antes.faturamento), 0);
igual('sem nenhum atendimento contado', Number(antes.atendimentos), 0);

/* ══════════════════════════════════════════════════════════════════════════
   2. FECHAR A COMANDA — E O QUE IMPEDE DE FECHAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('Fechar exige o pagamento inteiro');

const COM1 = comandas1[0].id;
recados.length = 0;
await pg.evaluate(c => fecharComanda(c), COM1);
await pg.waitForTimeout(1200);

verdade('sem pagamento, a comanda NÃO fecha',
  recados.some(t => /faltam/i.test(t)), JSON.stringify(recados));
igual('e ela continua aberta no banco',
  (await d.lista('comandas', { salaoId: SALAO }))[0].status, 'aberta');

// Paga metade: continua faltando, e continua sem fechar.
await pg.evaluate(c => {
  document.getElementById('cForma').value = 'credito';
  document.getElementById('cValor').value = '50';
  receber(c);
}, COM1);
await pg.waitForTimeout(2000);
recados.length = 0;
await pg.evaluate(c => fecharComanda(c), COM1);
await pg.waitForTimeout(1200);
verdade('paga pela metade, também não fecha',
  recados.some(t => /faltam/i.test(t)), JSON.stringify(recados));

// Paga o resto e fecha.
await pg.evaluate(c => {
  document.getElementById('cForma').value = 'credito';
  document.getElementById('cValor').value = '50';
  receber(c);
}, COM1);
await pg.waitForTimeout(2000);
await pg.evaluate(c => fecharComanda(c), COM1);
await pg.waitForTimeout(2500);

const fechada = (await d.lista('comandas', { salaoId: SALAO }))
  .find(c => c.id === COM1);
igual('paga por inteiro, ela fecha', fechada.status, 'fechada');
verdade('com a hora do fechamento gravada no banco', !!fechada.fechadaEm,
  'sem `fechada_em` o relatório não sabe de que mês é esse dinheiro');

/* ══════════════════════════════════════════════════════════════════════════
   3. COMANDA FECHADA NÃO SE MEXE
   ══════════════════════════════════════════════════════════════════════════ */
secao('Comanda fechada é mês fechado');

recados.length = 0;
await pg.evaluate(c => receber(c), COM1);
await pg.waitForTimeout(800);
verdade('não dá para registrar pagamento nela',
  recados.some(t => /fechada/i.test(t)), JSON.stringify(recados));
recados.length = 0;
await pg.evaluate(c => mudarDesconto(c, 90), COM1);
await pg.waitForTimeout(800);
verdade('nem mudar o desconto',
  recados.some(t => /fechada/i.test(t)), JSON.stringify(recados));
igual('e o total dela no banco continua o mesmo',
  Number((await relatorioDoBanco()).faturamento), 100);

/* ══════════════════════════════════════════════════════════════════════════
   4. A SEGUNDA COMANDA, E A CONTA QUE O DONO FAZ NA CALCULADORA
   ══════════════════════════════════════════════════════════════════════════ */
secao('O período soma');

await pg.evaluate(a => comandaDoAgendamento(a), AG2.id);
await pg.waitForTimeout(2500);
const COM2 = (await d.lista('comandas', { salaoId: SALAO }))
  .find(c => c.id !== COM1).id;
await pg.evaluate(c => {
  document.getElementById('cForma').value = 'pix';
  document.getElementById('cValor').value = '200';
  receber(c);
}, COM2);
await pg.waitForTimeout(2000);
await pg.evaluate(c => fecharComanda(c), COM2);
await pg.waitForTimeout(2500);

const r = await relatorioDoBanco();
igual('faturou 300,00 — o corte mais a mecha', Number(r.faturamento), 300);
igual('em 2 atendimentos', Number(r.atendimentos), 2);
igual('duas pessoas na lista de comissão', r.comissoes.length, 2);
igual('a Bia é a primeira, porque vem em ordem de valor',
  r.comissoes[0].nome, 'Bia');
igual('e ela tem 100,00 a receber (50% de 200)',
  Number(r.comissoes[0].comissao), 100);
igual('a Ana tem 40,00 (40% de 100)', Number(r.comissoes[1].comissao), 40);
igual('a falta conta pelo dia do atendimento', Number(r.agenda.faltas), 1);
igual('e os 80,00 dela ficaram na mesa', Number(r.agenda.perdido), 80);
igual('duas clientes atendidas', Number(r.clientes.atendidas), 2);
igual('e as duas são novas na casa', Number(r.clientes.novas), 2);

/* ══════════════════════════════════════════════════════════════════════════
   5. A TELA MOSTRA O QUE O BANCO SOMOU
   Número certo dentro de um jsonb que ninguém desenha não paga comissão
   nenhuma. Aqui é a tela que é lida, não a resposta da função.
   ══════════════════════════════════════════════════════════════════════════ */
secao('A tela de Relatórios');

await pg.evaluate(() => irPara('relatorios'));
await pg.waitForTimeout(600);
await pg.evaluate(dd => { relDe = dd; relAte = dd; prepararRelatorios(); }, HOJE);
await pg.waitForTimeout(2500);

const texto = await pg.evaluate(() =>
  document.getElementById('relCorpo').textContent.replace(/\s+/g,' '));

verdade('o faturamento do período aparece', /R\$\s*300,00/.test(texto), texto.slice(0,300));
verdade('o ticket médio também', /R\$\s*150,00/.test(texto), texto.slice(0,300));
verdade('a Ana está na lista de comissão', /Ana/.test(texto));
verdade('a Bia também', /Bia/.test(texto));
verdade('com os 100,00 dela', /R\$\s*100,00/.test(texto));
verdade('o total a pagar de comissão fecha em 140,00',
  /R\$\s*140,00/.test(texto), texto.slice(0,600));
verdade('as formas de pagamento aparecem',
  /Crédito/.test(texto) && /Pix/.test(texto), texto.slice(0,600));
verdade('e o que ficou na mesa com a falta', /R\$\s*80,00/.test(texto));

const kpis = await pg.evaluate(() =>
  [...document.querySelectorAll('#relCorpo .kpi')].length);
verdade('a tela tem os indicadores do topo e os da agenda', kpis >= 10, String(kpis));

/* Período onde não houve nada: tem que dizer POR QUE está vazio, e não só
   "sem dados" — que faria o dono achar que o sistema perdeu o mês dele. */
await pg.evaluate(() => {
  relDe = '2020-01-01'; relAte = '2020-01-31'; prepararRelatorios();
});
await pg.waitForTimeout(2000);
verdade('período sem movimento explica que só comanda fechada conta',
  await pg.evaluate(() =>
    /comanda FECHADA/i.test(document.getElementById('relCorpo').textContent)),
  await pg.evaluate(() => document.getElementById('relCorpo').textContent.slice(0,200)));

/* ══════════════════════════════════════════════════════════════════════════
   6. O CAIXA DO DIA E O RELATÓRIO DO DIA TÊM QUE DIZER O MESMO
   Dois faturamentos diferentes na mesma tela é o que faz o dono parar de
   confiar no sistema inteiro — e ele estaria certo.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O Caixa concorda com o Relatório');

await pg.evaluate(() => irPara('caixa'));
await pg.waitForTimeout(1200);
const caixa = await pg.evaluate(() =>
  document.getElementById('kpisCaixa').textContent.replace(/\s+/g,' '));
verdade('o Caixa do dia mostra os mesmos 300,00',
  /R\$\s*300,00/.test(caixa), caixa);
verdade('e mostra o que ainda está em aberto com nome próprio',
  /em aberto/.test(caixa), caixa);

/* ══════════════════════════════════════════════════════════════════════════
   7. AS DUAS CONTAS TÊM QUE DAR O MESMO
   `relatorioLocal()` é a versão da demonstração, escrita em JavaScript, e
   `relatorio()` é a do banco. Existem duas de propósito — a demonstração roda
   sem banco nenhum — e é exatamente por isso que elas divergem calado: quem
   mexe numa não lembra da outra.

   Aqui a página está LIGADA no banco, então dá para pedir as duas sobre os
   MESMOS dados e comparar. É o único jeito de a divergência aparecer no dia
   em que ela nasce, e não meses depois, na demonstração para um cliente.
   ══════════════════════════════════════════════════════════════════════════ */
secao('A conta da demonstração bate com a do banco');

const local = await pg.evaluate(dd => relatorioLocal(dd, dd), HOJE);
const doBanco = await relatorioDoBanco();
const num = v => Math.round(Number(v || 0) * 100) / 100;

for(const campo of ['faturamento','atendimentos','descontos','faturamentoAntes'])
  igual('mesmo ' + campo, num(local[campo]), num(doBanco[campo]));
igual('mesma quantidade de pessoas na comissão',
  local.comissoes.length, doBanco.comissoes.length);
for(let i = 0; i < doBanco.comissoes.length; i++){
  igual(`mesma comissão para ${doBanco.comissoes[i].nome}`,
    num(local.comissoes[i].comissao), num(doBanco.comissoes[i].comissao));
  igual(`e o mesmo vendido`,
    num(local.comissoes[i].vendido), num(doBanco.comissoes[i].vendido));
}
igual('mesmas formas de pagamento',
  local.formas.map(f => f.forma).join(','),
  doBanco.formas.map(f => f.forma).join(','));
for(const campo of ['concluidos','faltas','cancelados','marcados','perdido'])
  igual('mesma agenda: ' + campo, num(local.agenda[campo]), num(doBanco.agenda[campo]));
for(const campo of ['atendidas','novas'])
  igual('mesmas clientes: ' + campo, num(local.clientes[campo]), num(doBanco.clientes[campo]));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
