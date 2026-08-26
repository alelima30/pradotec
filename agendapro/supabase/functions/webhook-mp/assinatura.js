/* ===========================================================================
   AgendaPro — a conferência da assinatura do aviso do Mercado Pago

   ── POR QUE ESTE ARQUIVO É .js E NÃO .ts ───────────────────────────────────
   Porque ele precisa rodar nos DOIS lados: o Deno importa daqui, e o teste
   (tests/webhook-assinatura.test.js) importa exatamente o mesmo arquivo, no
   Node. Sem build, sem transpilar, sem duas cópias.

   E precisa ser testado. Esta função é o que separa "o Mercado Pago avisou
   que pagaram" de "alguém na internet escreveu que pagaram" — o endereço do
   webhook é público por obrigação. Uma cópia dela num arquivo que ninguém
   consegue executar fora do Deno seria a parte mais crítica do sistema sendo
   a única sem teste.

   Usa só WebCrypto, que Deno e Node 20+ têm nativamente.
   =========================================================================== */

/* O texto que o Mercado Pago assinou, exatamente nesta ordem e com estes
   pontos-e-vírgulas. Errar um caractere aqui faz TODO aviso legítimo ser
   recusado — e o sintoma seria "ninguém consegue assinar", dias depois. */
export function manifesto(dataId, requestId, ts){
  return `id:${String(dataId).toLowerCase()};request-id:${requestId};ts:${ts};`;
}

/* ⚠ Comparar com `===` vaza, pelo tempo, o tamanho do prefixo que bateu. É
   pouco por tentativa, e é explorável em cima de um endereço que aceita
   tentativas ilimitadas. Comparação de tamanho fixo custa nada. */
export function iguaisEmTempoConstante(a, b){
  if(typeof a !== 'string' || typeof b !== 'string') return false;
  if(a.length !== b.length) return false;
  let dif = 0;
  for(let i = 0; i < a.length; i++) dif |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return dif === 0;
}

export async function hmacHex(segredo, texto){
  const chave = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(segredo),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const bruto = await crypto.subtle.sign(
    'HMAC', chave, new TextEncoder().encode(texto));
  return [...new Uint8Array(bruto)]
    .map(b => b.toString(16).padStart(2, '0')).join('');
}

/* A conferência inteira. Devolve true só quando TUDO bate.

   `agoraMs` entra por parâmetro para o teste poder envelhecer um aviso sem
   mexer no relógio da máquina. */
export async function assinaturaConfere(
  { segredo, xSignature, xRequestId, dataId, agoraMs = Date.now(),
    janelaSegundos = 600 }){

  /* Sem segredo configurado não há o que conferir. Recusar é o certo: aceitar
     deixaria o endereço aberto justamente enquanto ninguém terminou de
     configurar — que é quando ninguém está olhando. */
  if(!segredo) return false;
  if(!xSignature || !dataId) return false;

  const partes = new Map();
  for(const p of String(xSignature).split(',')){
    const i = p.indexOf('=');
    if(i < 0) continue;
    partes.set(p.slice(0, i).trim(), p.slice(i + 1).trim());
  }
  const ts = partes.get('ts');
  const v1 = partes.get('v1');
  if(!ts || !v1) return false;

  /* Janela de tempo. Sem ela, um aviso legítimo capturado hoje pode ser
     reenviado daqui a um ano e a assinatura continuaria válida — para sempre.
     A idempotência do banco já cobriria o estrago, mas defesa em profundidade
     custa cinco linhas. */
  const idade = Math.abs(agoraMs / 1000 - Number(ts));
  if(!Number.isFinite(idade) || idade > janelaSegundos) return false;

  const meu = await hmacHex(segredo,
    manifesto(dataId, xRequestId ?? '', ts));
  return iguaisEmTempoConstante(meu, v1);
}
