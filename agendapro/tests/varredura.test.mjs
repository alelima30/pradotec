/* ===========================================================================
   AgendaPro — varredura das duas áreas, tela por tela

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/varredura.test.mjs

   As outras suítes olham um assunto de cada vez: a agenda, a segurança, a
   aparência. Esta faz o contrário — passa por TODAS as telas do dono e da
   cliente fazendo o que uma pessoa faria, e reprova ao primeiro erro de
   JavaScript, campo que não grava, lista que não atualiza ou botão que não
   responde.

   É a suíte que pega o defeito que ninguém procurou: o que aparece quando se
   abre a comanda depois de mudar de dia, quando se apaga o serviço que está
   dentro de um agendamento, quando o salão não tem nada cadastrado ainda.
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
await d.criarConta({ email:`var-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Varredura ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();

/* Todo erro conta: os que estouram na página e os que só sussurram no
   console. Muito defeito de tela vive inteiro dentro de um console.error que
   ninguém abre. */
const erros = [];
pg.on('pageerror', e => erros.push('pageerror: ' + e.message));
pg.on('console', m => {
  if(m.type() !== 'error') return;
  const t = m.text();
  // A bancada devolve 400 de propósito em alguns testes de recusa; o que
  // interessa aqui é erro de código, não recusa esperada do banco.
  if(/Failed to load resource/.test(t)) return;
  erros.push('console: ' + t.slice(0, 160));
});
const semErro = (onde) => {
  if(!erros.length){ ok(onde + ': sem erro de JavaScript'); return; }
  nao(onde + ': sem erro de JavaScript', erros.join('\n      '));
  erros.length = 0;
};

await pg.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);

const ir = async (k) => { await pg.evaluate(x => irPara(x), k); await pg.waitForTimeout(900); };
const fechar = async () => { await pg.evaluate(() => fecharModal()); await pg.waitForTimeout(400); };
const salvouSemErro = async () => { await pg.waitForTimeout(2200); };

/* ══════════════════════════════════════════════════════════════════════════
   ÁREA DO SALÃO — cada tela, com o salão ainda VAZIO

   O salão recém-criado não tem serviço, não tem cliente, não tem jornada. É
   o estado em que todo dono vê o sistema pela primeira vez, e é onde a tela
   costuma quebrar por assumir que alguma lista tem pelo menos um item.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Salão vazio: todas as telas abrem');

for(const [chave, rotulo] of [['agenda','Agenda'], ['caixa','Caixa'],
    ['clientes','Clientes'], ['servicos','Serviços'], ['equipe','Equipe'],
    ['salao','Meu salão'], ['publico','Ver como cliente'], ['plano','Plano']]){
  await ir(chave);
  const viva = await pg.evaluate(k => {
    const s = document.getElementById('t-' + k) || document.querySelector('.tela.on');
    return !!s && s.offsetParent !== null;
  }, chave);
  verdade(rotulo + ' abre sem quebrar', viva);
}
semErro('salão vazio');

/* ══════════════════════════════════════════════════════════════════════════
   CADASTROS — criar, editar, desativar, pelo caminho da tela
   ══════════════════════════════════════════════════════════════════════════ */
secao('Cadastrar serviço pela tela');

await ir('servicos');
await pg.evaluate(() => abrirServico());
await pg.waitForTimeout(600);
await pg.fill('#sNome', 'Corte Feminino');
await pg.fill('#sDur', '45');
await pg.fill('#sPreco', '90');
await pg.evaluate(() => salvarServico());
await salvouSemErro();

const svs = await d.lista('servicos', { salaoId: SALAO });
igual('o serviço foi para o banco', svs.length, 1);
igual('com a duração digitada', svs[0] && Number(svs[0].duracaoMin), 45);
igual('e com o preço digitado', svs[0] && Number(svs[0].preco), 90);
verdade('e aparece na lista da tela',
  await pg.evaluate(() => /Corte Feminino/.test(document.body.textContent)));

// Editar o que acabou de criar.
await pg.evaluate(id => abrirServico(id), svs[0].id);
await pg.waitForTimeout(600);
const veioPreenchido = await pg.evaluate(() => ({
  nome: document.getElementById('sNome').value,
  dur:  document.getElementById('sDur').value,
}));
igual('reabrir traz o nome preenchido', veioPreenchido.nome, 'Corte Feminino');
igual('e a duração', veioPreenchido.dur, '45');
await pg.fill('#sPreco', '110');
// `salvarServico(id)` — sem o id ele cunha um novo e cria um SEGUNDO serviço.
await pg.evaluate(id => salvarServico(id), svs[0].id);
await salvouSemErro();
igual('a alteração de preço gravou',
  Number((await d.lista('servicos', { salaoId: SALAO }))[0].preco), 110);
semErro('serviços');

secao('Cadastrar cliente pela tela');
await ir('clientes');
await pg.evaluate(() => abrirCliente());
await pg.waitForTimeout(600);
await pg.fill('#kNome', 'Cliente da Recepção');
await pg.fill('#kTel', '(11) 98888-7777');
await pg.fill('#kObs', 'Alergia a amônia');
await pg.evaluate(() => salvarCliente());
await salvouSemErro();

const cls = await d.lista('clientes', { salaoId: SALAO });
igual('a ficha foi para o banco', cls.length, 1);
igual('com o nome', cls[0] && cls[0].nome, 'Cliente da Recepção');
/* ⚠ O TELEFONE VAI SÓ EM DÍGITOS — foi bug medido, não zelo.
   Guardado "(11) 98888-7777", a mesma pessoa marcando pelo link (onde o
   banco procura por dígitos) virava uma SEGUNDA ficha, e o histórico dela
   rachava ao meio. */
verdade('com o telefone só em dígitos, como o banco espera',
  cls[0] && /^\d{10,13}$/.test(String(cls[0].telefone || '')),
  JSON.stringify(cls[0] && cls[0].telefone));
igual('e com a observação', cls[0] && cls[0].obs, 'Alergia a amônia');
semErro('clientes');

secao('Cliente sem telefone, e a mesma pessoa em dois caminhos');

/* ⚠ O SEGUNDO CLIENTE SEM TELEFONE NÃO GRAVAVA.
   Campo vazio virava string vazia, que NÃO é nula — e a trava do banco é
   `where telefone is not null`. A recepção levava "duplicate key value
   violates unique constraint ux_cli_tel" na cara, em inglês, ao cadastrar a
   segunda pessoa que passou sem deixar número. Em salão isso é rotina. */
for(const quem of ['Passante Um', 'Passante Dois']){
  await pg.evaluate(() => abrirCliente());
  await pg.waitForTimeout(500);
  await pg.fill('#kNome', quem);
  await pg.fill('#kTel', '');
  await pg.evaluate(() => salvarCliente(null));
  await salvouSemErro();
}
const semTel = (await d.lista('clientes', { salaoId: SALAO }))
  .filter(c => /Passante/.test(c.nome));
igual('duas pessoas sem telefone são cadastradas sem brigar', semTel.length, 2);
verdade('e o telefone vazio virou NULO, não texto vazio',
  semTel.every(c => c.telefone === null || c.telefone === undefined),
  JSON.stringify(semTel.map(c => c.telefone)));

/* E a mesma pessoa, cadastrada na recepção e marcando pelo link, tem de cair
   numa ficha só. */
await pg.evaluate(() => abrirCliente());
await pg.waitForTimeout(500);
await pg.fill('#kNome', 'Maria das Duas Portas');
await pg.fill('#kTel', '(11) 97777-6666');
await pg.evaluate(() => salvarCliente(null));
await salvouSemErro();
{
  const antes = (await d.lista('clientes', { salaoId: SALAO }))
    .filter(c => String(c.telefone || '') === '11977776666').length;
  igual('a recepção gravou a ficha em dígitos', antes, 1);
}

secao('Jornada da equipe pela tela');
await ir('equipe');
await pg.evaluate(id => abrirProf(id), PROF.id);
await pg.waitForTimeout(700);
const temJornada = await pg.evaluate(() =>
  document.querySelectorAll('#modalCorpo input[type=time]').length > 0);
verdade('a janela da equipe traz as faixas de horário', temJornada);
await fechar();
semErro('equipe');

/* ══════════════════════════════════════════════════════════════════════════
   A AGENDA — marcar pela recepção, com o salão já povoado
   ══════════════════════════════════════════════════════════════════════════ */
secao('Marcar pela recepção');

// Jornada, senão não há horário nenhum para oferecer.
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
await pg.reload();
await pg.waitForTimeout(3500);
erros.length = 0;

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
await pg.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pg.waitForTimeout(800);

await pg.evaluate(p => abrirNovo(p, 600), PROF.id);   // 10:00
await pg.waitForTimeout(800);
const janelaNovo = await pg.evaluate(() => ({
  temCliente: !!document.getElementById('fCliente'),
  temProf: !!document.getElementById('fProf'),
  temServico: document.querySelectorAll('#modalCorpo input[type=checkbox]').length > 0,
}));
verdade('a janela de novo agendamento traz cliente, quem atende e os serviços',
  janelaNovo.temCliente && janelaNovo.temProf && janelaNovo.temServico,
  JSON.stringify(janelaNovo));
await fechar();
semErro('novo agendamento');

/* ══════════════════════════════════════════════════════════════════════════
   O CAIXA — o caminho que já quebrou uma vez
   ══════════════════════════════════════════════════════════════════════════ */
secao('Comanda: abrir, lançar, descontar, receber');

// Um atendimento para a comanda nascer de.
const sv1 = (await d.lista('servicos', { salaoId: SALAO }))[0];
const cli1 = (await d.lista('clientes', { salaoId: SALAO }))[0];
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');
const ag = await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cli1.id,
  profissionalId: PROF.id, inicio:`${AMANHA}T09:00:00${desl}`,
  fim:`${AMANHA}T09:45:00${desl}`, status:'confirmado', origem:'recepcao',
  valorPrevisto: 110 });
await d.inserir('agendamento_servicos', { agendamentoId: ag.id, servicoId: sv1.id,
  ordem:1, duracaoMin:45, preco:110, comissaoPct:0 });

await pg.reload();
await pg.waitForTimeout(3500);
erros.length = 0;
await pg.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pg.waitForTimeout(800);

await pg.evaluate(id => comandaDoAgendamento(id), ag.id);
await pg.waitForTimeout(1200);
verdade('a comanda abre a partir do atendimento',
  await pg.evaluate(() => /Comanda/.test(
    document.getElementById('modalTitulo').textContent)));
verdade('já com o serviço lançado dentro dela',
  await pg.evaluate(() => /Corte Feminino/.test(
    document.getElementById('modalCorpo').textContent)));
await fechar();
await salvouSemErro();

/* ── O DEFEITO QUE JÁ ACONTECEU: a agenda sumia depois da comanda ─────────
   Abrir a comanda, salvar, e trocar de dia deixava a grade vazia. A tela
   guardava os dados na forma do banco e não sabia mais lê-los. Está
   consertado, e fica vigiado daqui. */
await pg.evaluate(() => mudarDia(1));
await pg.waitForTimeout(700);
await pg.evaluate(() => mudarDia(-1));
await pg.waitForTimeout(900);
igual('depois de abrir a comanda e trocar de dia, a agenda continua desenhada',
  await pg.evaluate(() => document.querySelectorAll('.ag').length), 1);
semErro('caixa');

/* ══════════════════════════════════════════════════════════════════════════
   MEU SALÃO — os campos que a cliente vê
   ══════════════════════════════════════════════════════════════════════════ */
secao('Meu salão: endereço e identidade');

await ir('salao');
await pg.fill('#cNome', 'Salão Varredura Editado');
await pg.fill('#cRua', 'Rua Avanhandava');
await pg.fill('#cNum', '10');
await pg.fill('#cBairro', 'Cidade Nova');
await pg.fill('#cCidade', 'Itu');
await pg.evaluate(() => salvarCadastroSalao());
await salvouSemErro();

const sl = (await d.lista('saloes', { id: SALAO }))[0];
igual('o nome do salão gravou', sl.nome, 'Salão Varredura Editado');
const end = sl.endereco || {};
igual('a rua gravou', end.logradouro, 'Rua Avanhandava');
igual('o número gravou', end.numero, '10');
igual('a cidade gravou', end.cidade, 'Itu');
semErro('meu salão');

/* ══════════════════════════════════════════════════════════════════════════
   ÁREA DA CLIENTE
   ══════════════════════════════════════════════════════════════════════════ */
secao('Área da cliente: o link do salão');

const cel = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
const cli = await cel.newPage();
const errosCli = [];
cli.on('pageerror', e => errosCli.push('pageerror: ' + e.message));
cli.on('console', m => { if(m.type() === 'error'
  && !/Failed to load resource/.test(m.text()))
  errosCli.push('console: ' + m.text().slice(0,160)); });
await cli.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
await cli.goto(BASE + '/agendar.html?salao=' + SLUG);
await cli.waitForTimeout(2800);

verdade('a capa abre com o nome novo do salão',
  await cli.evaluate(() => /Varredura Editado/.test(document.body.textContent)));
verdade('e mostra o endereço que o dono acabou de cadastrar',
  await cli.evaluate(() => /Avanhandava/.test(document.body.textContent)));

await cli.click('.boas-cta');
await cli.waitForTimeout(1200);
verdade('a lista de serviços traz o que o dono cadastrou',
  await cli.evaluate(() => /Corte Feminino/.test(document.body.textContent)));
verdade('com o preço que ele definiu',
  await cli.evaluate(() => /110/.test(document.body.textContent)),
  'o preço mudou de 90 para 110 e a vitrine tem que acompanhar');

igual('sem erro de JavaScript na área da cliente',
  errosCli.length ? errosCli.join(' | ') : 0, 0);

secao('Área da cliente: salão que não existe');
{
  const p = await cel.newPage();
  const e2 = [];
  p.on('pageerror', x => e2.push(x.message));
  await p.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
  await p.goto(BASE + '/agendar.html?salao=nao-existe-mesmo-' + marca);
  await p.waitForTimeout(2500);
  verdade('explica que não achou, em vez de ficar em branco',
    await p.evaluate(() => /não encontrado/i.test(document.body.textContent)));
  igual('e sem erro de JavaScript', e2.length ? e2.join(' | ') : 0, 0);
  await p.close();
}

secao('Área da cliente: salão sem serviço nenhum');
{
  const outra = novaAba();
  await outra.criarConta({ email:`vaz-${marca}@teste.com`, senha:'minhasenhaboa',
    nome:'Dono Vazio', telefone:'+5521' + (100000000 + (Date.now() % 89999999)) });
  const c2 = await outra.chamar('criar_salao', { p_nome_salao:'Salão Sem Nada ' + marca,
    p_tipo:'salao', p_telefone:'(21) 4444-5555', p_documento:null, p_origem:null });

  const p = await cel.newPage();
  const e3 = [];
  p.on('pageerror', x => e3.push(x.message));
  await p.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
  await p.goto(BASE + '/agendar.html?salao=' + c2[0].slug);
  await p.waitForTimeout(2800);
  verdade('a capa abre mesmo sem serviço cadastrado',
    await p.evaluate(() => !!document.querySelector('.boas-cta')));
  await p.click('.boas-cta');
  await p.waitForTimeout(1200);
  verdade('e explica que a agenda ainda não abriu, sem tela quebrada',
    await p.evaluate(() => /ainda não publicou|não faz|sem serviço/i
      .test(document.body.textContent)),
    await p.evaluate(() => document.body.textContent.replace(/\s+/g,' ').slice(0,150)));
  igual('sem erro de JavaScript', e3.length ? e3.join(' | ') : 0, 0);
  await p.close();
}


/* ══════════════════════════════════════════════════════════════════════════
   O DINHEIRO — lançar, descontar, receber

   É o trecho onde o erro não aparece na tela: fecha a comanda com o valor
   errado e ninguém percebe até o fim do mês.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Comanda: a conta tem que fechar');

await ir('caixa');
const cmd = (await d.lista('comandas', { salaoId: SALAO }))[0];
verdade('a comanda aberta aparece no caixa', !!cmd);

if(cmd){
  await pg.evaluate(id => abrirComanda(id), cmd.id);
  await pg.waitForTimeout(900);

  // Um desconto de 10 sobre o serviço de 110.
  await pg.evaluate(id => mudarDesconto(id, '10'), cmd.id);
  await pg.waitForTimeout(1800);
  const comDesconto = (await d.lista('comandas', { salaoId: SALAO }))
    .find(c => c.id === cmd.id);
  igual('o desconto gravou', Number(comDesconto && comDesconto.desconto), 10);

  await pg.evaluate(id => abrirComanda(id), cmd.id);
  await pg.waitForTimeout(900);
  const naTela = await pg.evaluate(() =>
    document.getElementById('modalCorpo').textContent.replace(/\s+/g, ' '));
  verdade('e a tela mostra o total já com o desconto (110 − 10 = 100)',
    /100,00/.test(naTela), naTela.slice(0, 200));
  await fechar();
  await salvouSemErro();
}
semErro('comanda');

/* ══════════════════════════════════════════════════════════════════════════
   APAGAR O QUE ESTÁ EM USO

   O serviço que já foi vendido e o profissional que já atendeu não podem
   sumir do banco levando o histórico junto. Aqui o teste confere que o
   sistema PROTEGE isso — e que a recusa chega como frase, não como erro de
   banco em inglês.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Serviço e profissional que já foram usados');

{
  const sv = (await d.lista('servicos', { salaoId: SALAO }))[0];
  let recusou = false, mensagem = '';
  try{ await d.apagar('servicos', sv.id); }
  catch(e){ recusou = true; mensagem = e.message; }
  verdade('o banco não deixa apagar serviço que já está num atendimento',
    recusou, 'apagar levaria junto o histórico do que foi vendido');

  // E o caminho que o dono DEVE usar continua funcionando: desativar.
  await d.atualizar('servicos', sv.id, { ativo: false });
  const depois = (await d.lista('servicos', { salaoId: SALAO })).find(x => x.id === sv.id);
  igual('mas desativar funciona, que é o caminho certo', depois && depois.ativo, false);
  await d.atualizar('servicos', sv.id, { ativo: true });
}

{
  let recusou = false;
  try{ await d.apagar('profissionais', PROF.id); }
  catch(e){ recusou = true; }
  verdade('nem apagar quem já atendeu', recusou);
}

/* ══════════════════════════════════════════════════════════════════════════
   BLOQUEIO DE HORÁRIO PELO PAINEL
   ══════════════════════════════════════════════════════════════════════════ */
secao('Bloquear e liberar horário');

await ir('agenda');
await pg.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pg.waitForTimeout(700);
await pg.evaluate(p => abrirBloqueio(p), PROF.id);
await pg.waitForTimeout(700);
const temBloqueio = await pg.evaluate(() =>
  !!document.getElementById('bIni') || !!document.getElementById('bMotivo')
  || document.querySelectorAll('#modalCorpo input').length > 0);
verdade('a janela de bloqueio abre com campos', temBloqueio);
await fechar();
semErro('bloqueio');

/* ══════════════════════════════════════════════════════════════════════════
   ÁREA DA CLIENTE — a lista de espera, quando o dia está cheio
   ══════════════════════════════════════════════════════════════════════════ */
secao('Área da cliente: lista de espera');
{
  const p = await cel.newPage();
  const e4 = [];
  p.on('pageerror', x => e4.push(x.message));
  await p.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
  await p.goto(BASE + '/agendar.html?salao=' + SLUG);
  await p.waitForTimeout(2800);
  const temFila = await p.evaluate(() => typeof entrarNaFila === 'function'
                                      || !!document.getElementById('p-fila'));
  verdade('a lista de espera existe na tela da cliente', temFila);
  igual('e a tela abre sem erro', e4.length ? e4.join(' | ') : 0, 0);
  await p.close();
}

await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de varredura.`);
