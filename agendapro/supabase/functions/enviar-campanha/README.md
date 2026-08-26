# O worker das campanhas — como colocar no ar

Esta pasta é a **única** parte do AgendaPro que roda no servidor. Ela existe
porque duas credenciais não podem chegar ao navegador de jeito nenhum:

| Segredo | O que ele dá a quem tiver |
|---|---|
| `WHATSAPP_TOKEN` | mandar mensagem em nome do seu número |
| `SUPABASE_SERVICE_ROLE_KEY` | ler e escrever **tudo**, por cima de todo o RLS |

O painel do dono é HTML servido do GitHub Pages. Tudo o que chega nele é
público — não existe "esconder" ali. Por isso o disparo mora aqui.

---

## 1. Antes de tudo, do lado da Meta

A Cloud API não é uma API de disparo livre. Para **campanha de marketing** ela
exige:

- Conta **Meta Business verificada**;
- Um **número dedicado** ao WhatsApp Business Platform — ele deixa de
  funcionar no aplicativo comum do celular;
- **Template aprovado** pela Meta. Marketing só sai por template. Texto livre
  só chega em quem falou com o seu número nas últimas **24 horas**.

O template precisa ter **um parâmetro no corpo**, que é o nome da cliente.
Exemplo do que cadastrar na Meta:

```
Olá {{1}}! Estamos com novidade no salão esta semana.
Responda esta mensagem para agendar.
```

Anote o **nome** do template e o **idioma** (`pt_BR`). São eles que você
digita ao criar a campanha.

Há custo por conversa iniciada. Confira a tabela da Meta para o Brasil antes
de disparar para a base inteira.

---

## 2. Instalar

Com a [CLI do Supabase](https://supabase.com/docs/guides/cli):

```bash
supabase functions deploy enviar-campanha --project-ref SEU_REF
```

## 3. Os segredos

**Nunca** num arquivo do repositório. Só aqui:

```bash
supabase secrets set \
  WHATSAPP_TOKEN=EAAG...            \
  WHATSAPP_PHONE_ID=1234567890      \
  --project-ref SEU_REF
```

`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` o Supabase já injeta sozinho nas
funções de borda — não precisa declarar.

Se você usa um token temporário da Meta (24h), ele vai expirar e a fila vai
parar com erro `190`. Para produção, gere um **token de sistema permanente**.

---

## 4. Chamar de tempos em tempos

O worker faz **uma volta curta por chamada** e para sozinho perto dos 55
segundos — função de borda tem teto de tempo, e função que roda para sempre é
função que morre no meio e deixa linha presa em `processando`.

Quem chama de novo é o `pg_cron`. No **SQL Editor** do Supabase:

```sql
-- Uma vez só, para ligar as duas extensões.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- A cada minuto, empurra a fila.
select cron.schedule(
  'campanhas-whatsapp',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://SEU_REF.functions.supabase.co/enviar-campanha',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || current_setting('app.service_key', true)),
    body    := '{}'::jsonb);
  $$);
```

E guarde a chave de serviço **no banco**, não no texto da tarefa — assim ela
não aparece para quem lista as tarefas do cron:

```sql
alter database postgres set app.service_key = 'SUA_SERVICE_ROLE_KEY';
```

Quando não há campanha rodando, a chamada volta em milissegundos sem fazer
nada. Não custa cota da Meta.

---

## 5. Conferir que está de pé

```sql
-- A fila de agora.
select c.nome, d.status, count(*)
  from public.campanha_destinatarios d
  join public.campanhas c on c.id = d.campanha_id
 group by 1, 2 order by 1;

-- As últimas chamadas do cron.
select * from cron.job_run_details order by start_time desc limit 10;
```

---

## 6. O que este worker NÃO faz, de propósito

- **Não decide quem recebe.** Isso é do banco (`publico_da_campanha`), que
  respeita o opt-out e o isolamento por salão.
- **Não repete mensagem.** Quem garante é a trava `ux_camp_dest` mais o
  `for update skip locked` do `fila_proxima()`. O worker pode ser reiniciado
  no meio sem risco.
- **Não registra segredo em log.** Só a frase de erro da Meta. Corpo e
  cabeçalho da requisição nunca vão para o `console`.
