-- Auxiliares dos testes. Carregado antes de cada arquivo .test.sql.
--
-- Falha para o script inteiro (o \set ON_ERROR_STOP dos testes cuida disso):
-- teste que só avisa baixinho vira paisagem, e paisagem ninguém lê.

create or replace function t_falha(msg text) returns void
language plpgsql as $$ begin raise exception '✗ %', msg; end $$;

create or replace function t_ok(msg text) returns void
language plpgsql as $$ begin raise notice '  ✓ %', msg; end $$;

create or replace function t_igual(msg text, obtido bigint, esperado bigint)
returns void language plpgsql as $$
begin
  if obtido = esperado then perform t_ok(msg);
  else perform t_falha(format('%s — esperava %s, veio %s', msg, esperado, obtido));
  end if;
end $$;

-- Roda um comando e diz se o banco RECUSOU.
--
-- Cuidado ao ler um `recusado()` verde: ele não distingue "barrou pela regra
-- que eu queria testar" de "quebrou por erro de digitação no SQL". Quando o
-- caso for importante, confira também o efeito — foi o que o teste de
-- super_admin faz, olhando o valor depois da tentativa.
create or replace function recusado(sql text) returns boolean
language plpgsql as $$
begin
  execute sql;
  return false;
exception when others then
  return true;
end $$;

-- Asserção booleana. `t_igual` só serve para número, e escrever
-- `count(*) = 1` para conferir uma condição deixa o teste ilegível.
create or replace function t_verdade(msg text, cond boolean) returns void
language plpgsql as $$
begin
  if cond then perform t_ok(msg);
  else perform t_falha(format('%s — esperava verdadeiro', msg));
  end if;
end $$;

create or replace function t_falso(msg text, cond boolean) returns void
language plpgsql as $$
begin
  if not cond then perform t_ok(msg);
  else perform t_falha(format('%s — esperava falso', msg));
  end if;
end $$;

-- Igualdade de texto. Usada para conferir a MENSAGEM da recusa, não só que
-- houve recusa: `recusado()` fica verde tanto quando a regra barrou quanto
-- quando o SQL do próprio teste tinha um erro de digitação.
create or replace function t_texto(msg text, obtido text, esperado text)
returns void language plpgsql as $$
begin
  if obtido is not distinct from esperado then perform t_ok(msg);
  else perform t_falha(format('%s — esperava «%s», veio «%s»',
                              msg, coalesce(esperado,'null'), coalesce(obtido,'null')));
  end if;
end $$;

-- Roda um comando e devolve a MENSAGEM do erro (null se passou). É o
-- `recusado()` com olhos: prova que barrou pelo motivo certo.
create or replace function erro_de(sql text) returns text
language plpgsql as $$
begin
  execute sql;
  return null;
exception when others then
  return sqlerrm;
end $$;
