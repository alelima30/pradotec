# Como testar o AgendaPro

Dois caminhos. O primeiro não precisa de nada instalado; o segundo liga no
Supabase de verdade.

---

## 1. Sem instalar nada (5 minutos)

Baixe a pasta inteira e abra **`app.html`** no navegador.

Já vem com dois salões, cinco profissionais, dez serviços e a agenda de hoje
preenchida. Tudo fica guardado no próprio navegador. O botão **Recomeçar**
devolve ao estado inicial quando você bagunçar.

Os três aplicativos, na ordem em que a vida acontece:

| Arquivo | Quem usa |
|---|---|
| `criar.html` | o dono, para abrir a conta |
| `app.html` | o salão: agenda, clientes, caixa, plano |
| `agendar.html?salao=studio-bella` | o cliente, para marcar |

Vale conferir:

- Troque de salão no seletor do topo — um não enxerga o outro
- Clique num espaço vazio da agenda; tente marcar em cima de alguém
- Aba **Ver como cliente** → copie o link → abra `agendar.html`
- Abra `agendar.html?salao=barbearia-do-ze`: o tema fica escuro e dourado, e
  o sistema passa a dizer "barbeiro" em vez de "profissional"
- Um dia cheio oferece a **lista de espera**
- Aba **Plano**: a Barbearia do Zé está com o teste vencendo e 2
  profissionais num limite de 1, para você ver o aviso

Para instalar como aplicativo (ícone na tela inicial), precisa servir por
http — navegador não registra service worker em `file://`:

```bash
cd agendapro && python3 -m http.server 8000
# abra http://localhost:8000 → botão "Instalar app"
```

---

## 2. Ligado no Supabase de verdade

### Passo 1 — criar o projeto

Em [supabase.com](https://supabase.com), crie um projeto (o plano grátis
serve). Anote a senha do banco.

### Passo 2 — instalar o banco

No painel: **SQL Editor → New query**. Cole **`supabase/00_tudo.sql`**
inteiro e clique em **Run**.

Pode rodar mais de uma vez sem medo — o arquivo é feito para isso.

### Passo 3 — conferir a instalação

Ainda no SQL Editor, cole **`tests/conferir_instalacao.sql`** e rode.

Devem sair **11 linhas, todas com ✓**. Qualquer ✗ traz junto o que fazer.
Não siga com um ✗ na tela: significa que o app vai se comportar de um jeito
que os testes não previram.

### Passo 4 — apontar o app para o projeto

Em **Settings → API**, copie os dois valores e cole no **`config.js`**:

```js
window.AGENDAPRO = {
  url:   'https://xxxxxxxx.supabase.co',
  chave: 'eyJhbGciOi...',        // a chave "anon / public"
  ambiente: 'produção',
};
```

> A chave anônima pode ficar aí à vista: não é segredo. Quem protege os
> dados é o RLS dentro do banco. A chave **`service_role`** é outra coisa e
> nunca entra em arquivo que vai para o navegador — ela passa por cima de
> todo o RLS.

Pronto. Sem preencher, o sistema roda em demonstração; preenchido, ele fala
com o banco. Nada mais muda.

### Passo 5 — usar

Sirva a pasta por http (o navegador bloqueia várias coisas em `file://`):

```bash
cd agendapro && python3 -m http.server 8000
```

Abra `http://localhost:8000/criar.html`, crie sua conta e siga. O salão, a
assinatura em teste, seu vínculo de dono e o primeiro profissional nascem
juntos, numa transação só.

### O que ainda falta configurar no Supabase

- **Código por WhatsApp.** Em Authentication → Providers, ligue Phone. A
  entrega pelo WhatsApp exige o *Send SMS Hook* apontando para uma Edge
  Function com a Cloud API da Meta. Sem isso, o login por telefone não sai
  do lugar — mas o login por email e senha (o do dono) já funciona.
- **Lembretes automáticos.** Dependem de `pg_cron` e de uma Edge Function,
  como no AdminPro.

---

## 3. Os testes automáticos

Precisa de Postgres e Node na máquina.

```bash
# 1) O banco: regras, isolamento, travas — 90 verificações
bash tests/rodar.sh

# 2) O mapa de colunas bate com o schema — 96 verificações
node tests/colunas.test.js

# 3) A camada de dados contra um Postgres de verdade — 33 verificações
bash tests/bancada/subir.sh      # num terminal
node tests/nuvem.test.mjs        # noutro
```

A **bancada** (`tests/bancada/`) é um PostgREST caseiro apontando para um
Postgres local com o schema instalado. Não é o Supabase, mas é o mesmo
Postgres, o mesmo schema e as mesmas policies — que é onde mora o risco.

Foi ela que pegou três bugs que nenhum outro teste pegaria:

1. **O cabeçalho `Authorization` sumia nas gravações.** Um `Object.assign`
   deixava o `Prefer` do insert substituir o objeto de cabeçalhos inteiro.
   O banco tratava o dono como visitante anônimo e recusava — só na
   gravação, nunca na leitura.
2. **Faltava a policy que deixa o cliente criar a própria ficha.** O
   autoatendimento nunca funcionaria em produção; na demonstração passava
   porque não existe RLS.
3. **A chave primária de `saloes` estava sendo renomeada** na tradução, o
   que deixava `bd.saloes[0].id` indefinido e a agenda abria vazia.

---

## Se der errado

| O que aparece | O que é |
|---|---|
| Tela em branco | Abra o console (F12). Quase sempre é `config.js` com url ou chave errada. |
| "permission denied for table X" | O `00_tudo.sql` não rodou inteiro. Rode de novo e confira com o `conferir_instalacao.sql`. |
| "Entre para ver sua agenda" | Está no modo nuvem sem login. Vá em `criar.html`. |
| "Não consegui salvar no banco" | A mensagem depois dos dois-pontos vem do Postgres e diz o motivo — costuma ser limite de plano ou choque de horário. |
| O rodapé diz "demonstração" | O `config.js` está vazio; é o esperado antes do passo 4. |
