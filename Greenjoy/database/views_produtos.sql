-- views_produtos.sql
-- Reescreve sobre mv_produto_dia as três views que estouravam o statement_timeout.
-- Colunas mantidas iguais às originais para não quebrar o frontend.

-- ============================================================
-- kpi_top_produtos_venda — card de top produtos da home
-- ============================================================
DROP VIEW IF EXISTS kpi_top_produtos_venda;
CREATE VIEW kpi_top_produtos_venda AS
SELECT
    cod_item,
    produto,
    grupo,
    SUM(qtde)              AS qtde_total,
    ROUND(SUM(receita), 2) AS receita_total,
    SUM(pedidos)::BIGINT   AS qtd_pedidos
FROM mv_produto_dia
WHERE dia >= CURRENT_DATE - INTERVAL '90 days'
GROUP BY cod_item, produto, grupo
ORDER BY 5 DESC;

-- ============================================================
-- kpi_curva_abc — curva ABC de produtos por receita, 90 dias
-- ============================================================
CREATE OR REPLACE VIEW kpi_curva_abc AS
WITH receita AS (
    SELECT cod_item, produto, grupo,
           ROUND(SUM(qtde), 2)    AS qtde_total,
           ROUND(SUM(receita), 2) AS receita_total
    FROM mv_produto_dia
    WHERE dia >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY cod_item, produto, grupo
),
total AS (SELECT SUM(receita_total) AS geral FROM receita),
ranking AS (
    SELECT r.*,
        ROUND(100.0 * r.receita_total / NULLIF(t.geral, 0), 2) AS pct_receita,
        ROUND(100.0 * SUM(r.receita_total) OVER (ORDER BY r.receita_total DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / NULLIF(t.geral, 0), 2) AS pct_acumulado,
        ROW_NUMBER() OVER (ORDER BY r.receita_total DESC) AS posicao
    FROM receita r, total t
)
SELECT posicao, cod_item, produto, grupo, qtde_total, receita_total,
       pct_receita, pct_acumulado,
       CASE WHEN pct_acumulado <= 80 THEN 'A'
            WHEN pct_acumulado <= 95 THEN 'B'
            ELSE 'C' END AS curva
FROM ranking
ORDER BY posicao;

-- ============================================================
-- kpi_ifood_top_produtos — top 30 do iFood, 90 dias
-- ============================================================
DROP VIEW IF EXISTS kpi_ifood_top_produtos;
CREATE VIEW kpi_ifood_top_produtos AS
SELECT
    cod_item,
    produto,
    grupo,
    SUM(pedidos)::BIGINT   AS qtd_pedidos,
    ROUND(SUM(qtde), 2)    AS qtde_total,
    ROUND(SUM(receita), 2) AS receita_total
FROM mv_produto_dia
WHERE dia >= CURRENT_DATE - INTERVAL '90 days'
  AND canal = 'iFood'
GROUP BY cod_item, produto, grupo
ORDER BY 6 DESC
LIMIT 30;

GRANT SELECT ON kpi_top_produtos_venda, kpi_curva_abc, kpi_ifood_top_produtos
      TO anon, authenticated;

-- ============================================================
-- FIX 9 — kpi_curva_abc_fornecedor ainda fazia JOIN direto em
-- jafeb_despesas_mapping, ignorando a tabela de classificação nova.
-- Perdia R$6.329 em 90 dias.
-- ============================================================
DROP VIEW IF EXISTS kpi_curva_abc_fornecedor;
CREATE VIEW kpi_curva_abc_fornecedor AS
WITH custo AS (
    SELECT chave AS fornecedor,
           COUNT(*)            AS qtd_nf,
           ROUND(SUM(valor),2) AS custo_total
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '90 days'
    GROUP BY chave
),
total AS (SELECT SUM(custo_total) AS geral FROM custo),
ranking AS (
    SELECT c.*,
        ROUND(100.0 * c.custo_total / NULLIF(t.geral,0), 2) AS pct_custo,
        ROUND(100.0 * SUM(c.custo_total) OVER (ORDER BY c.custo_total DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / NULLIF(t.geral,0), 2) AS pct_acumulado,
        ROW_NUMBER() OVER (ORDER BY c.custo_total DESC) AS posicao
    FROM custo c, total t
)
SELECT posicao, fornecedor, qtd_nf, custo_total, pct_custo, pct_acumulado,
       CASE WHEN pct_acumulado <= 80 THEN 'A'
            WHEN pct_acumulado <= 95 THEN 'B'
            ELSE 'C' END AS curva
FROM ranking
ORDER BY posicao;

GRANT SELECT ON kpi_curva_abc_fornecedor TO anon, authenticated;
