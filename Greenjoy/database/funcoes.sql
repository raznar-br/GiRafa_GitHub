-- funcoes.sql — funções auxiliares. Aplicar antes de qualquer arquivo de views.

-- Data corrente no fuso da loja. O Postgres do Supabase roda em UTC, então
-- CURRENT_DATE já virou o dia seguinte a partir das 21h BRT — o que criava um dia
-- futuro vazio nas séries diárias e distorcia janelas móveis.
CREATE OR REPLACE FUNCTION hoje_br() RETURNS DATE
LANGUAGE sql STABLE AS $$
    SELECT (NOW() AT TIME ZONE 'America/Sao_Paulo')::DATE
$$;

GRANT EXECUTE ON FUNCTION hoje_br() TO anon, authenticated;

-- Moeda em pt-BR para textos gerados no banco (ações do CMV).
-- TO_CHAR sozinho usa o lc_numeric do servidor (US) e devolvia "3,672.87".
-- O 0 na casa das unidades garante "0,40" em vez de ",40".
CREATE OR REPLACE FUNCTION brl(v NUMERIC) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT REPLACE(REPLACE(REPLACE(
               TO_CHAR(COALESCE(v, 0), 'FM999G999G990D00'),
           '.', '#'), ',', '.'), '#', ',')
$$;

GRANT EXECUTE ON FUNCTION brl(NUMERIC) TO anon, authenticated;

-- Chave de comparação sem acento e sem caixa, para fundir variantes de grafia
-- ('Proteinas'/'Proteínas', 'bebidas'/'Bebidas'). Usa translate em vez da extensão
-- unaccent, que não está instalada neste projeto.
CREATE OR REPLACE FUNCTION chave_texto(s TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT TRANSLATE(LOWER(TRIM(COALESCE(s, ''))),
                     'áàâãäéèêëíìîïóòôõöúùûüçñ',
                     'aaaaaeeeeiiiiooooouuuucn')
$$;

GRANT EXECUTE ON FUNCTION chave_texto(TEXT) TO anon, authenticated;
