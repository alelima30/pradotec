/* ===========================================================================
   AgendaPro — o aviso de pagamento do Mercado Pago
   Supabase Edge Function (Deno). Roda NO SERVIDOR, nunca no navegador.

   ── ESTE É O ENDEREÇO MAIS EXPOSTO DO SISTEMA ──────────────────────────────
   Ele é público por obrigação: o Mercado Pago precisa alcançá-lo sem login.
   Ou seja, QUALQUER PESSOA NA INTERNET pode fazer POST aqui dizendo "a
   cobrança tal foi paga". Se este arquivo acreditar no que recebe, o produto
   é de graça para quem souber escrever um curl.

   Por isso são DUAS conferências, e nenhuma delas confia no corpo do aviso:

     1. ASSINATURA. O Mercado Pago manda `x-signature` com um HMAC-SHA256 do
        aviso, feito com um segredo que só nós e ele temos. Sem bater, é 401.

     2. A FONTE. Mesmo com a assinatura boa, o corpo do aviso não é usado como
        verdade: ele diz só o ID do pagamento. Status e valor são LIDOS DA API
        do Mercado Pago, com o nosso token. Assim, mesmo que a assinatura
        vazasse um dia, ainda seria preciso que o pagamento existisse e
        estivesse aprovado lá.

   E a terceira trava não está aqui — está no banco. `registrar_pagamento()`
   é idempotente: o Mercado Pago reenvia o mesmo aviso até receber 200, e
   reenvia de novo a cada mudança do pagamento. Cada chegada somando um mês
   daria meio ano de assinatura a quem pagou uma vez.

   ── POR QUE QUASE TUDO RESPONDE 200 ────────────────────────────────────────
   Aviso que não é nosso, pagamento que não está aprovado, cobrança que não
   existe: tudo isso é 200. Responder erro faz o Mercado Pago reenviar em
   escala crescente por dias. O 401 é reservado para o que interessa — aviso
   com assinatura errada, que é tentativa de fraude e tem que constar no log.
   =========================================================================== */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_TOKEN     = Deno.env.get('MP_ACCESS_TOKEN')!;
// Segredo do webhook, copiado do painel do Mercado Pago ao cadastrar a URL.
const MP_SEGREDO   = Deno.env.get('MP_WEBHOOK_SECRET') ?? '';

const rpc = async (nome: string, args: unknown) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if(!r.ok) throw new Error(`${nome}: ${r.status} ${await r.text()}`);
  return r.json();
};

/* ── A CONFERÊNCIA DA ASSINATURA ────────────────────────────────────────────
   Mora em `assinatura.js`, ao lado, e não aqui dentro — porque precisa rodar
   também no Node, no tests/webhook-assinatura.test.js. É a função que separa
   "o Mercado Pago avisou que pagaram" de "alguém escreveu que pagaram", num
   endereço que é público por obrigação: deixá-la presa dentro de um arquivo
   que só o Deno executa seria a parte mais crítica do sistema sendo a única
   sem teste. */
import { assinaturaConfere } from './assinatura.js';

Deno.serve(async (req) => {
  if(req.method !== 'POST') return new Response('ok', { status: 200 });

  try{
    const url = new URL(req.url);
    const corpo = await req.json().catch(() => ({}));

    // O id do pagamento pode vir na querystring ou no corpo, dependendo do
    // tipo de aviso. O da querystring é o que entra no manifesto assinado.
    const dataId = String(
      url.searchParams.get('data.id') ?? corpo?.data?.id ?? '');
    const tipo = String(url.searchParams.get('type') ?? corpo?.type ?? '');

    if(!dataId) return new Response('sem id', { status: 200 });

    const confere = await assinaturaConfere({
      segredo: MP_SEGREDO,
      xSignature: req.headers.get('x-signature'),
      xRequestId: req.headers.get('x-request-id'),
      dataId,
    });
    if(!confere){
      if(!MP_SEGREDO) console.error('MP_WEBHOOK_SECRET não configurado.');
      console.error('webhook-mp: assinatura inválida', { tipo, dataId });
      return new Response('assinatura inválida', { status: 401 });
    }

    // Só interessa aviso de pagamento. `merchant_order` e o resto chegam
    // junto e não movem assinatura nenhuma.
    if(tipo && tipo !== 'payment') return new Response('ok', { status: 200 });

    /* ── A FONTE ────────────────────────────────────────────────────────────
       Aqui o corpo do aviso deixa de importar. Status e valor vêm da API. */
    const r = await fetch(`https://api.mercadopago.com/v1/payments/${dataId}`, {
      headers: { Authorization: `Bearer ${MP_TOKEN}` } });
    if(!r.ok){
      console.error('webhook-mp: não consegui ler o pagamento', dataId, r.status);
      // 500 para o Mercado Pago tentar de novo: pode ter sido rede.
      return new Response('erro ao ler', { status: 500 });
    }
    const pg = await r.json();

    const resultado = await rpc('registrar_pagamento', {
      p_mp_id: String(pg.id),
      p_valor: Number(pg.transaction_amount),
      p_status: String(pg.status ?? ''),
    });

    // O log guarda o resultado, nunca o pagamento inteiro: ele traz nome,
    // e-mail e documento de quem pagou.
    console.log('webhook-mp', dataId, JSON.stringify(resultado));
    return new Response('ok', { status: 200 });

  }catch(e){
    console.error('webhook-mp falhou:', String(e).slice(0, 300));
    return new Response('erro', { status: 500 });
  }
});
