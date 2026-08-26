/* ===========================================================================
   AgendaPro — nenhum segredo pode estar num arquivo que o navegador baixa

     node tests/segredos.test.js

   ── POR QUE ESTE ARQUIVO EXISTE ────────────────────────────────────────────
   O painel é HTML estático servido do GitHub Pages. Tudo o que está nele é
   público: não existe "esconder" ali, existe "ainda não procuraram".

   A chave `anon` do Supabase pode aparecer — ela é feita para isso, e quem
   protege o dado é o RLS. As outras não podem, e cada uma tem um estrago
   próprio:

     service_role / sb_secret_  → passa por cima de TODO o RLS. Um salão lê a
                                  clientela de todos os outros.
     WHATSAPP_TOKEN             → manda mensagem em nome do salão até alguém
                                  revogar, e a conta paga.

   O módulo de campanhas foi o primeiro a ter credencial de verdade neste
   projeto. Esta suíte é a trava para ela nunca escorregar do servidor para o
   navegador numa correção apressada — inclusive numa minha.
   =========================================================================== */
const fs = require('node:fs');
const path = require('node:path');

const RAIZ = path.dirname(__dirname);
let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);

/* Tudo o que o navegador baixa. `supabase/functions/` fica FORA de propósito:
   é o único lugar do projeto que roda no servidor, e é lá que os segredos
   devem estar. */
function arquivosDoNavegador(dir, achados = []){
  for(const nome of fs.readdirSync(dir)){
    if(['.git','node_modules','dist','icones'].includes(nome)) continue;
    const caminho = path.join(dir, nome);
    const st = fs.statSync(caminho);
    if(st.isDirectory()){
      // A pasta das funções de borda não é servida ao navegador.
      if(caminho.includes(path.join('supabase','functions'))) continue;
      arquivosDoNavegador(caminho, achados);
    }else if(/\.(html|js|mjs|css|json|webmanifest)$/.test(nome)){
      /* Este arquivo fica de fora, e só ele: as iscas lá embaixo são
         segredos falsos de propósito, e sem esta linha a varredura acusa a si
         mesma. `tests/` inteiro continua sendo varrido — o GitHub Pages serve
         a pasta junto com o resto, e uma chave esquecida num teste vaza
         igual. */
      if(path.resolve(caminho) !== path.resolve(__filename)) achados.push(caminho);
    }
  }
  return achados;
}

const PROIBIDOS = [
  // A chave secreta do Supabase, nos dois formatos que ela já teve.
  { nome: 'chave service_role (JWT)', re: /"?role"?\s*:\s*"service_role"/ },
  { nome: 'chave secreta nova (sb_secret_)', re: /\bsb_secret_[A-Za-z0-9_-]{8,}/ },
  // Token da Cloud API da Meta. Os de usuário e de sistema começam com EAA.
  { nome: 'token do WhatsApp (EAA...)', re: /\bEAA[A-Za-z0-9]{40,}/ },
  { nome: 'WHATSAPP_TOKEN com valor', re: /WHATSAPP_TOKEN\s*[:=]\s*['"][^'"]{8,}/ },
  { nome: 'segredo de webhook com valor', re: /(webhook|verify)[_-]?(token|secret)\s*[:=]\s*['"][^'"]{8,}/i },
];

console.log('\nNenhum segredo nos arquivos que o navegador baixa');
{
  const arquivos = arquivosDoNavegador(RAIZ);
  verdade(`há arquivos para varrer (${arquivos.length})`, arquivos.length > 10,
    'varredura que não abre nada passa sempre');

  const achados = [];
  for(const f of arquivos){
    const txt = fs.readFileSync(f, 'utf8');
    for(const p of PROIBIDOS){
      if(p.re.test(txt)) achados.push(`${path.relative(RAIZ, f)}: ${p.nome}`);
    }
  }
  verdade('nenhum segredo encontrado', achados.length === 0, achados.join('; '));
}

/* A varredura acima só vale se ela SABE achar. Um regex quebrado devolve
   lista vazia, que é idêntica a "está tudo limpo" — e foi assim que uma
   varredura deste projeto já ficou verde sem varrer nada. */
console.log('\nA varredura sabe achar o que procura');
{
  const iscas = [
    ['{"role":"service_role","iss":"supabase"}', 'chave service_role (JWT)'],
    ['const k = "sb_secret_abcdefgh12345678";', 'chave secreta nova (sb_secret_)'],
    ['EAA' + 'x'.repeat(45), 'token do WhatsApp (EAA...)'],
    ['WHATSAPP_TOKEN: "EAAGxyz123456"', 'WHATSAPP_TOKEN com valor'],
  ];
  for(const [texto, esperado] of iscas){
    const pegou = PROIBIDOS.filter(p => p.re.test(texto)).map(p => p.nome);
    verdade(`pega a isca: ${esperado}`, pegou.includes(esperado),
      `pegou ${JSON.stringify(pegou)}`);
  }
  // E não pode acender à toa: a chave publicável PODE estar no config.js.
  const publicavel = 'const chave = "sb_publishable_abc123def456";';
  verdade('e NÃO acusa a chave publicável, que pode estar lá',
    PROIBIDOS.every(p => !p.re.test(publicavel)));
}

console.log('\nO worker lê os segredos do ambiente, nunca de arquivo');
{
  const f = path.join(RAIZ, 'supabase/functions/enviar-campanha/index.ts');
  verdade('a função de borda existe', fs.existsSync(f));
  if(fs.existsSync(f)){
    const txt = fs.readFileSync(f, 'utf8');
    for(const v of ['WHATSAPP_TOKEN','WHATSAPP_PHONE_ID','SUPABASE_SERVICE_ROLE_KEY']){
      verdade(`${v} vem de Deno.env`,
        new RegExp(`Deno\\.env\\.get\\(['"]${v}['"]\\)`).test(txt));
    }
    for(const p of PROIBIDOS){
      verdade(`e nenhum valor de ${p.nome} está escrito nela`, !p.re.test(txt));
    }
    // Log com o token dentro vaza o segredo para quem lê o painel de logs.
    verdade('não há console.log do cabeçalho nem do corpo da requisição',
      !/console\.(log|info)\s*\(\s*(req|corpo|headers)/.test(txt));
  }
}

console.log('');
if(falhou === 0){ console.log(`✓ ${passou} verificações de segredos.`); }
else { console.log(`✗ ${falhou} falha(s) em ${passou + falhou} verificações.`); }
process.exit(falhou ? 1 : 0);
