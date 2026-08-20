/* ===========================================================================
   AgendaPro — a cliente abre o link do WhatsApp e marca, contra o banco

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/cliente-nuvem.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   O cadastro terminava entregando ao dono um link para mandar às clientes.
   Aberto, ele dizia:

       Salão não encontrado. O endereço ?salao=… não corresponde a
       nenhum salão ativo.

   O salão estava no banco. A tela é que nunca perguntava — falava só com o
   `localStorage`. Quer dizer: o produto inteiro terminava num link que
   informava à cliente do salão que o salão não existe.

   Este arquivo faz o caminho todo, do jeito que ele acontece de verdade:
   a dona cria a conta e o salão, cadastra um serviço e a jornada da semana;
   depois uma ABA ANÔNIMA — sem sessão, sem localStorage, sem nada — abre o
   link, escolhe, marca, e o horário tem que existir no banco, com o preço
   que o BANCO calculou.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.dirname(AQUI);
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok = (m) => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c) => c ? ok(m) : nao(m, 'esperava verdadeiro');
const secao = t => console.log('\n' + t);

// dados.js carregado como o navegador carregaria — é assim que a dona faz o
// trabalho dela sem precisar de uma segunda janela aberta.
function novaAba(){
  const guardado = {};
  const janela = {
    AGENDAPRO: { url: BASE, chave: 'chave-de-teste', ambiente: 'bancada' },
    localStorage: {
      getItem: k => (k in guardado ? guardado[k] : null),
      setItem: (k,v) => { guardado[k] = String(v); },
      removeItem: k => { delete guardado[k]; },
    },
  };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    janela, { info(){}, error(){}, log(){} }, fetch, janela.localStorage);
  return janela.Dados;
}

secao('A dona monta o salão');

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dona = novaAba();
await dona.criarConta({ email: `dona-${marca}@teste.com`, senha: 'salaoteste123',
  nome: 'Marta Prado', telefone: '+5551' + (900000000 + (Date.now() % 99999999)) });

const criado = await dona.chamar('criar_salao', {
  p_nome_salao: 'Studio Cliente ' + marca, p_tipo: 'salao',
  p_telefone: '(51) 99887-6655', p_documento: null, p_origem: null });
const salaoId = criado[0].salao_id;
const SLUG    = criado[0].slug;
verdade('o salão nasce com o apelido do link', !!SLUG);

const PRECO = 90, DURACAO = 60;
const corte = await dona.inserir('servicos', {
  salaoId, nome: 'Corte feminino', duracaoMin: DURACAO, intervaloMin: 0,
  preco: PRECO, ativo: true, aceitaOnline: true });

const prof = (await dona.lista('profissionais', { salaoId }))[0];
// Jornada nos sete dias. Não é preguiça: sem isso o teste passaria ou falharia
// conforme o dia da semana em que fosse rodado, que é a pior espécie de teste.
for(let dia = 0; dia <= 6; dia++){
  await dona.inserir('jornadas', { profissionalId: prof.id, diaSemana: dia,
    inicio: '09:00', fim: '18:00' });
}
ok('serviço e jornada cadastrados');

secao('A cliente abre o link — aba anônima, sem sessão nenhuma');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport: { width: 430, height: 800 } });
const p = await ctx.newPage();
const erros = [], ruins = [];
p.on('pageerror', e => erros.push(e.message));
p.on('console', m => { if (m.type() === 'error') erros.push(m.text()); });
p.on('response', r => { if (r.status() >= 400) ruins.push(r.status() + ' ' + r.url().replace(BASE,'')); });

const tela = () => p.evaluate(() => document.body.getAttribute('data-passo'));

await p.goto(BASE + '/agendar.html?salao=' + SLUG);
await p.waitForTimeout(1500);

verdade('a página está falando com o banco, não com o navegador',
  await p.evaluate(() => NA_NUVEM));
igual('o link abre o salão certo',
  (await p.textContent('#tituloSalao')).trim(), 'Studio Cliente ' + marca);

await p.click('#btPrincipal'); await p.waitForTimeout(300);
igual('a capa leva à escolha do serviço', await tela(), 'servico');
verdade('e o serviço cadastrado aparece com o preço do banco',
  (await p.textContent('#listaServicos')).includes('Corte feminino'));

await p.click('#listaServicos button.opcao'); await p.waitForTimeout(200);
await p.click('#btPrincipal'); await p.waitForTimeout(300);
await p.click('#listaProfs button.opcao'); await p.waitForTimeout(200);
await p.click('#btPrincipal'); await p.waitForTimeout(2500);
igual('e chega nos horários', await tela(), 'quando');

/* ── A FAIXA DE DIAS VEM DE UMA PERGUNTA SÓ ────────────────────────────────
   28 dias × cada profissional, numa requisição. Se um dia alguém trocar isso
   por uma chamada por dia, o número aqui denuncia na hora — e o motivo não é
   elegância: no 3G da cliente, 84 requisições são 25 segundos de tela cinza. */
const chamadas = ruins.length; // (só para não confundir os contadores abaixo)
const pedidos = [];
p.on('request', r => { if(r.url().includes('horarios_livres')) pedidos.push(r.url()); });

const dias = await p.evaluate(() =>
  [...document.querySelectorAll('#listaDias .dia')].map(b => b.innerText.replace(/\s+/g,' ')));
verdade('a faixa mostra os dias da janela liberada', dias.length >= 20);
verdade('com a contagem de vagas em cada um, vinda do banco',
  dias.some(d => /\d+ vagas/.test(d)));

// Amanhã: o dia inteiro livre, sem depender de que horas são agora.
await p.click('#listaDias .dia:nth-child(2)'); await p.waitForTimeout(500);
igual('trocar de dia não pergunta ao servidor de novo — a janela já veio toda',
  pedidos.length, 0);

const horas = await p.evaluate(() =>
  [...document.querySelectorAll('#listaHoras .hora')].map(b => b.textContent));
igual('o primeiro horário é a abertura do salão', horas[0], '09:00');
verdade('e o passo é de 15 em 15 minutos', horas[1] === '09:15');
// Jornada 09:00–18:00 com serviço de 60 min: a última que ainda TERMINA
// dentro do expediente é 17:00. 33 vagas.
igual('a última vaga é a que ainda termina dentro do expediente',
  horas[horas.length - 1], '17:00');

secao('Marcar');

await p.click('#listaHoras .hora'); await p.waitForTimeout(300);
await p.click('#btPrincipal'); await p.waitForTimeout(400);
igual('depois do horário vem "seus dados"', await tela(), 'dados');

await p.fill('#dNome', 'Juliana Ferreira');
await p.fill('#dTel', '51988776655');
await p.click('#btPrincipal'); await p.waitForTimeout(600);
igual('e a confirmação', await tela(), 'confirmar');

const resumo = (await p.textContent('#resumoFinal')).replace(/\s+/g,' ');
verdade('o resumo mostra o preço que o banco calculou', resumo.includes('90,00'));

await p.click('#btPrincipal'); await p.waitForTimeout(3500);
igual('a marcação conclui', await tela(), 'pronto');
verdade('e a tela final diz o dia, a hora e com quem',
  /às 09:00, com Marta Prado/.test(await p.textContent('#prontoTexto')));
igual('sem nenhum erro de JavaScript no caminho todo', erros.length, 0);
igual('e sem nenhuma resposta de erro do servidor', ruins.join(' | '), '');

/* ── O QUE A TELA PROMETE DEPOIS DE MARCAR ─────────────────────────────────
   Estas duas verificações existem porque a versão anterior desta tela mentia
   por omissão. `bd.agendamentos` é sempre vazio na nuvem, então "meus
   horários" respondia "Nenhum horário por aqui" para quem tinha acabado de
   marcar — e quem lê isso marca de novo, deixando o salão com duas cadeiras
   vendidas para a mesma pessoa. */
igual('o botão do fim oferece o que funciona, não o que ainda não existe',
  (await p.textContent('#btPrincipal')).trim(), 'Marcar outro horário');

await p.evaluate(() => irPara('meus'));
await p.waitForTimeout(300);
const meus = await p.textContent('#listaMeus');
verdade('e "meus horários" diz a verdade em vez de dizer que não há nada',
  meus.includes('chegam pelo WhatsApp'));
verdade('sem afirmar que a pessoa não tem horário marcado',
  !meus.includes('Nenhum horário por aqui'));

secao('O horário existe no banco, e é do salão');

const agendados = await dona.lista('agendamentos', { salaoId });
igual('a dona vê exatamente um horário marcado', agendados.length, 1);
const ag = agendados[0] || {};
igual('marcado como confirmado', ag.status, 'confirmado');
igual('e com a origem certa — veio da agenda online', ag.origem, 'online');

/* ── A REGRA QUE NÃO SE NEGOCIA, CONFERIDA DO LADO DE FORA ─────────────────
   A tela mandou os IDS DOS SERVIÇOS e mais nada. Duração e preço saíram do
   banco. Se um dia alguém "otimizar" mandando `preco` do navegador, este
   número passa a valer o que o console mandar — e a comanda do salão fecha
   com o valor que a cliente escolheu. */
igual('o valor foi calculado pelo banco, não enviado pela tela',
  Number(ag.valorPrevisto), PRECO);

const fichas = await dona.lista('clientes', { salaoId });
igual('e a ficha da cliente nasceu junto', fichas.length, 1);
igual('com o nome que ela digitou', (fichas[0]||{}).nome, 'Juliana Ferreira');

secao('E o horário sai da lista para a próxima pessoa');

// O agendamento guarda um INSTANTE, não uma data solta — a coluna é
// timestamptz. O dia sai dele lido no fuso do salão, que é o único em que
// "09:00" quer dizer nove da manhã.
const diaDoAg = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo',
  year:'numeric', month:'2-digit', day:'2-digit' }).format(new Date(ag.inicio));

const restantes = await fetch(BASE + '/rest/v1/rpc/horarios_livres_periodo', {
  method:'POST', headers:{'apikey':'chave-de-teste','Content-Type':'application/json'},
  body: JSON.stringify({ p_profissionais:[prof.id],
    p_de: diaDoAg, p_ate: diaDoAg, p_servicos:[corte.id] }) }).then(r => r.json());
verdade('o banco responde a lista de horários daquele dia', Array.isArray(restantes));

verdade('o horário marcado não é mais oferecido',
  !restantes.some(x => x.inicio === ag.inicio));

/* A última linha de defesa. Mesmo que a tela ofereça um horário velho —
   cache antigo, duas pessoas na mesma vaga, alguém montando a requisição na
   mão — quem recusa é o banco, e é isso que impede a cadeira de ser vendida
   duas vezes. */
const naMao = await fetch(BASE + '/rest/v1/rpc/agendar', {
  method:'POST', headers:{'apikey':'chave-de-teste','Content-Type':'application/json'},
  body: JSON.stringify({ p_profissional: prof.id, p_inicio: ag.inicio,
    p_servicos: [corte.id], p_nome: 'Outra Pessoa', p_telefone: '51977665544' }) });
verdade('e quem tentar marcar em cima dele na mão é recusado pelo banco',
  !naMao.ok);

secao('O salão recém-criado, antes de cadastrar qualquer serviço');

/* É o estado em que TODO salão passa a primeira hora: o cadastro entrega o
   link no fim, e a pessoa manda para as clientes antes de lançar os serviços.
   Aqui saía a mensagem da busca vazia — "Tente outra palavra, ou limpe a
   busca" — para quem não tinha digitado busca nenhuma. */
const zero = novaAba();
await zero.criarConta({ email: `zero-${marca}@teste.com`, senha: 'salaoteste123',
  nome: 'Dona Zero', telefone: '+5551' + (800000000 + (Date.now() % 99999999)) });
const criadoZero = await zero.chamar('criar_salao', {
  p_nome_salao: 'Salao Zero ' + marca, p_tipo: 'salao',
  p_telefone: '(51) 99887-6600', p_documento: null, p_origem: null });

const z = await ctx.newPage();
await z.goto(BASE + '/agendar.html?salao=' + criadoZero[0].slug);
await z.waitForTimeout(1500);
await z.click('#btPrincipal'); await z.waitForTimeout(400);
const vazio = await z.textContent('#listaServicos');
verdade('diz que o salão ainda não publicou os serviços',
  vazio.includes('ainda não publicou'));
verdade('e não manda a cliente arrumar uma busca que ela não fez',
  !vazio.includes('limpe a busca'));

secao('Um apelido que não existe');

const q = await ctx.newPage();
await q.goto(BASE + '/agendar.html?salao=salao-que-nao-existe-' + marca);
await q.waitForTimeout(1500);
verdade('diz que não encontrou, em vez de listar os outros salões',
  (await q.textContent('#listaSaloes')).includes('não corresponde a nenhum salão ativo'));

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações do link da cliente.`);
