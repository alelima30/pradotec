/* ===========================================================================
   AgendaPro — abrir a cobrança do plano no Mercado Pago
   Supabase Edge Function (Deno). Roda NO SERVIDOR, nunca no navegador.

   ── AS DUAS CREDENCIAIS QUE SÓ EXISTEM AQUI ────────────────────────────────
     MP_ACCESS_TOKEN            cria cobrança e move dinheiro em nome da conta
     SUPABASE_SERVICE_ROLE_KEY  passa por cima de TODO o RLS

   Nenhuma das duas pode encostar no painel. O painel é HTML servido do GitHub
   Pages: tudo o que chega nele é público por construção, e um access token do
   Mercado Pago vazado é acesso à conta que recebe o dinheiro.

   ── O QUE ELA FAZ, E EM QUE ORDEM ──────────────────────────────────────────
     1. confere QUEM está pedindo, pelo token de sessão do painel
     2. abre a cobrança no BANCO, que lê o preço da tabela de planos
     3. pede o Pix (ou o boleto) ao Mercado Pago
     4. guarda o copia-e-cola e devolve para a tela

   ── ⚠ O VALOR NUNCA VEM DO CORPO DA REQUISIÇÃO ─────────────────────────────
   O navegador manda `salaoId` e `plano`. Não manda preço, e se mandasse seria
   ignorado: quem lê `planos.preco_mes` é `abrir_cobranca()`, no banco. É a
   diferença entre um checkout e um formulário onde o cliente digita quanto
   quer pagar.

   ── ⚠ E A SESSÃO É VERIFICADA, NÃO ACREDITADA ──────────────────────────────
   O `Authorization` que chega é o JWT do painel. Ele é conferido contra o
   `/auth/v1/user` do próprio Supabase — assinatura, validade e tudo — e o
   uuid que VOLTA de lá é o que vai para `abrir_cobranca(p_quem)`. Ler o uuid
   de dentro do token sem verificar seria aceitar um JWT montado à mão.
   =========================================================================== */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;
const MP_TOKEN     = Deno.env.get('MP_ACCESS_TOKEN')!;
// Para onde o Mercado Pago avisa que pagou. Sem isto a cobrança nasce e
// ninguém nunca fica sabendo que foi paga.
const MP_WEBHOOK   = Deno.env.get('MP_WEBHOOK_URL') ?? '';

const CORS = {
  'Access-Control-Allow-Origin': Deno.env.get('PAINEL_ORIGEM') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });

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

/* Quem está pedindo. Devolve o uuid do perfil, ou null.

   ⚠ Não decodifica o JWT aqui. Um JWT é base64 legível: qualquer pessoa monta
   um com o `sub` que quiser. Quem diz se ele é válido é o servidor que o
   assinou. */
async function quemPediu(auth: string | null): Promise<string | null> {
  if(!auth || !auth.startsWith('Bearer ')) return null;
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: auth },
  });
  if(!r.ok) return null;
  const u = await r.json();
  return u?.id ?? null;
}

Deno.serve(async (req) => {
  if(req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if(req.method !== 'POST') return responder({ erro: 'method' }, 405);

  try{
    const quem = await quemPediu(req.headers.get('Authorization'));
    if(!quem) return responder({ erro: 'Faça login de novo.' }, 401);

    const corpo = await req.json().catch(() => ({}));
    const salaoId = String(corpo.salaoId ?? '');
    const plano   = String(corpo.plano ?? '');
    const metodo  = corpo.metodo === 'boleto' ? 'boleto' : 'pix';
    if(!salaoId || !plano) return responder({ erro: 'Faltou o salão ou o plano.' }, 400);

    /* A cobrança nasce no banco, com o preço lido lá. Se esta pessoa não for
       gestão deste salão, `abrir_cobranca` recusa e a gente para aqui — a
       autorização é do banco, não deste arquivo. */
    let cobranca;
    try{
      cobranca = await rpc('abrir_cobranca', {
        p_salao: salaoId, p_plano: plano, p_metodo: metodo, p_quem: quem });
    }catch(e){
      // Mensagem do banco (plano inexistente, sem permissão) volta como 403:
      // é sempre uma das duas, e nenhuma é erro nosso.
      console.error('abrir_cobranca recusou', String(e).slice(0, 200));
      return responder({ erro: 'Não consegui abrir a cobrança.' }, 403);
    }

    // Já tinha uma cobrança aberta com o Pix pronto? Devolve ela, sem bater no
    // Mercado Pago de novo.
    if(cobranca?.mp_id){
      return responder({ ok: true, cobranca: paraTela(cobranca) });
    }

    /* ── O pedido ao Mercado Pago ────────────────────────────────────────────
       `external_reference` é o id da NOSSA cobrança. É por ele que o webhook
       reencontra a linha — e é por isso que ele não pode ser o id do salão:
       dois meses do mesmo salão precisam ser dois pagamentos distintos.

       `X-Idempotency-Key` também é o id da cobrança: se esta função for
       chamada duas vezes (o dono clicou duas vezes, a rede repetiu), o
       Mercado Pago devolve o MESMO pagamento em vez de criar dois. */
    /* ⚠ O PAGADOR VEM DO BANCO, NÃO DA TELA.
       Boleto exige nome, e-mail e CPF/CNPJ do pagador. O CPF já foi dado no
       cadastro e mora em `documentos_cobranca`, com RLS próprio. Pedir de
       novo no navegador faria o documento do dono trafegar num formulário
       toda vez que ele pagasse a mensalidade — sendo que a gente já tem. */
    const pagador = await rpc('dados_do_pagador', { p_salao: salaoId });
    const doc = String(pagador?.documento ?? '').replace(/\D/g, '');

    if(metodo === 'boleto' && (!doc || !pagador?.email)){
      return responder({ erro: 'Para boleto preciso do CPF/CNPJ e do e-mail do '
        + 'responsável no cadastro. Pague no Pix, ou fale com o suporte para '
        + 'completar o cadastro.' }, 400);
    }

    const nomeInteiro = String(pagador?.nome ?? '').trim();
    const corte = nomeInteiro.indexOf(' ');

    const vence = new Date(cobranca.vence_em);
    const pedido: Record<string, unknown> = {
      transaction_amount: Number(cobranca.valor),
      description: `AgendaPro — plano ${cobranca.plano}`,
      external_reference: cobranca.id,
      payment_method_id: metodo === 'boleto' ? 'bolbradesco' : 'pix',
      date_of_expiration: vence.toISOString(),
      payer: {
        email: pagador?.email ?? undefined,
        first_name: corte > 0 ? nomeInteiro.slice(0, corte) : (nomeInteiro || undefined),
        last_name:  corte > 0 ? nomeInteiro.slice(corte + 1) : undefined,
        identification: doc
          ? { type: doc.length === 14 ? 'CNPJ' : 'CPF', number: doc }
          : undefined,
      },
    };
    if(MP_WEBHOOK) pedido.notification_url = MP_WEBHOOK;

    const r = await fetch('https://api.mercadopago.com/v1/payments', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${MP_TOKEN}`,
        'X-Idempotency-Key': cobranca.id,
      },
      body: JSON.stringify(pedido),
    });
    const mp = await r.json().catch(() => ({}));

    if(!r.ok){
      /* ⚠ O ERRO DO MERCADO PAGO NÃO VAI INTEIRO PARA A TELA.
         Ele às vezes ecoa parte do pedido, e o pedido carrega e-mail do
         pagador. Vai para o log do servidor; a tela recebe uma frase. */
      console.error('MP recusou', r.status, JSON.stringify(mp).slice(0, 400));
      return responder({ erro: 'O Mercado Pago não aceitou a cobrança agora. '
        + 'Tente de novo em alguns minutos.' }, 502);
    }

    const tx = mp?.point_of_interaction?.transaction_data ?? {};
    await rpc('anotar_cobranca', {
      p_id: cobranca.id,
      p_mp_id: String(mp.id),
      p_mp_status: String(mp.status ?? ''),
      p_pix: tx.qr_code ?? null,
      p_qr: tx.qr_code_base64 ?? null,
      p_boleto: mp?.transaction_details?.external_resource_url ?? null,
      p_linha: mp?.barcode?.content ?? null,
    });

    return responder({ ok: true, cobranca: paraTela({
      ...cobranca,
      pix_copia_cola: tx.qr_code ?? null,
      pix_qr_base64:  tx.qr_code_base64 ?? null,
      boleto_url: mp?.transaction_details?.external_resource_url ?? null,
      linha_digitavel: mp?.barcode?.content ?? null,
    })});

  }catch(e){
    // Nunca `console.error(req)` nem o corpo: leva token de sessão para o log.
    console.error('criar-cobranca falhou:', String(e).slice(0, 300));
    return responder({ erro: 'Não consegui abrir a cobrança agora.' }, 500);
  }
});

/* O que a tela recebe. Nem `mp_status`, nem quem abriu, nem nada que não seja
   necessário para pagar — resposta enxuta é resposta que não vaza. */
function paraTela(c: Record<string, unknown>){
  return {
    id: c.id, plano: c.plano, valor: c.valor, metodo: c.metodo,
    venceEm: c.vence_em,
    pixCopiaCola: c.pix_copia_cola ?? null,
    pixQrBase64:  c.pix_qr_base64 ?? null,
    boletoUrl: c.boleto_url ?? null,
    linhaDigitavel: c.linha_digitavel ?? null,
  };
}
