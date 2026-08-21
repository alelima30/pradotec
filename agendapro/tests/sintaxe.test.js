/* ===========================================================================
   AgendaPro — o JavaScript de cada tela precisa ao menos COMPILAR

     node tests/sintaxe.test.js

   POR QUE ESTE ARQUIVO EXISTE
   Escrevi um comentário assim, dentro de um template literal:

       <!-- o campo `profissionais.foto` já existia esperando -->

   As crases fecharam a string no meio do HTML, e o script inteiro do painel
   deixou de compilar. A tela não abria — nem um pedaço dela.

   O que me contou não foi um teste do painel: foi o teste de IMAGENS, numa
   linha que diz "nenhum erro de JavaScript na página", com a mensagem
   "missing ) after argument list". Diagnóstico de raspão, na suíte errada,
   apontando para o arquivo errado.

   Um erro de sintaxe não merece investigação: merece uma linha dizendo o
   arquivo e o número. É o teste mais barato daqui e o que falha mais cedo.
   =========================================================================== */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const RAIZ = path.dirname(__dirname);
const TELAS = ['app.html', 'agendar.html', 'criar.html', 'entrar.html',
               'admin.html', 'index.html', 'nova-senha.html'];
const AVULSOS = ['dados.js', 'demo.js', 'imagens.js', 'icones.js',
                 'endereco.js', 'config.js', 'sw.js'];

let ok = 0, falhas = 0;
const dizer = (bom, msg, extra) => {
  if(bom){ ok++; console.log('  ✓ ' + msg); }
  else { falhas++; console.log('  ✗ ' + msg + (extra ? '\n      ' + extra : '')); }
};

// Onde cada <script> começa no arquivo, para o número da linha do erro bater
// com o número da linha no HTML — senão o recado manda procurar no lugar
// errado, que é o vício que este arquivo existe para não repetir.
function scriptsDe(texto){
  const achados = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m;
  while((m = re.exec(texto)) !== null){
    achados.push({ codigo: m[1], linha: texto.slice(0, m.index).split('\n').length });
  }
  return achados;
}

console.log('\nO JavaScript embutido em cada tela compila');
for(const tela of TELAS){
  const caminho = path.join(RAIZ, tela);
  if(!fs.existsSync(caminho)){ dizer(false, tela + ' não existe'); continue; }
  const texto = fs.readFileSync(caminho, 'utf8');
  const blocos = scriptsDe(texto);
  let problema = null;
  for(const b of blocos){
    try{
      new vm.Script(b.codigo, { filename: tela });
    }catch(e){
      // A linha que o motor reporta é relativa ao bloco; somada ao começo do
      // bloco, vira a linha do arquivo que se abre no editor.
      const dentro = Number((String(e.stack).match(/<anonymous>:(\d+)|:(\d+)\n/) || [])[1] || 0);
      problema = e.message + (dentro ? ' — perto da linha ' + (b.linha + dentro) + ' de ' + tela : '');
      break;
    }
  }
  dizer(!problema, tela + ' compila', problema);
}

console.log('\nE os arquivos .js soltos');
for(const arq of AVULSOS){
  const caminho = path.join(RAIZ, arq);
  if(!fs.existsSync(caminho)){ dizer(false, arq + ' não existe'); continue; }
  try{
    new vm.Script(fs.readFileSync(caminho, 'utf8'), { filename: arq });
    dizer(true, arq + ' compila');
  }catch(e){ dizer(false, arq + ' compila', e.message); }
}

/* ── A ARMADILHA QUE CAUSOU ISTO ──────────────────────────────────────────
   Comentário HTML dentro de template literal é normal e útil — explica o
   markup ali onde ele é escrito. O que não pode é conter crase, porque a
   crase não sabe que está dentro de um comentário: ela fecha a string.

   O teste acima já pegaria, mas só depois do estrago. Este aponta o lugar. */
console.log('\nCrase dentro de comentário HTML embutido');
for(const tela of TELAS){
  const caminho = path.join(RAIZ, tela);
  if(!fs.existsSync(caminho)) continue;
  const texto = fs.readFileSync(caminho, 'utf8');
  const suspeitos = [];
  for(const b of scriptsDe(texto)){
    const re = /<!--[\s\S]*?-->/g;
    let m;
    while((m = re.exec(b.codigo)) !== null){
      if(m[0].includes('`')){
        suspeitos.push('linha ~' + (b.linha + b.codigo.slice(0, m.index).split('\n').length));
      }
    }
  }
  dizer(suspeitos.length === 0,
    tela + ': nenhum comentário embutido com crase',
    suspeitos.join(', '));
}

console.log('\n' + (falhas
  ? `✗ ${falhas} problema(s) de sintaxe.`
  : `✓ ${ok} verificações de sintaxe.`));
process.exit(falhas ? 1 : 0);
