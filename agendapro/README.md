# AgendaPro

Sistema de agendamento para salão de beleza, barbearia, manicure e estética.
Irmão do [AdminPro](https://github.com/alelima30/adminpro): mesma stack —
HTML/CSS/JS puro, sem build, backend Supabase, PWA instalável — com as dívidas
daquele projeto corrigidas de saída.

**Estado: banco pronto e testado; app rodando com dados de demonstração.**
Falta ligar os dois — hoje a tela guarda no navegador, não no Supabase.

---

## O que já está aqui

| Arquivo | O que faz |
|---|---|
| `app.html` | O aplicativo: agenda, clientes, serviços, equipe, caixa e página pública |
| `index.html` | Encaminha a raiz para o app |
| `sw.js` + `manifest.webmanifest` | PWA — instala no celular e no computador |
| `supabase/01_schema.sql` | 16 tabelas, a trava anti-choque da agenda, comanda e comissão |
| `supabase/02_rls.sql` | Isolamento entre salões e entre papéis — a segurança de verdade |
| `tests/` | 49 verificações rodando em Postgres de verdade |

## Como testar

**A tela** — abra `app.html` no navegador. Já vem com dois salões, cinco
profissionais, dez serviços e a agenda de hoje preenchida. Tudo fica no
`localStorage`; o botão **Recomeçar** devolve ao estado inicial.

Para instalar como aplicativo é preciso servir por http, porque navegador não
registra service worker em `file://`:

```bash
cd agendapro && python3 -m http.server 8000
# abra http://localhost:8000  →  botão "Instalar app"
```

**O banco** — precisa de um Postgres alcançável:

```bash
bash tests/rodar.sh
PGHOST=localhost PGPORT=5432 bash tests/rodar.sh
```

**No Supabase** — rode `01_schema.sql` e `02_rls.sql` no SQL Editor, depois
cole `tests/conferir_instalacao.sql` e clique em Run. Ele devolve onze linhas
✓/✗ dizendo se a instalação ficou de pé (RLS ligado, trava presente, vitrine
aberta, nenhuma tabela exposta para quem não fez login).

## O que dá para conferir na tela

- **Multi-salão** — troque de salão no seletor do topo: agenda, clientes e
  serviços mudam junto, e um não enxerga o outro
- **A grade entende serviço** — mecha ocupa 3h, corte ocupa 1h; o listrado
  marca fora da jornada e o hachurado marca almoço
- **Conflito** — tente marcar em cima de alguém e o aviso aparece antes de salvar
- **Ver como cliente** — a mesma agenda vista de fora: só os horários livres,
  sem nome nem telefone de ninguém. Dia cheio sugere os próximos com vaga
- **Comanda** — clique num atendimento, abra a comanda, some produto e veja a
  comissão sair por item

## As três decisões que definem o projeto

**1. Um login, vários salões.** No AdminPro a pessoa pertence a um condomínio
— uma coluna `condominio_id` resolve. Aqui não: a mesma cliente corta o cabelo
na barbearia e faz unha no salão da esquina, com o mesmo telefone. Então a
identidade é global (`perfis`, uma linha por telefone) e o pertencimento é uma
tabela à parte (`vinculos`), com papel por salão. As policies perguntam *"você
tem vínculo com este salão, e em que papel?"*, não *"qual é o seu salão?"*.

**2. Horário duplicado é impossível, e não por educação do JavaScript.** O
AdminPro confere conflito no navegador (`hrConflita`), então duas recepcionistas
clicando junto marcam o mesmo horário — nenhuma das duas telas sabe da outra.
Aqui a recusa é do banco, por uma constraint `EXCLUDE USING gist` sobre
`tstzrange`. Não fura por corrida, nem chamando a API direto, nem com o
JavaScript desligado.

**3. Nada de `modulo_dados`.** O AdminPro guarda metade do sistema como um
bloco JSON por módulo, e a própria documentação dele reconhece o custo: dois
admins salvando junto, o último apaga o trabalho do primeiro, e nada disso tem
teste. Aqui tudo é tabela, coluna e chave desde o primeiro dia.

## O que o cliente enxerga (e o que não enxerga)

O ponto mais fácil de errar. Uma policy do tipo `using (tem_acesso(salao_id))`
parece certa na tela e vaza a clientela inteira: basta chamar a API REST do
Supabase pelo navegador, sem passar pelo nosso app.

| Quem | Alcança |
|---|---|
| Cliente | Os agendamentos **dele**, a ficha **dele**, a conta **dele**. Horário livre vem de função que devolve horários, não linhas. |
| Profissional | A agenda dele e a comissão dele. Não vê o que a colega ganhou. |
| Recepção / dono | Tudo do próprio salão. |
| Outro salão | Nada. Nem uma linha. |
| Sem login | Só a vitrine: nome, serviços, preços e quem atende. |

Cada uma dessas linhas é um teste em `tests/02_rls.test.sql`, rodando com
`set role authenticated` — que é como o Supabase trata um JWT. Sem trocar o
papel, o teste rodaria como superusuário e passaria por cima do RLS: verde
mentiroso, o pior tipo.

## Dois bugs que os testes pegaram antes de existir tela

Ficam registrados porque são armadilhas que voltam.

**`for all` reabre a leitura restrita.** Uma policy `for all` vale também para
SELECT, e o Postgres soma as permissivas com OU. Uma policy de escrita da
equipe ao lado de uma policy de leitura restrita anula a restrição — a
profissional voltava a ver a agenda das colegas e a comissão delas. Escrita vai
separada por verbo: `for insert`, `for update`, `for delete`.

**Policies que se citam entram em recursão.** A de `comandas` consultava
`comanda_itens`, cuja policy consultava `comandas` de volta:
`infinite recursion detected in policy`. O ciclo se rompe com funções
`security definer`, que não passam pelo RLS.

## O que falta

1. **Ligar a tela no Supabase.** Hoje o app grava no `localStorage`. A troca
   acontece num lugar só — o bloco `ARMAZENAMENTO` no fim do `app.html`, com
   `salvar()` e `carregar()`. O resto da página conversa por funções e não
   fica sabendo de onde vem o dado.
2. `03_funcoes_agenda.sql` — `horarios_livres()` e `agendar()` no banco. A
   versão que está no `app.html` é de tela: serve para desenhar, não para
   garantir. Cliente marcando precisa passar por função `security definer`,
   senão escolhe o próprio preço e o horário das 3 da manhã.
3. Cadastro por telefone com código no WhatsApp, via
   [Send SMS Hook](https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook)
   do Supabase — ele gera, valida e expira o código; a Edge Function só
   entrega. Template de autenticação da Meta é pago por mensagem, então limite
   de reenvio por número desde o primeiro dia.
4. CI com Postgres de serviço, rodando `tests/rodar.sh` a cada envio.
5. Sinal por Pix, pacotes e fidelidade — os campos de sinal já existem na
   tabela `agendamentos`, vazios.

## Onde este código vai morar

Hoje ele está numa pasta do repositório `pradotec`, numa branch de trabalho —
não encosta no site que está no ar. É tudo arquivo estático: quando virar
produto, é copiar a pasta para um repositório próprio e apontar o Pages.
