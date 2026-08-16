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
      const c = linha.match(/^([a-z_][a-z0-9_]*)\s+/i);
      if(c) colunas.push(c[1]);
    }
    tabelas[nome] = colunas;
  }
  return tabelas;
}

const tabelas = lerTabelas(sql);

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
