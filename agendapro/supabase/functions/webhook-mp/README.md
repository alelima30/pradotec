# A cobrança pelo Mercado Pago — como colocar no ar

Duas funções, e as duas rodam **no servidor**:

| Pasta | O que faz |
|---|---|
| `criar-cobranca` | o dono clica em assinar → abre o Pix (ou o boleto) |
| `webhook-mp` | o Mercado Pago avisa que pagou → a assinatura passa a valer |

Elas existem porque um segredo não pode chegar ao navegador de jeito nenhum:

| Segredo | O que ele dá a quem tiver |
|---|---|
| `MP_ACCESS_TOKEN` | criar cobrança e **mover dinheiro** na sua conta |
| `MP_WEBHOOK_SECRET` | forjar avisos de pagamento — assinar de graça |
| `SUPABASE_SERVICE_ROLE_KEY` | ler e escrever **tudo**, por cima de todo o RLS |

O painel é HTML servido do GitHub Pages. Tudo o que chega nele é público —
não existe "esconder" ali.

---

## 1. Do lado do Mercado Pago

1. Entre em **[Suas integrações](https://www.mercadopago.com.br/developers/panel)**
   e crie uma aplicação (tipo: **Pagamentos online**, modelo **CheckoutAPI**).
2. Em **Credenciais de produção**, copie o **Access Token**
   (`APP_USR-...`). É o `MP_ACCESS_TOKEN`.
3. Em **Webhooks**, cadastre a URL da função:

   ```
   https://SEU_REF.supabase.co/functions/v1/webhook-mp
   ```

   Marque o evento **Pagamentos** (`payment`). Ao salvar, o Mercado Pago
   mostra uma **assinatura secreta** — copie. É o `MP_WEBHOOK_SECRET`, e ele
   só aparece nesse momento.

> **Comece pelas credenciais de teste.** Elas começam com `TEST-`, e o
> Mercado Pago tem usuários de teste para pagar sem dinheiro de verdade.
> Troque para as de produção só depois que um pagamento de teste ativar uma
> assinatura de ponta a ponta.

### Pix precisa da chave cadastrada

Pix só funciona com uma **chave Pix cadastrada na conta Mercado Pago** e a
conta com os dados fiscais completos. Sem isso a criação da cobrança volta
com erro, e o painel mostra "o Mercado Pago não aceitou a cobrança agora" —
que é a mensagem certa para o dono, mas não diz o motivo. **O motivo aparece
no log da função**, no painel do Supabase.

### Boleto exige CPF/CNPJ e e-mail

O AgendaPro já pede o documento no cadastro do salão (fica em
`documentos_cobranca`, com RLS próprio) e a borda lê de lá — o navegador
nunca vê. Se o cadastro estiver sem documento ou sem e-mail, o boleto é
recusado com uma mensagem explicando, e o Pix continua funcionando.

**Sobre boleto, uma conta que vale fazer antes:** a tarifa é fixa por boleto
emitido. Numa mensalidade de R$ 47 ela pesa bem mais, em porcentagem, do que
numa de R$ 297 — e o boleto ainda compensa em até 3 dias úteis, então o salão
fica sem o plano enquanto espera. Confira a tarifa vigente na sua conta e
decida se vale manter o botão para os planos de entrada.

---

## 2. Instalar

Com a [CLI do Supabase](https://supabase.com/docs/guides/cli):

```bash
supabase functions deploy criar-cobranca --project-ref SEU_REF
# O webhook é chamado pelo Mercado Pago, que não manda JWT nenhum:
supabase functions deploy webhook-mp --project-ref SEU_REF --no-verify-jwt
```

> `--no-verify-jwt` **só** no `webhook-mp`. Ele precisa aceitar requisição sem
> login — quem confere a autenticidade é a assinatura HMAC, dentro da função.
> Passar essa opção no `criar-cobranca` seria abrir o checkout para qualquer
> um.

E o SQL, que você cola no **SQL Editor** do Supabase:

```
supabase/13_cobranca.sql
```

(ou o `98_modulos.sql`, que já traz este junto com os outros módulos).

---

## 3. As variáveis de ambiente

Supabase → **Edge Functions** → **Secrets**:

| Nome | Onde achar |
|---|---|
| `MP_ACCESS_TOKEN` | Mercado Pago → Suas integrações → Credenciais |
| `MP_WEBHOOK_SECRET` | Mercado Pago → Webhooks → assinatura secreta |
| `MP_WEBHOOK_URL` | `https://SEU_REF.supabase.co/functions/v1/webhook-mp` |
| `SUPABASE_URL` | já vem preenchida |
| `SUPABASE_ANON_KEY` | já vem preenchida |
| `SUPABASE_SERVICE_ROLE_KEY` | já vem preenchida |
| `PAINEL_ORIGEM` | opcional: `https://seu-usuario.github.io` |

`PAINEL_ORIGEM` fecha o CORS no endereço do seu painel. Sem ela, o padrão é
`*` — o que não abre nada sozinho (a borda continua exigindo token de sessão
válido), mas é uma porta a menos deixar preenchida.

> **Se faltar `MP_WEBHOOK_SECRET`, o webhook recusa TUDO** e responde 401.
> É de propósito: "sem segredo configurado" não pode significar "aceita
> qualquer aviso", porque esse é justamente o estado em que ninguém está
> olhando ainda.

---

## 4. A renovação, que o Pix não faz sozinho

Cartão recorrente cobra sozinho. Pix não — alguém precisa lembrar o dono
antes de vencer. O `13_cobranca.sql` traz as duas funções para isso:

- `assinaturas_a_vencer(dias)` — quem vence nos próximos N dias e ainda não
  tem cobrança aberta;
- `vencer_cobrancas()` — a faxina: Pix que passou da validade vira `vencida`,
  liberando o dono para pedir outro.

Uma vez por dia, pelo `pg_cron` (SQL Editor):

```sql
select cron.schedule('faxina-cobrancas', '10 4 * * *',
  $$select public.vencer_cobrancas()$$);
```

O aviso ao dono usa o worker de WhatsApp que já existe — as mensagens de
renovação são `tipo = 'aviso'`, não `'promocao'`, então saem também para quem
pediu para não receber promoção. Cobrança não é marketing.

---

## 5. Conferir que está de pé

```bash
node tests/webhook-assinatura.test.js          # a conferência da assinatura
PLAYWRIGHT=... node tests/cobranca.test.mjs    # o checkout, no navegador
bash tests/rodar.sh                            # cobranca.test.sql, no banco
```

E o primeiro pagamento de verdade, de ponta a ponta:

1. assine com as credenciais `TEST-` e um usuário de teste do Mercado Pago;
2. veja o log de `webhook-mp` no Supabase — tem que aparecer
   `{"ok":true,...}`;
3. confira `select status, plano, vence_em from assinaturas where salao_id = ...`.

Se o log mostrar `assinatura inválida`, o `MP_WEBHOOK_SECRET` está diferente
do que o Mercado Pago cadastrou — é o erro mais comum, e o certo é ele
recusar.

---

## O que este desenho protege, e como

| Ataque | O que segura |
|---|---|
| escolher o próprio preço | o valor é lido de `planos` **no banco**; o navegador manda só o código do plano |
| chamar `registrar_pagamento` pelo console | a função é negada a `anon` e `authenticated` |
| editar `assinaturas` direto | policy de escrita exige `is_super()`; o salão só tem `select` |
| forjar o aviso de pagamento | HMAC-SHA256 com `MP_WEBHOOK_SECRET`, janela de 10 min, comparação em tempo constante |
| reenviar um aviso legítimo | `cobrancas.mp_id` é único e `registrar_pagamento` é idempotente |
| trocar o id dentro de um aviso legítimo | o id entra no texto assinado |
| mentir no corpo do aviso | status e valor são relidos da API do Mercado Pago, não do corpo |
| pagar R$ 1 numa cobrança de R$ 297 | o valor é conferido contra o gravado antes de ativar |
| assinar pelo salão dos outros | `abrir_cobranca` confere o vínculo de quem pediu |
