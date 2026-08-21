/* ===========================================================================
   AgendaPro — o mapa de colunas bate com o banco?
   Rodar:  node tests/colunas.test.js

   POR QUE ESTE TESTE EXISTE
   `dados.js` traduz camelCase da tela para snake_case do banco. Um nome
   errado ali não quebra nada até a hora de gravar em produção — aí o
   PostgREST devolve 400 e a tela perde o que a pessoa digitou.

   É o erro mais bobo possível e o mais caro de descobrir tarde, porque só
   aparece na operação. Aqui ele aparece em dois segundos: lemos as colunas
   do `01_schema.sql` de verdade e comparamos com o mapa.

   Não substitui testar contra o Supabase de verdade. Elimina, isso sim, a
   classe inteira de erro de digitação de nome de coluna.
   =========================================================================== */

const fs = require('fs');
const path = require('path');

const RAIZ = path.join(__dirname, '..');
const sql = ['supabase/01_schema.sql', 'supabase/03_onboarding.sql']
  .map(f => fs.readFileSync(path.join(RAIZ, f), 'utf8')).join('\n');

let ok = 0, falhas = 0;
const dizer = (bom, msg) => {
  if(bom){ ok++; console.log('  ✓ ' + msg); }
  else   { falhas++; console.log('  ✗ ' + msg); }
};

/* ── Ler as colunas de cada `create table` ───────────────────────────────
   Analisador simples de propósito: o schema é nosso e segue um padrão só.
   Analisador de SQL de verdade seria mais frágil que o problema.
   ──────────────────────────────────────────────────────────────────────── */
function lerTabelas(texto){
  const tabelas = {};
  const re = /create table if not exists public\.(\w+)\s*\(([\s\S]*?)\n\);/g;
  let m;
  while((m = re.exec(texto)) !== null){
    const nome = m[1];
    const colunas = [];
    for(let linha of m[2].split('\n')){
      linha = linha.replace(/--.*$/, '').trim();
      if(!linha) continue;
      // Pula o que não é definição de coluna
      if(/^(primary key|unique|check|constraint|foreign key|exclude)\b/i.test(linha)) continue;
      /* Nome e tipo. O tipo passou a importar quando um campo de data vazio
         derrubou a gravação inteira: para o Postgres, `''` não é uma data.

         O tipo é UMA palavra (mais um `(10,2)` opcional), e não "o resto da
         linha": a primeira versão engolia `generated always as (...)` e
         `primary key references public`, e inventava três colunas que não
         existem. Analisador que erra o nome da coluna estraga o teste que
         depende dele. */
      const c = linha.match(
        /^([a-z_][a-z0-9_]*)\s+((?:timestamp with time zone|time without time zone|double precision|[a-z]+)(?:\(\s*[\d,\s]*\))?)/i);
      if(c) colunas.push({
        nome: c[1],
        tipo: c[2].trim().toLowerCase(),
        // Coluna calculada pelo banco e chave primária nunca chegam em branco
        // da tela, então não entram na conferência de "vazio vira null".
        nulo: !/not null|primary key|generated always as/i.test(linha),
      });
    }
    tabelas[nome] = colunas;
  }
  return tabelas;
}

// O resto do arquivo compara nomes; mantém a forma antiga para eles.
function soNomes(tabelas){
  const r = {};
  for(const t of Object.keys(tabelas)) r[t] = tabelas[t].map(c => c.nome);
  return r;
}

const tabelasComTipo = lerTabelas(sql);
const tabelas = soNomes(tabelasComTipo);

console.log('\nTabelas lidas do schema');
dizer(Object.keys(tabelas).length >= 20,
  `${Object.keys(tabelas).length} tabelas encontradas no SQL`);

// Carrega o mapa de dados.js sem navegador: montamos o mínimo de `window`.
const dadosJs = fs.readFileSync(path.join(RAIZ, 'dados.js'), 'utf8');
const janela = {
  AGENDAPRO: { url: '', chave: '' },
  localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
};
new Function('window', 'console', 'fetch', 'localStorage', dadosJs)(
  janela, { info(){}, error(){}, log(){} }, () => {}, janela.localStorage);

const D = janela.Dados;
dizer(!!D && !!D.COLUNAS, 'dados.js carrega e expõe o mapa de colunas');

console.log('\nCada tabela do mapa existe no banco');
for(const tabela of Object.keys(D.COLUNAS)){
  dizer(!!tabelas[tabela], `tabela "${tabela}"`);
}

console.log('\nCada coluna traduzida existe mesmo');
for(const tabela of Object.keys(D.COLUNAS)){
  const reais = tabelas[tabela] || [];
  for(const [naTela, noBanco] of Object.entries(D.COLUNAS[tabela])){
    // `saloes.salaoId -> id` é apelido de conveniência, não coluna nova.
    dizer(reais.includes(noBanco),
      `${tabela}.${naTela} → ${noBanco}` +
      (reais.includes(noBanco) ? '' : `  (colunas reais: ${reais.join(', ')})`));
  }
}

/* ── O caminho de ida e volta ────────────────────────────────────────── */
console.log('\nTradução de ida e volta');
{
  const original = {
    salaoId:'s1', clienteId:'c1', profissionalId:'p1', inicio:'2026-08-20T12:00:00Z',
    fim:'2026-08-20T13:00:00Z', status:'confirmado', origem:'online',
    atendidoNome:'João', valorPrevisto:50, criadoEm:'2026-08-15T00:00:00Z',
  };
  const noBanco = D.paraBanco('agendamentos', original);
  dizer(noBanco.salao_id === 's1' && noBanco.atendido_nome === 'João'
        && noBanco.valor_previsto === 50,
    'camelCase vira snake_case na ida');

  const devolta = D.paraTela('agendamentos', noBanco);
  dizer(JSON.stringify(devolta) === JSON.stringify(original),
    'e volta exatamente igual — nada se perde no caminho');
}

console.log('\nCampos que são só da tela não vão para o banco');
{
  // `servicos` do agendamento vira linhas em agendamento_servicos; mandar
  // esse array junto faria o PostgREST recusar a gravação inteira.
  const comExtras = { salaoId:'s1', inicio:'x', servicos:[{a:1}] };
  const noBanco = D.paraBanco('agendamentos', comExtras);
  dizer(!('servicos' in noBanco),
    'agendamentos.servicos fica de fora (vira agendamento_servicos)');

  const comanda = D.paraBanco('comandas',
    { salaoId:'s1', itens:[], pagamentos:[], numero:7, desconto:0 });
  dizer(!('itens' in comanda) && !('pagamentos' in comanda) && !('numero' in comanda),
    'comandas: itens, pagamentos e numero ficam de fora');
  dizer(comanda.desconto === 0, 'mas desconto passa — e o zero não some');
}

/* ── CAMPO VAZIO EM COLUNA QUE NÃO É TEXTO ────────────────────────────────
   Um <input> em branco devolve `''`, nunca null. Numa coluna de data, número
   ou uuid, isso derruba a gravação inteira:

       clientes: invalid input syntax for type date: ""

   Apareceu ao cadastrar um cliente sem data de nascimento — campo opcional
   impedindo o cadastro. O `paraBanco()` passou a traduzir `''` para null
   nessas colunas, e esta seção existe para a lista dele não envelhecer: ela
   sai do schema, não da memória de quem escreveu.
   ──────────────────────────────────────────────────────────────────────── */
console.log('\nColuna que não é texto: vazio da tela vira null');
{
  const ESCRITAS = D.TABELAS_SINCRONIZADAS.concat(['assinaturas']);
  const TEXTO = /^(text|varchar|char|jsonb|json|bytea)/;

  const faltando = [];
  for(const t of ESCRITAS){
    for(const c of (tabelasComTipo[t] || [])){
      if(!c.nulo) continue;                     // obrigatória: erro é outro
      if(TEXTO.test(c.tipo)) continue;          // em texto, '' é um valor
      if(c.nome === 'id') continue;             // nunca vai vazio
      if(!D.VAZIO_E_NULO.has(c.nome)) faltando.push(t + '.' + c.nome + ' (' + c.tipo + ')');
    }
  }
  dizer(faltando.length === 0,
    faltando.length ? 'faltam em VAZIO_E_NULO: ' + faltando.join(', ')
                    : 'toda coluna anulável que não é texto está em VAZIO_E_NULO');

  const cli = D.paraBanco('clientes', { nome:'Jucelia', nascimento:'', obs:'' });
  dizer(cli.nascimento === null, 'nascimento em branco vira null');
  dizer(cli.obs === '', 'mas observação em branco continua texto vazio — apagar é intenção');
  const cli2 = D.paraBanco('clientes', { nascimento:'1990-05-02' });
  dizer(cli2.nascimento === '1990-05-02', 'e a data preenchida passa intacta');
}

/* ── DINHEIRO CHEGA COMO TEXTO ────────────────────────────────────────────
   O PostgREST devolve `numeric` como string, para não perder precisão. O
   JavaScript aceita e faz outra coisa: `0 + '80.00' + '45.00'` é
   '080.0045.00'. Total de comanda e comissão saem daí.

   O `paraTela()` converte, e esta seção existe para a lista dele não
   envelhecer: ela sai do schema, não da memória de quem escreveu. */
console.log('\nColuna numérica vira número, não texto');
{
  const LIDAS = D.TABELAS_SINCRONIZADAS.concat(['planos','assinaturas','perfis','vinculos']);
  const NUM = /^(numeric|decimal|real|double)/;
  const faltando = [];
  for(const t of LIDAS){
    for(const c of (tabelasComTipo[t] || [])){
      if(NUM.test(c.tipo) && !D.NUMERICAS.has(c.nome)) faltando.push(t + '.' + c.nome);
    }
  }
  dizer(faltando.length === 0,
    faltando.length ? 'faltam em NUMERICAS: ' + faltando.join(', ')
                    : 'toda coluna numérica está em NUMERICAS');

  const s = D.paraTela('servicos', { preco: '80.00', comissao_pct: '40.00', nome: 'Corte' });
  dizer(typeof s.preco === 'number' && s.preco === 80, 'preço "80.00" vira o número 80');
  dizer(s.nome === 'Corte', 'e o texto continua texto');
  dizer(0 + s.preco + 45 === 125, 'e agora soma em vez de concatenar');

  const v = D.paraTela('servicos', { comissao_pct: null });
  dizer(v.comissaoPct === null,
    'null continua null — "sem comissão definida" não é "comissão zero"');
}

console.log('\nO identificador que a tela cunha serve para o banco');
{
  // Era 'x' + base36 — "xxe7qkwou" — e toda coluna id é uuid. Nada criado
  // pelo painel chegava ao banco.
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const ids = new Set();
  let todosValidos = true;
  for(let i = 0; i < 500; i++){
    const v = D.novoId();
    if(!uuid.test(v)) todosValidos = false;
    ids.add(v);
  }
  dizer(todosValidos, 'novoId() devolve uuid v4, que é o tipo da coluna');
  dizer(ids.size === 500, 'e 500 seguidos saem todos diferentes');
}

console.log('\nCampo indefinido não vira null no banco');
{
  const r = D.paraBanco('clientes', { salaoId:'s1', nome:'Ana', email: undefined });
  dizer(!('email' in r),
    'undefined é omitido (mandar null apagaria o que já estava lá)');
  const r2 = D.paraBanco('clientes', { salaoId:'s1', obs: null });
  dizer(r2.obs === null, 'mas null explícito passa, porque limpar é intencional');
}

console.log('\n' + (falhas
  ? `✗ ${falhas} problema(s) — corrija antes de ligar no Supabase.`
  : `✓ ${ok} verificações, o mapa bate com o schema.`));
process.exit(falhas ? 1 : 0);
