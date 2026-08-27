/* ===========================================================================
   AgendaPro — o webhook do Mercado Pago não acredita em quem bate na porta

     node tests/webhook-assinatura.test.js

   O endereço do webhook é público por obrigação: o Mercado Pago precisa
   alcançá-lo sem login. Ou seja, qualquer pessoa na internet pode fazer POST
   nele dizendo que a cobrança tal foi paga. O que separa o aviso de verdade
   do curl de qualquer um é uma função só — e é esta.

   Este arquivo importa o MESMO módulo que o Deno importa. Não é uma cópia da
   lógica: é a lógica.
   =========================================================================== */
import { assinaturaConfere, hmacHex, manifesto, iguaisEmTempoConstante }
  from '../supabase/functions/webhook-mp/assinatura.js';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const falso   = (m, c, d) => !c ? ok(m) : nao(m, d);
const secao = t => console.log('\n' + t);

const SEGREDO = 'segredo-do-painel-do-mercado-pago';
const ID = '1234567890';
const REQ = 'req-abc-123';
const AGORA = 1767225600000;                     // um instante fixo, em ms

// Assina como o Mercado Pago assinaria.
async function avisoDeVerdade(
  { segredo = SEGREDO, dataId = ID, requestId = REQ, ts = Math.floor(AGORA/1000) } = {}){
  const v1 = await hmacHex(segredo, manifesto(dataId, requestId, ts));
  return { xSignature: `ts=${ts},v1=${v1}`, xRequestId: requestId, dataId };
}

const confere = (extra) => assinaturaConfere(
  { segredo: SEGREDO, agoraMs: AGORA, ...extra });

/* ══════════════════════════════════════════════════════════════════════════
   1. O AVISO LEGÍTIMO PASSA
   Sem esta primeira asserção, todas as recusas abaixo ficariam verdes com uma
   função que devolvesse `false` sempre — e ninguém conseguiria assinar.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O aviso de verdade passa');
verdade('assinatura correta é aceita', await confere(await avisoDeVerdade()));

// O Mercado Pago manda o cabeçalho com espaços em volta das vírgulas às
// vezes; o manifesto é o mesmo.
{
  const a = await avisoDeVerdade();
  const [ts, v1] = a.xSignature.split(',');
  verdade('e com espaços entre as partes também',
    await confere({ ...a, xSignature: `${ts} , ${v1}` }));
}

/* ══════════════════════════════════════════════════════════════════════════
   2. O QUE TEM QUE SER RECUSADO
   ══════════════════════════════════════════════════════════════════════════ */
secao('O que não passa');

falso('assinatura vazia', await confere({ ...await avisoDeVerdade(), xSignature: '' }));
falso('assinatura inventada',
  await confere({ ...await avisoDeVerdade(), xSignature: 'ts=1767225600,v1=deadbeef' }));

// Assinada com OUTRO segredo: é o caso de quem descobriu o formato mas não a
// chave. É o ataque realista.
verdade('assinado com outro segredo é recusado',
  !await confere(await avisoDeVerdade({ segredo: 'chutei-o-segredo' })));

/* ⚠ TROCAR O ID DEPOIS DE ASSINAR.
   O ataque mais provável não é forjar assinatura do zero: é pegar um aviso
   legítimo (o de uma cobrança de R$ 57 que a pessoa pagou de verdade) e
   trocar o id para o de outra cobrança. Se o id não entrasse no manifesto,
   funcionaria. */
{
  const a = await avisoDeVerdade();
  falso('aviso legítimo com o id trocado é recusado',
    await confere({ ...a, dataId: '9999999999' }));
}

// Idem para o request-id, que também está dentro do manifesto.
{
  const a = await avisoDeVerdade();
  falso('e com o request-id trocado também',
    await confere({ ...a, xRequestId: 'outro-request' }));
}

// Sem `v1` ou sem `ts` o cabeçalho não é assinatura nenhuma.
falso('cabeçalho sem v1',
  await confere({ ...await avisoDeVerdade(), xSignature: 'ts=1767225600' }));
falso('cabeçalho sem ts',
  await confere({ ...await avisoDeVerdade(), xSignature: 'v1=abc' }));
falso('cabeçalho que não é par chave=valor',
  await confere({ ...await avisoDeVerdade(), xSignature: 'lixo' }));

/* ══════════════════════════════════════════════════════════════════════════
   3. A JANELA DE TEMPO
   Um aviso legítimo capturado hoje não pode valer para sempre.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O aviso envelhece');

verdade('um aviso de 5 minutos atrás ainda vale',
  await confere(await avisoDeVerdade({ ts: Math.floor(AGORA/1000) - 300 })));
falso('um de 20 minutos atrás não',
  await confere(await avisoDeVerdade({ ts: Math.floor(AGORA/1000) - 1200 })));
falso('nem um assinado no futuro',
  await confere(await avisoDeVerdade({ ts: Math.floor(AGORA/1000) + 1200 })));
falso('ts que não é número',
  await confere({ ...await avisoDeVerdade(), xSignature: 'ts=ontem,v1=abc' }));

/* ══════════════════════════════════════════════════════════════════════════
   4. SEM SEGREDO CONFIGURADO, NADA PASSA
   É o estado em que o sistema fica entre subir a função e cadastrar a URL no
   painel do Mercado Pago. Se "sem segredo" significasse "aceita tudo", o
   endereço ficaria aberto exatamente enquanto ninguém está olhando.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Sem segredo configurado');

falso('sem MP_WEBHOOK_SECRET, o aviso é recusado',
  await assinaturaConfere({ ...await avisoDeVerdade(), segredo: '', agoraMs: AGORA }));
falso('e nem um aviso perfeito passa',
  await assinaturaConfere({ ...await avisoDeVerdade(), segredo: undefined, agoraMs: AGORA }));

/* ══════════════════════════════════════════════════════════════════════════
   5. A COMPARAÇÃO É DE TAMANHO FIXO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A comparação não vaza pelo tempo');

verdade('iguais dão true', iguaisEmTempoConstante('abcdef', 'abcdef'));
falso('tamanhos diferentes dão false', iguaisEmTempoConstante('abc', 'abcdef'));
falso('mesmo tamanho e conteúdo diferente dá false',
  iguaisEmTempoConstante('abcdef', 'abcdeg'));
falso('e nada que não seja texto passa', iguaisEmTempoConstante(null, null));

/* O manifesto tem formato exato: errar um caractere faria TODO aviso
   legítimo ser recusado, e o sintoma apareceria dias depois como "ninguém
   consegue assinar". */
secao('O formato do manifesto');
const m = manifesto('ABC123', 'req-1', 1767225600);
verdade('id em minúsculas, na ordem certa, com os pontos-e-vírgulas',
  m === 'id:abc123;request-id:req-1;ts:1767225600;', m);

console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
