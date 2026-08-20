/* ===========================================================================
   AgendaPro — o funil de cadastro, dirigido como gente dirige

     python3 -m http.server 8099 --directory .
     PLAYWRIGHT=.../node_modules/playwright node tests/cadastro.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   Já havia um teste que levava o cadastro do passo 1 ao 3. Ele passava, e o
   cadastro estava quebrado assim mesmo: o teste preenchia os campos com
   `fill()`, que grava o valor de uma vez, e usava uma senha que por acaso
   tinha números. A regra escondida — "misture letras e números", que nenhum
   texto na tela mencionava — nunca foi exercitada.

   Aqui os campos são DIGITADOS, tecla por tecla, e com o que uma pessoa de
   verdade escreve. É a diferença entre provar que o caminho existe e provar
   que ele é caminhável.
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';

const BASE = process.env.BASE || 'http://127.0.0.1:8099/';
let passou = 0, falhou = 0;

const ok = (m) => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c) => c ? ok(m) : nao(m, 'esperava verdadeiro');

const nav = await chromium.launch({ executablePath: CHROMIUM });

// Uma aba limpa por caso: o cadastro grava no localStorage, e o salão que um
// caso cria faria o próximo recusar o apelido por já estar em uso.
async function abrir() {
  const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 } });
  const p = await ctx.newPage();
  p.erros = [];
  p.on('pageerror', e => p.erros.push(e.message));
  p.on('console', m => { if (m.type() === 'error') p.erros.push(m.text()); });
  await p.goto(BASE + 'criar.html');
  await p.waitForTimeout(300);
  return p;
}

const digitar = (p, sel, txt) => p.click(sel).then(() => p.type(sel, txt, { delay: 8 }));
const passoAtual = p => p.evaluate(() =>
  [...document.querySelectorAll('.passo')].findIndex(e => e.classList.contains('on')) + 1);
const erroDe = (p, id) => p.evaluate(i => {
  const e = document.getElementById('e-' + i);
  return e && getComputedStyle(e).display !== 'none' ? e.textContent.trim() : '';
}, id);

async function preencherConta(p, { nome, email, senha }) {
  await digitar(p, '#fNome', nome);
  await digitar(p, '#fEmail', email);
  await digitar(p, '#fSenha', senha);
  await p.click('button.grande:has-text("Continuar")');
  await p.waitForTimeout(250);
}

console.log('\nPasso 1 — a conta');

// O CASO QUE ESTAVA QUEBRADO. Senha de treze letras, sem número: é o que a
// maioria das pessoas escreve quando o campo pede "pelo menos 8 caracteres".
{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro Prado',
    email: 'alessandro@studioprado.com.br', senha: 'minhasenhaboa' });
  igual('senha só de letras avança — não existe regra escondida de número',
    await passoAtual(p), 2);
  igual('e nenhum erro fica pendurado no campo', await erroDe(p, 'fSenha'), '');
  await p.context().close();
}

{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro Prado',
    email: 'alessandro@studioprado.com.br', senha: 'S3nh4!com#tudo' });
  igual('senha com número e símbolo também avança', await passoAtual(p), 2);
  await p.context().close();
}

{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro Prado',
    email: 'alessandro@studioprado.com.br', senha: 'curta12' });
  igual('senha de 7 caracteres NÃO avança', await passoAtual(p), 1);
  igual('e diz o motivo, com o número exato',
    await erroDe(p, 'fSenha'), 'A senha precisa de pelo menos 8 caracteres.');
  await p.context().close();
}

// A outra regra que não estava escrita em lugar nenhum.
{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro',
    email: 'alessandro@studioprado.com.br', senha: 'minhasenhaboa' });
  igual('nome sem sobrenome não avança', await passoAtual(p), 1);
  verdade('e o campo já avisava disso antes, no texto do lugar vazio',
    (await p.getAttribute('#fNome', 'placeholder')).toLowerCase().includes('sobrenome'));
  await p.context().close();
}

{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro Prado',
    email: 'alessandro@studioprado', senha: 'minhasenhaboa' });
  igual('e-mail sem domínio não avança', await passoAtual(p), 1);
  await p.context().close();
}

// TODA regra que barra tem que estar escrita na tela antes de barrar. Este é
// o teste que teria pego o defeito original sozinho: ele compara o que o
// campo PROMETE com o que a regra COBRA.
{
  const p = await abrir();
  const promessa = (await p.getAttribute('#fSenha', 'placeholder')).toLowerCase();
  const cobra = await p.evaluate(() => ({
    // Uma senha longa que atende tudo que o texto do campo pede.
    aceitaSoLetras: REGRAS.fSenha('abcdefghijkl') === '',
  }));
  verdade('o campo de senha promete um tamanho mínimo', /8|oito/.test(promessa));
  verdade('e o que ele promete é tudo o que ele cobra', cobra.aceitaSoLetras);
  await p.context().close();
}

console.log('\nO medidor de força');

{
  const p = await abrir();
  const ler = async (senha) => {
    await p.fill('#fSenha', '');
    await digitar(p, '#fSenha', senha);
    return p.textContent('#sTexto');
  };
  igual('doze letras: "boa"',      (await ler('abcdefghijkl')).trim(), 'boa');
  igual('oito letras: "fraca"',    (await ler('abcdefgh')).trim(),     'fraca');
  igual('quatro letras: "curta"',  (await ler('abcd')).trim(),         'curta');
  igual('longa com número e símbolo: "forte"',
    (await ler('abcdefghijkl9!')).trim(), 'forte');

  // O medidor ACONSELHA; quem barra é a regra de tamanho. Se ele barrasse
  // também, "fraca" seria uma porta fechada sem placa.
  await p.fill('#fSenha', '');
  await digitar(p, '#fSenha', 'abcdefgh');
  await p.click('button.grande:has-text("Continuar")');
  await p.waitForTimeout(150);
  igual('senha marcada como "fraca" ainda é aceita — o medidor não é porta',
    await erroDe(p, 'fSenha'), '');
  await p.context().close();
}

console.log('\nO funil inteiro');

{
  const p = await abrir();
  await preencherConta(p, { nome: 'Alessandro Prado',
    email: 'alessandro@studioprado.com.br', senha: 'minhasenhaboa' });
  await digitar(p, '#fSalao', 'Studio Prado');
  await p.selectOption('#fTipo', { index: 1 });
  await digitar(p, '#fZap', '51998876655');
  await p.waitForTimeout(200);

  verdade('o link aparece enquanto se digita o nome do salão',
    (await p.textContent('.previa-link')).includes('studio-prado'));

  await p.click('button.grande:has-text("Criar minha agenda")');
  await p.waitForTimeout(900);
  igual('chega no passo 3', await passoAtual(p), 3);
  verdade('e entrega o link pronto',
    (await p.textContent('#linkFinal')).includes('salao=studio-prado'));
  verdade('dizendo o que acontece depois dos 7 dias',
    (await p.textContent('#textoPronto')).includes('plano grátis'));

  igual('nenhum erro de JavaScript no caminho todo', p.erros.length, 0);
  await p.context().close();
}

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de cadastro.`);
