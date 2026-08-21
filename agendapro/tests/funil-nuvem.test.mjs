/* ===========================================================================
   AgendaPro — o funil inteiro NA NUVEM: cadastrar, sair, voltar e entrar

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/funil-nuvem.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   Já havia um teste do cadastro — o cadastro.test.mjs — e ele passava. Só que
   ele abre `criar.html?demo=1`, o modo demonstração, que grava no navegador e
   não fala com banco nenhum. Quer dizer: o funil só era exercitado no modo em
   que ele NÃO PODE quebrar.

   Foi por isso que estes três defeitos conviveram com a suíte verde:

     · o "Criando…" ia parar no botão do passo 1, escondido, e o botão que a
       pessoa apertou ficava aceso e sem resposta — "o botão não vai";
     · quatro tabelas eram pedidas com um filtro que o Postgres recusava, e o
       painel abria sem jornada de trabalho e com o Caixa vazio;
     · ninguém nunca tinha feito LOGIN em teste nenhum.

   Nenhum dos três aparece em modo demonstração. Todos os três aparecem aqui.

   Este arquivo faz o caminho de uma pessoa de verdade: cria a conta contra um
   Postgres com o schema e o RLS de verdade, fecha o navegador, volta numa aba
   limpa — como quem entra no dia seguinte, de outro computador — e entra com
   a senha que escolheu. No fim, o painel tem que mostrar o salão dela.
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok = (m) => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c) => c ? ok(m) : nao(m, 'esperava verdadeiro');

const nav = await chromium.launch({ executablePath: CHROMIUM });

// Uma aba nova, com tudo o que ela disser anotado. As respostas 4xx e 5xx
// entram na lista porque foi assim que os quatro `400` passaram despercebidos:
// o código os engolia e devolvia lista vazia, e a tela não tinha como saber.
async function abrir(ctx) {
  const p = await ctx.newPage();
  p.erros = []; p.ruins = [];
  p.on('pageerror', e => p.erros.push(e.message));
  p.on('console', m => { if (m.type() === 'error') p.erros.push(m.text()); });
  p.on('response', r => {
    if (r.status() >= 400) p.ruins.push(r.status() + ' ' + r.url().replace(BASE, ''));
  });
  return p;
}

const digitar = (p, sel, txt) => p.click(sel).then(() => p.type(sel, txt, { delay: 4 }));
const passoAtual = p => p.evaluate(() =>
  [...document.querySelectorAll('.passo')].findIndex(e => e.classList.contains('on')) + 1);

// Cada rodada precisa de e-mail e apelido que ninguém usou: o banco da bancada
// não é zerado entre execuções, e "e-mail já cadastrado" faria o teste falhar
// por sujeira, não por defeito.
const marca     = Date.now().toString(36) + Math.floor(Math.random() * 1000);
const EMAIL     = 'funil-' + marca + '@studioprado.com.br';
const SENHA     = 'minhasenhaboa';
const NOME      = 'Alessandro Prado';
const NOMESALAO = 'Studio Funil ' + marca;

const ctx1 = await nav.newContext({ viewport: { width: 430, height: 780 } });
const p = await abrir(ctx1);

console.log('\nA conta e o salão, contra um Postgres de verdade');

await p.goto(BASE + '/criar.html');
await p.waitForTimeout(500);
verdade('a página abre em modo nuvem, não em demonstração',
  await p.evaluate(() => !!(window.Dados && Dados.ligado)));

await digitar(p, '#fNome', NOME);
await digitar(p, '#fEmail', EMAIL);
await digitar(p, '#fSenha', SENHA);
await p.click('button.grande:has-text("Continuar")');
await p.waitForTimeout(400);
igual('a conta passa do passo 1', await passoAtual(p), 2);

await digitar(p, '#fSalao', NOMESALAO);
await p.selectOption('#fTipo', { index: 1 });
await digitar(p, '#fZap', '51998876655');
await p.waitForTimeout(200);

/* ── O BOTÃO TEM QUE RESPONDER AO DEDO QUE O APERTOU ──────────────────────
   Na bancada a resposta volta em milissegundos, e aí qualquer coisa parece
   instantânea. No celular da pessoa, não: o cadastro fala com o servidor duas
   vezes. Então a rede é atrasada de propósito, e a pergunta é a que ela faz —
   "apertei; mudou alguma coisa?".

   Sem o atraso este teste passaria com o defeito no lugar, que é o mesmo
   motivo de ele ter durado tanto.
   ──────────────────────────────────────────────────────────────────────── */
await p.route('**/auth/v1/**', async r => { await new Promise(f => setTimeout(f, 900)); r.continue(); });
await p.route('**/rest/v1/**', async r => { await new Promise(f => setTimeout(f, 900)); r.continue(); });

await p.click('#btCriar');
await p.waitForTimeout(350);

const visivel = await p.evaluate(() => {
  const b = [...document.querySelectorAll('button.grande')].find(x => x.offsetParent !== null);
  return b && { txt: b.textContent.trim(), desligado: b.disabled };
});
igual('enquanto espera o servidor, o botão à vista diz que está trabalhando',
  visivel && visivel.txt, 'Criando…');
verdade('e fica desabilitado, para o segundo clique não criar tudo de novo',
  visivel && visivel.desligado);

await p.waitForTimeout(4000);
igual('o cadastro chega ao passo 3', await passoAtual(p), 3);
const link = await p.textContent('#linkFinal');
verdade('e entrega o link da cliente com o apelido do salão',
  /agendar\.html\?salao=studio-funil-/.test(link));
igual('sem nenhum erro de JavaScript', p.erros.length, 0);
igual('e sem nenhuma resposta de erro do servidor', p.ruins.join(' | '), '');
await ctx1.close();

/* ── TENTAR DE NOVO COM O MESMO E-MAIL ────────────────────────────────────
   É o segundo caminho mais percorrido deste formulário: a pessoa não sabe se
   terminou, volta e preenche tudo outra vez. O Supabase recusa, e o que
   estava escrito na tela era o `e.message` cru — em inglês, e às vezes só
   "400", porque a frase vinha no campo `msg` que o `conferir()` não lia.

   "User already registered" não diz a coisa que resolve: é ir em Entrar. */
console.log('\nO mesmo e-mail, de novo');

const ctxR = await nav.newContext({ viewport: { width: 430, height: 780 } });
const r = await abrir(ctxR);
await r.goto(BASE + '/criar.html');
await r.waitForTimeout(500);
await digitar(r, '#fNome', NOME);
await digitar(r, '#fEmail', EMAIL);
await digitar(r, '#fSenha', SENHA);
await r.click('button.grande:has-text("Continuar")');
await r.waitForTimeout(400);
await digitar(r, '#fSalao', NOMESALAO + ' II');
await r.selectOption('#fTipo', { index: 1 });
await digitar(r, '#fZap', '51998876600');
await r.click('#btCriar');
await r.waitForTimeout(2500);

const recusa = (await r.textContent('#avisoNegocio')).replace(/\s+/g, ' ').trim();
igual('não avança de passo', await passoAtual(r), 2);
verdade('e diz, em português, que o e-mail já tem conta — ' + JSON.stringify(recusa.slice(0, 70)),
  recusa.includes('já tem conta'));
verdade('apontando para a tela de Entrar, que é o que resolve',
  await r.isVisible('#avisoNegocio a[href="entrar.html"]'));
verdade('e nunca mostra só o número da resposta',
  !/\b400\b|\b422\b/.test(recusa));
verdade('o botão volta a funcionar, para a pessoa corrigir e tentar',
  await r.evaluate(() => !document.getElementById('btCriar').disabled));
await ctxR.close();

console.log('\nVoltar no dia seguinte e entrar');

/* Contexto NOVO: sem localStorage, sem cookie, sem sessão. É a diferença
   entre "continua funcionando na mesma aba" e "a conta existe no banco". */
const ctx2 = await nav.newContext({ viewport: { width: 1280, height: 900 } });
const q = await abrir(ctx2);
await q.goto(BASE + '/entrar.html');
await q.waitForTimeout(3600);          // a cortina de abertura leva 3 segundos

await q.fill('#email', EMAIL);
await q.fill('#senha', SENHA);
await q.click('#btEntrar');
await q.waitForTimeout(3500);

igual('a senha escolhida no cadastro abre o painel', new URL(q.url()).pathname, '/app.html');

const corpo = await q.evaluate(() => document.body.innerText.replace(/\s+/g, ' '));
verdade('e o painel mostra o salão desta pessoa, não outro',
  corpo.includes(NOMESALAO));

/* ── O CAIXA E A JORNADA ──────────────────────────────────────────────────
   Aqui moravam os quatro `400`. Eles não derrubavam a tela: viravam lista
   vazia em silêncio, e o painel abria com cara de salão novo. Como o defeito
   não fazia barulho, o teste tem que fazer — qualquer 4xx reprova. */
igual('nenhuma pergunta malfeita chega ao banco', q.ruins.join(' | '), '');
igual('e nenhum erro de JavaScript no painel', q.erros.length, 0);

// `bd` é declarado com `let` no topo do script da página. `let` global não
// vira propriedade de `window` — mas o nome continua alcançável daqui, que é
// por onde se lê o banco em memória do painel.
const tabelas = await q.evaluate(() => {
  const b = (typeof bd !== 'undefined' && bd) ? bd : {};
  return { jornadas: Array.isArray(b.jornadas), pagamentos: Array.isArray(b.pagamentos),
           itens: Array.isArray(b.comanda_itens) };
});
verdade('as tabelas sem `salao_id` chegam na tela como lista, não como buraco',
  tabelas.jornadas && tabelas.pagamentos && tabelas.itens);

/* ── CADASTRAR UM CLIENTE PELO PAINEL ──────────────────────────────────────
   Este é o caminho mais comum que existe neste sistema: a recepção anota
   alguém no balcão. E era o que estava quebrado na nuvem — a tela cunhava id
   no formato "xxe7qkwou" e o Postgres respondia

       clientes: invalid input syntax for type uuid: "xxe7qkwou"

   Nada criado pelo painel chegava ao banco: cliente, serviço, agendamento,
   comanda, profissional, jornada. Todos os testes do painel rodavam em
   `?demo=1`, onde id é só texto no localStorage e qualquer coisa serve — pela
   terceira vez, o defeito morava no modo que os testes não visitavam.

   O `alert` do navegador é capturado: se a gravação falhar, ele aparece com a
   mensagem crua do Postgres, e é isso que este teste tem que ver. */
const avisos = [];
q.on('dialog', d => { avisos.push(d.message()); d.accept(); });

await q.click('a:has-text("Clientes"), button:has-text("Clientes")');
await q.waitForTimeout(500);
await q.click('button:has-text("+ Cliente")');
await q.waitForTimeout(400);
await q.fill('#kNome', 'Jucelia Barbosa');
await q.fill('#kTel', '11981113251');
await q.click('button:has-text("Salvar")');
await q.waitForTimeout(2500);

igual('gravar um cliente novo não devolve erro nenhum', avisos.join(' | '), '');
verdade('e ele aparece na lista da tela',
  (await q.textContent('body')).includes('Jucelia Barbosa'));

/* A prova que importa: recarregar. O que existe só na memória some aqui, e
   era exatamente esse o estado antes — a linha na tela, nada no banco. */
await q.reload();
await q.waitForTimeout(3000);
await q.click('a:has-text("Clientes"), button:has-text("Clientes")');
await q.waitForTimeout(800);
verdade('e continua lá depois de recarregar, porque foi para o banco',
  (await q.textContent('body')).includes('Jucelia Barbosa'));

/* ── A JORNADA DE TRABALHO ────────────────────────────────────────────────
   Três defeitos moravam aqui ao mesmo tempo, todos por falta da tradução
   entre `p.jornada` (o mapa da tela) e a tabela `jornadas` (uma linha por
   faixa):

     · a aba Equipe QUEBRAVA, lendo `p.jornada[d]` de quem não tinha jornada
       — e uma aba que quebra parece uma aba que não existe, que foi como
       este pedaço "sumiu";
     · a agenda do dono abria sem horário de trabalho nenhum;
     · e a jornada não tinha como ser salva, porque `jornada` é campo de tela
       e era removido antes de subir.

   O terceiro é o que custa dinheiro: sem linha em `jornadas`, a função
   `horarios_livres()` não devolve nada, e o link que a cliente abre fica sem
   um horário sequer. O dono configura a semana, salva, e continua invisível.
   ──────────────────────────────────────────────────────────────────────── */
await q.click('a:has-text("Equipe"), button:has-text("Equipe")');
await q.waitForTimeout(700);
igual('a aba Equipe abre sem quebrar', q.erros.length, 0);
verdade('e mostra quem atende', (await q.textContent('body')).includes(NOME.split(' ')[0]));

await q.click('#listaEquipe button:has-text("Editar")');
await q.waitForTimeout(500);
// Terça (2): entra 08:00, sai 12:00; volta 14:00, sai 18:00 — com almoço.
await q.fill('#j2a', '08:00'); await q.fill('#j2b', '12:00');
await q.fill('#j2c', '14:00'); await q.fill('#j2d', '18:00');
await q.click('button:has-text("Salvar")');
await q.waitForTimeout(2500);
igual('salvar a jornada não devolve erro', avisos.join(' | '), '');

await q.reload();
await q.waitForTimeout(3000);
await q.click('a:has-text("Equipe"), button:has-text("Equipe")');
await q.waitForTimeout(700);
await q.click('#listaEquipe button:has-text("Editar")');
await q.waitForTimeout(600);
igual('a hora de entrar na terça voltou do banco', await q.inputValue('#j2a'), '08:00');
igual('e a de sair também',                        await q.inputValue('#j2b'), '12:00');
igual('o almoço no meio não se perde — volta às 14:00', await q.inputValue('#j2c'), '14:00');
igual('e a saída da tarde',                        await q.inputValue('#j2d'), '18:00');

/* ── MARCAR E BLOQUEAR PELO PAINEL ────────────────────────────────────────
   O uso diário do lado do salão: a recepção anota alguém no balcão, e o dono
   bloqueia a própria folga. Os dois estavam quebrados na nuvem, e falhavam
   com a mensagem crua do Postgres:

       column "data" of relation "bloqueios" does not exist

   A tela pensa em `{data, minutos}`; o banco guarda dois `timestamptz`. Sem a
   tradução, nada que o painel criasse na agenda chegava ao banco — só o link
   da cliente marcava, porque ele passa por `agendar()`.

   Este caso cobra a ida E A VOLTA. Só a ida não bastaria: converter na
   gravação e errar na leitura mostraria o horário deslocado no dia seguinte,
   que é pior do que não gravar — porque parece que funcionou.
   ──────────────────────────────────────────────────────────────────────── */
/* O modal do passo anterior ainda está aberto, e o fundo escuro dele
   intercepta o clique na aba. Teste que trava por isso falha por cenário
   errado, não por defeito. */
const fecharModalAberto = () => q.evaluate(() => {
  const f = document.getElementById('fundo');
  if(f) f.classList.remove('on');
});

/* Sem serviço cadastrado, `abrirNovo()` mostra "Falta cadastro" em vez do
   formulário — e está certo: não dá para marcar o que o salão não faz. */
await fecharModalAberto();
await q.click('a:has-text("Serviços"), button:has-text("Serviços")');
await q.waitForTimeout(700);
await q.click('button:has-text("+ Serviço")');
await q.waitForTimeout(600);
await q.fill('#sNome', 'Corte');
await q.fill('#sPreco', '80');
await q.click('#modalPe button:has-text("Salvar")');
await q.waitForTimeout(2500);
igual('cadastrar um serviço pelo painel não devolve erro', avisos.join(' | '), '');

await fecharModalAberto();
await q.click('a:has-text("Agenda"), button:has-text("Agenda")');
await q.waitForTimeout(700);
await q.click('button:has-text("+ Agendamento")');
await q.waitForTimeout(700);
await q.fill('#fNome', 'Cliente do Balcão');
await q.fill('#fTel', '51988776655');
await q.fill('#fInicio', '14:30');
await q.evaluate(() => {
  const c = document.querySelector('#modalCorpo input[type=checkbox]');
  if(c && !c.checked) c.click();
});
await q.waitForTimeout(300);
const diaMarcado = await q.inputValue('#fData');
await q.click('#modalPe button:has-text("Agendar")');
await q.waitForTimeout(2800);
igual('marcar pelo painel não devolve erro', avisos.join(' | '), '');

const marcados = await q.evaluate(() =>
  (typeof bd !== 'undefined' && bd.agendamentos) ? bd.agendamentos.length : -1);
igual('e existe uma marcação', marcados, 1);

await q.reload();
await q.waitForTimeout(3500);
await q.click('a:has-text("Agenda"), button:has-text("Agenda")');
await q.waitForTimeout(900);
const voltou = await q.evaluate(() => {
  const b = (typeof bd !== 'undefined' && bd.agendamentos) || [];
  return b[0] ? { data: b[0].data, inicio: b[0].inicio, servicos: (b[0].servicos||[]).length } : null;
});
igual('depois de recarregar, o dia volta igual', voltou && voltou.data, diaMarcado);
// 14:30 = 870 minutos desde a meia-noite. Se a conversão de fuso errar em uma
// hora, este número vira 810 ou 930 — e é exatamente esse o erro que aparece
// só no domingo em que o horário de verão vira.
igual('e a HORA volta igual, sem deslocar o fuso', voltou && voltou.inicio, 870);
igual('e o serviço do atendimento também voltou', voltou && voltou.servicos, 1);

/* ── O CAIXA ──────────────────────────────────────────────────────────────
   Três defeitos moravam aqui, e os três só apareciam na nuvem:

     · a comanda gravava `data`, coluna que não existe (ela tem `aberta_em`);
     · os itens e os pagamentos moram em tabelas filhas, e ninguém traduzia —
       o Caixa abria sempre zerado;
     · e o PostgREST devolve `numeric` como STRING, então somar concatenava:
       `0 + '80.00' + '45.00'` é '080.0045.00'. Faturamento do dia, comissão e
       total de comanda saem dessa conta.

   O último é o que assusta: um sistema de salão que erra a conta do caixa não
   tem serventia nenhuma, e ele erraria em silêncio, com número plausível na
   tela. Por isso o teste confere o TIPO, não só o valor. */
const agId = await q.evaluate(() =>
  (typeof bd !== 'undefined' && bd.agendamentos[0] || {}).id);
await q.evaluate(id => comandaDoAgendamento(id), agId);
await q.waitForTimeout(2500);
igual('abrir a comanda do atendimento não devolve erro', avisos.join(' | '), '');

await q.reload();
await q.waitForTimeout(3500);
const caixa = await q.evaluate(() => {
  const c = (typeof bd !== 'undefined' && bd.comandas[0]) || {};
  const sub = (c.itens || []).reduce((s, i) => s + i.qtd * i.precoUnit, 0);
  return { comandas: (bd.comandas || []).length, itens: (c.itens || []).length,
           subtotal: sub, tipo: typeof sub, dia: c.data };
});
igual('a comanda sobreviveu ao recarregamento', caixa.comandas, 1);
igual('com o item do atendimento dentro', caixa.itens, 1);
igual('o subtotal é NÚMERO, não texto — senão a soma concatena', caixa.tipo, 'number');
igual('e vale o preço do serviço', caixa.subtotal, 80);
verdade('e o dia da comanda saiu de `aberta_em`', /^\d{4}-\d{2}-\d{2}$/.test(caixa.dia || ''));

await fecharModalAberto();
await q.click('a:has-text("Equipe"), button:has-text("Equipe")');
await q.waitForTimeout(700);
await q.click('#listaEquipe button:has-text("Bloquear horário")');
await q.waitForTimeout(700);
await q.fill('#bIni', '12:00');
await q.fill('#bFim', '13:00');
await q.click('#modalPe button:has-text("Bloquear"), #modalPe button:has-text("Salvar")');
await q.waitForTimeout(2500);
igual('bloquear um horário não devolve erro', avisos.join(' | '), '');
igual('e o bloqueio existe',
  await q.evaluate(() =>
    (typeof bd !== 'undefined' && bd.bloqueios) ? bd.bloqueios.length : -1), 1);

/* ── A FOTO DE QUEM ATENDE ────────────────────────────────────────────────
   Imagem é o único pedaço do sistema que não passa pelo PostgREST: outro
   serviço, outro caminho, corpo binário. A bancada não tinha nada disso, e
   por isso TODA foto — logo, capa, serviço, profissional — vivia fora de
   teste no modo nuvem. Agora ela tem um arremedo do Storage, e este caso
   passa por ele de ponta a ponta: escolher, reduzir, enviar, gravar o
   endereço, recarregar e continuar lá. */
const PNG_4x4 = 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAHElEQVQI12P4'
              + '//8/AzYEEwAAKzQD/6Ac0AAAAABJRU5ErkJggg==';

// Reabre o cadastro de quem atende: os casos acima fecharam o modal para
// poder trocar de aba.
await fecharModalAberto();
await q.click('a:has-text("Equipe"), button:has-text("Equipe")');
await q.waitForTimeout(700);
await q.click('#listaEquipe button:has-text("Editar")');
await q.waitForTimeout(700);
await q.setInputFiles('#modalCorpo input[type=file]',
  { name: 'rosto.png', mimeType: 'image/png', buffer: Buffer.from(PNG_4x4, 'base64') });
await q.waitForTimeout(1200);
verdade('a foto escolhida aparece na prévia antes de salvar',
  await q.evaluate(() => !!document.querySelector('#previaProf img')));

await q.click('#modalPe button:has-text("Salvar")');
await q.waitForTimeout(3000);
igual('salvar com foto não devolve erro', avisos.join(' | '), '');

await q.reload();
await q.waitForTimeout(3000);
await q.click('a:has-text("Equipe"), button:has-text("Equipe")');
await q.waitForTimeout(800);
const rosto = await q.evaluate(() => {
  const img = document.querySelector('#listaEquipe .eq-rosto img');
  return img ? img.getAttribute('src') : null;
});
verdade('e continua lá depois de recarregar', !!rosto);
/* O endereço tem que ser do servidor, não um `data:` de 200 KB. Uma base64
   gravada na coluna funciona na tela do dono e faz a página da cliente
   carregar um texto gigante por profissional — no 3G dela, isso é a
   diferença entre abrir e desistir. */
verdade('e é um endereço do servidor, não a imagem inteira dentro da coluna',
  rosto && !rosto.startsWith('data:'));

/* ══════════════════════════════════════════════════════════════════════════
   A AGENDA TEM QUE SOBREVIVER AO SALVAMENTO

   Relatado assim: "está dando bug na agenda quando acesso comanda e aperto
   salvar ou mudo de dia". E era exatamente isso.

   `salvar()` chamava `desmontarJornadas(bd)` e `desmontarAgenda(bd)` — no
   objeto que a tela desenha. As duas mudam o formato NO LUGAR: `inicio`
   deixa de ser minutos e vira instante ISO, `data` é apagada (não existe no
   banco), a jornada vira linhas.

   Então, ao fim de todo salvamento, a tela ficava segurando dados que ela
   não sabe ler. A agenda esvaziava — a filtragem do dia procura `a.data`,
   recém-apagada — e só voltava quando alguém recarregava a página. Por isso
   "sumia e voltava", que é a pior forma de defeito: parece intermitente.

   Medido, com um atendimento marcado no dia:

       ANTES   1 cartão → salvar → 0 cartões, e o nome do cliente some
       DEPOIS  1 cartão → salvar → 1 cartão

   Nenhuma suíte pegava porque nenhuma salvava e DEPOIS olhava a agenda.
   Esta olha.
   ══════════════════════════════════════════════════════════════════════════ */
console.log('\nA agenda depois de salvar, e depois de trocar de dia');

await fecharModalAberto();
await q.click('a:has-text("Agenda"), button:has-text("Agenda")');
await q.waitForTimeout(900);

/* Medido pelo DESENHO, não por dentro. O que quebrava era o formato na
   memória, mas quem sofre é a agenda vazia — e um teste que espia variável
   interna passa a proteger a implementação em vez do que a pessoa vê.

   `top` em pixels é a prova de que a hora ainda é número: o cartão só tem
   onde ser posto se `a.inicio` for minutos. Virando texto do banco, ou o
   cartão some ou vai para o topo. */
const naAgenda = () => q.evaluate(() => {
  const cs = [...document.querySelectorAll('.grade .ag')];
  return {
    cartoes: cs.length,
    posicionados: cs.filter(c => parseFloat(c.style.top) > 0).length,
    texto: cs.map(c => c.textContent.replace(/\s+/g, ' ').trim()).join(' | '),
  };
});

const antesDeSalvar = await naAgenda();
verdade('há atendimento desenhado na agenda antes de salvar',
  antesDeSalvar.cartoes > 0, JSON.stringify(antesDeSalvar));

// Salvar QUALQUER coisa — o estrago não dependia do que foi salvo.
await q.click('a:has-text("Meu salão"), button:has-text("Meu salão")');
await q.waitForTimeout(900);
await q.click('button:has-text("Salvar dados")');
await q.waitForTimeout(2500);
await q.click('a:has-text("Agenda"), button:has-text("Agenda")');
await q.waitForTimeout(900);

const depoisDeSalvar = await naAgenda();
igual('depois de salvar, a agenda continua com os mesmos atendimentos',
  depoisDeSalvar.cartoes, antesDeSalvar.cartoes);
igual('cada um no horário certo da coluna, e não empilhado no topo',
  depoisDeSalvar.posicionados, antesDeSalvar.posicionados);
igual('com o mesmo conteúdo de antes — nome, horário, serviço',
  depoisDeSalvar.texto, antesDeSalvar.texto);

// E o segundo caminho do relato: trocar de dia depois de ter salvado.
await q.click('.ag-nav button:has-text("›"), button:has-text("›")');
await q.waitForTimeout(700);
await q.click('.ag-nav button:has-text("‹"), button:has-text("‹")');
await q.waitForTimeout(900);
igual('e voltando ao dia de hoje, os atendimentos ainda estão lá',
  (await naAgenda()).cartoes, antesDeSalvar.cartoes);
igual('sem nenhum aviso de erro em nada disso', avisos.join(' | '), '');

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações do funil na nuvem.`);
