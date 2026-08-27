/* ===========================================================================
   AgendaPro — quando o banco está atrás da tela

     bash tests/bancada/subir.sh
     node tests/banco-atrasado.test.mjs

   ── O DEFEITO QUE ESTE ARQUIVO EXISTE PARA NÃO DEIXAR VOLTAR ───────────────
   A tela se atualiza sozinha — é uma página, o navegador busca a versão nova.
   O banco não: ele só muda quando alguém cola SQL no painel do Supabase.
   Entre as duas coisas existe uma janela, de horas ou de semanas, em que a
   tela chama função que o banco ainda não tem. Isso não é um caso raro: é o
   estado normal de todo cliente entre uma publicação e a colagem seguinte.

   E foi o que aconteceu num salão de verdade, em duas telas no mesmo dia:

     Relatórios · «Could not find the function public.relatorio(p_ate, p_de,
                  p_salao) in the schema cache»
     Convite    · «Could not find the function public.criar_convite(p_papel,
                  p_para_quem, p_profissional, p_salao) in the schema cache
                  — Perhaps you meant to call the function
                  public.criar_convite(p_papel, p_para_quem, p_salao)»

   Duas coisas estavam erradas, e nenhuma das duas era da tela.

   1. A FRASE. Está escrita para quem programa. Para a dona do salão não quer
      dizer nada e, pior, não diz o que fazer. Ela ficou olhando um erro em
      inglês sobre cache de schema.

   2. NENHUM TESTE PODIA PEGAR. A bancada mandava a chamada direto para o
      Postgres e devolvia o 42883 dele: outra frase, outro código, status
      400. O PostgREST de verdade nem fala com o banco — casa contra o cache
      de schema e responde 404 com PGRST202. Bancada que responde diferente
      do real aprova código quebrado, e foi o que fez.

   O segundo erro é o mais grave dos dois: enquanto a bancada não soubesse
   errar como o PostgREST erra, a tradução do `dados.js` podia estar escrita
   de qualquer jeito que a suíte ficaria verde.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
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

const d = novaAba();

const pegar = async fn => {
  try{ await fn(); return null; }catch(e){ return e; }
};

/* ═══════════════════════════════════════════════════════════════════════════
   0) A BANCADA ERRA COMO O POSTGREST ERRA

   Antes de conferir a tradução, conferir que existe o que traduzir. Se esta
   seção afrouxar, todas as de baixo continuam verdes sem provar nada.
   ═══════════════════════════════════════════════════════════════════════════ */
secao('0) a bancada responde como o PostgREST de verdade');

{
  const r = await fetch(BASE + '/rest/v1/rpc/funcao_que_nunca_existiu',
    { method:'POST', headers:{ 'Content-Type':'application/json', apikey:'k' },
      body: JSON.stringify({ p_salao:'x' }) });
  const corpo = await r.json().catch(() => ({}));

  verdade('função que não existe responde 404, não 400', r.status === 404,
    'veio ' + r.status);
  verdade('e com o código PGRST202', corpo.code === 'PGRST202',
    'veio ' + JSON.stringify(corpo.code));
  verdade('com a frase do cache de schema',
    /Could not find the function public\.funcao_que_nunca_existiu/.test(corpo.message || ''),
    corpo.message);
}

/* O caso do convite: a função EXISTE, com outros argumentos. É o mais
   traiçoeiro dos dois, porque o `hint` do PostgREST é o que entrega o
   diagnóstico — e um erro sem `hint` mandaria quem for consertar procurar
   uma função que está bem ali. */
{
  const r = await fetch(BASE + '/rest/v1/rpc/vitrine',
    { method:'POST', headers:{ 'Content-Type':'application/json', apikey:'k' },
      body: JSON.stringify({ p_slug:'x', p_argumento_que_nao_existe:1 }) });
  const corpo = await r.json().catch(() => ({}));

  verdade('argumento a mais numa função existente também dá PGRST202',
    r.status === 404 && corpo.code === 'PGRST202',
    r.status + ' ' + JSON.stringify(corpo.code));
  verdade('e o hint aponta a assinatura que existe de verdade',
    /Perhaps you meant to call the function public\.vitrine\(p_slug\)/
      .test(corpo.hint || ''), corpo.hint);
}

/* O contrário disso importa igual: argumento OMITIDO é normal, porque o
   parâmetro tem `default`. Uma bancada mais rigorosa que o real reprovaria
   chamada que lá fora passa — o mesmo defeito, virado do avesso. */
{
  const r = await fetch(BASE + '/rest/v1/rpc/vitrine',
    { method:'POST', headers:{ 'Content-Type':'application/json', apikey:'k' },
      body: JSON.stringify({ p_slug:'nao-existe-este-salao' }) });
  verdade('chamada com os argumentos certos NÃO é barrada', r.status === 200,
    'veio ' + r.status);
}

/* ═══════════════════════════════════════════════════════════════════════════
   1) A TRADUÇÃO — o que a dona do salão lê
   ═══════════════════════════════════════════════════════════════════════════ */
secao('1) a mensagem que chega na tela');

{
  const e = await pegar(() => d.chamar('funcao_que_nunca_existiu', { p_salao:'x' }));

  verdade('a chamada realmente falhou', !!e);
  verdade('a frase em inglês do PostgREST não chega na tela',
    !/schema cache|Could not find/i.test(e.message), e.message);
  verdade('e a mensagem diz o que fazer: colar o 98_modulos.sql',
    /98_modulos\.sql/.test(e.message), e.message);
  verdade('diz também ONDE se faz isso',
    /Supabase/.test(e.message) && /SQL Editor/.test(e.message), e.message);
  verdade('e nomeia a peça que falta, para quem for consertar',
    /funcao_que_nunca_existiu/.test(e.message), e.message);
  verdade('avisa que colar de novo não faz mal',
    /mais de uma vez/.test(e.message), e.message);
  verdade('o código do erro continua disponível para o código',
    e.codigo === 'PGRST202', e.codigo);
}

/* PGRST204 é a mesma história com coluna: a tela grava um campo que o banco
   ainda não tem. A frase do PostgREST nomeia a peça de outro jeito — «Could
   not find the 'x' column of 'y'», sem `public.` nenhum — e um padrão só
   pegaria metade dos casos. */
{
  const r = new Response(JSON.stringify({
    code: 'PGRST204',
    message: "Could not find the 'acrescimo' column of 'comandas' in the schema cache",
  }), { status: 400, headers:{ 'Content-Type':'application/json' } });

  /* Aba própria, com o `fetch` trocado por um que devolve sempre a resposta
     acima. É o único jeito de produzir um PGRST204 aqui: a bancada não tem
     como ficar sem uma coluna que o `00_tudo.sql` acabou de criar nela. */
  const g = {};
  const j = { AGENDAPRO:{ url:'http://x', chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, async () => r.clone(), j.localStorage);

  const e = await pegar(() => j.Dados.chamar('qualquer', { p_x:1 }));
  verdade('coluna faltando também vira instrução, não jargão',
    /98_modulos\.sql/.test(e.message) && !/schema cache/.test(e.message),
    e.message);
  verdade('e nomeia a COLUNA que falta',
    /acrescimo/.test(e.message), e.message);
}

/* Traduzir DEMAIS seria trocar um problema por outro: um erro de permissão
   virando "instale o banco" manda a pessoa colar SQL para resolver algo que
   SQL nenhum resolve. */
{
  const e = await pegar(() => d.chamar('painel_plataforma', {}));
  verdade('erro que NÃO é de instalação segue com a mensagem dele',
    !e || !/98_modulos/.test(e.message),
    e && e.message);
}

/* ═══════════════════════════════════════════════════════════════════════════
   2) O QUE A TELA CHAMA TEM QUE EXISTIR — HOJE, NESTA VERSÃO

   A tradução acima é a rede de baixo, para quando o banco do cliente estiver
   atrasado. Não é desculpa para publicar tela que chama função inexistente:
   isso é defeito nosso, e tem que reprovar aqui, não no salão dela.

   Repare que confere pelo NOME DOS ARGUMENTOS, não só pelo nome da função.
   Era exatamente aí que estava o defeito do convite: `criar_convite` existia,
   e mesmo assim a tela levava "Could not find the function", porque chamava
   com quatro argumentos um banco que só tinha a de três.
   ═══════════════════════════════════════════════════════════════════════════ */
secao('2) toda função que a tela chama existe com os argumentos que ela manda');

const fonte = ['app.html','dados.js','index.html','criar.html','entrar.html']
  .map(f => path.join(RAIZ, f))
  .filter(f => fs.existsSync(f))
  .map(f => fs.readFileSync(f, 'utf8'))
  .join('\n');

const nomesEm = t => [...t.matchAll(/(^|[\s,{])(p_[a-z_0-9]+)\s*:/g)].map(a => a[2]);

/* Dois jeitos de chamar, porque são dois lados do sistema.

   O painel usa `Dados.chamar('fn', { p_a: ... })`. As telas da cliente não
   têm painel nenhum: elas chamam métodos do `dados.js`, e é lá dentro que
   está o `rest('rpc/fn', { body: JSON.stringify({ p_a: ... }) })`. Ficar só
   com o primeiro padrão deixaria `vitrine`, `meus_agendamentos`, `minha_fila`
   e as outras de fora — justamente as que a cliente alcança sem login, e as
   únicas que um salão quebrado deixa quebradas para quem está de fora.

   `[\s\S]*?` porque as chamadas quebram em várias linhas.

   Quem passa `JSON.stringify(dados)` — uma variável — não entra: não há nome
   de argumento escrito no código para conferir. É um limite honesto deste
   teste, e o `atualizar.test.sh` cobre a existência dessas por outro caminho. */
const chamadas = [
  ...[...fonte.matchAll(/chamar\(\s*'([a-z_0-9]+)'\s*,\s*\{([\s\S]{0,400}?)\}/g)]
      .map(m => ({ fn: m[1], args: nomesEm(m[2]) })),
  ...[...fonte.matchAll(
      /rest\(\s*'rpc\/([a-z_0-9]+)'[\s\S]{0,200}?JSON\.stringify\(\{([\s\S]{0,300}?)\}\)/g)]
      .map(m => ({ fn: m[1], args: nomesEm(m[2]) })),
].filter(c => c.args.length);

verdade('achei as chamadas do painel no código',
  chamadas.some(c => c.fn === 'criar_convite') &&
  chamadas.some(c => c.fn === 'relatorio'),
  'achei ' + chamadas.map(c => c.fn).join(', '));

verdade('achei também as chamadas das telas da cliente',
  chamadas.some(c => c.fn === 'vitrine'),
  'achei ' + chamadas.map(c => c.fn).join(', '));

for(const c of chamadas){
  const r = await fetch(BASE + '/rest/v1/rpc/' + c.fn,
    { method:'POST', headers:{ 'Content-Type':'application/json', apikey:'k' },
      body: JSON.stringify(Object.fromEntries(c.args.map(a => [a, null]))) });
  // `?? {}` e não `|| {}`: resposta bem-sucedida sem corpo vem como `null`,
  // e `null.code` derruba o teste inteiro com um TypeError — reprovando por
  // erro do teste, no meio de uma lista que estava passando.
  const corpo = (await r.json().catch(() => null)) ?? {};

  // Qualquer resposta serve, MENOS "essa função com esses argumentos não
  // existe". Erro de permissão, de tipo ou de regra é outro assunto — aqui
  // só se pergunta se a porta está no lugar.
  verdade(c.fn + '(' + c.args.join(', ') + ') existe no banco',
    corpo.code !== 'PGRST202',
    (corpo.message || '') + ' ' + (corpo.hint || ''));
}

/* ═══════════════════════════════════════════════════════════════════════════
   3) NINGUÉM PODE DEPENDER SÓ DA FRASE

   O `agendar.html` já sabia tratar este caso antes de tudo isto existir: ele
   reconhecia a instalação atrasada e dizia à cliente que a agenda online não
   tinha sido ligada. Reconhecia POR TEXTO — `/Could not find the function/`
   em cima de `e.message`.

   No dia em que o `dados.js` passou a traduzir essa mesma frase para
   português, a regra parou de casar e a tela voltou a dizer "pode ser a
   conexão" para um banco sem função nenhuma. Nada estava errado dos dois
   lados: um melhorou a mensagem, o outro dependia dela palavra por palavra.
   Casar com texto voltado para gente é casar com o que EXISTE para mudar.

   `e.codigo` é dado de máquina: não é traduzido, não é reescrito. Quem
   reconhece este erro tem que olhar para ele primeiro.
   ═══════════════════════════════════════════════════════════════════════════ */
secao('3) reconhecer o erro pelo código, não pela frase');

for(const arq of ['agendar.html','app.html','index.html','dados.js']){
  const caminho = path.join(RAIZ, arq);
  if(!fs.existsSync(caminho)) continue;
  const t = fs.readFileSync(caminho, 'utf8');

  // Só interessa quem RECONHECE a frase para decidir alguma coisa. O
  // `dados.js` é quem a produz, e a linha que monta a mensagem não conta.
  const casaFrase = /Could not find the function/.test(t);
  if(!casaFrase) continue;

  verdade(arq + ' também olha o código PGRST202, não só a frase',
    /PGRST202/.test(t),
    'reconhece a instalação atrasada pelo texto em inglês e nada mais — '
    + 'qualquer melhoria na mensagem quebra em silêncio');
}

console.log('');
if(falhou){
  console.log(`✗ ${falhou} de ${passou + falhou} verificações falharam.`);
  process.exit(1);
}
console.log(`✓ ${passou} verificações de banco atrasado.`);
