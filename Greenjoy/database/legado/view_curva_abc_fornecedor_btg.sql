-- ARQUIVO LEGADO — NÃO APLICAR.
-- Substituído em Ago/2026. Aplicar este arquivo REVERTE correções em produção.
-- Fonte atual: views_socios_v2.sql / views_produtos.sql (ver aplicar_views.py).

-- kpi_curva_abc_fornecedor — curva ABC de fornecedores a partir do BTG
-- Aplicada via MCP (migration curva_abc_fornecedor_btg).
--
-- Antes vinha do Everest (nf_recebimento). Migrada para btg_movimentacoes porque o
-- extrato BTG já traz o nome do recebedor (fornecedor) e o de-para jafeb_despesas_mapping
-- (natureza='Custo') isola o que é compra de insumo. Vantagem: fonte viva (sync diário),
-- sem depender da importação manual do Everest.
--
-- Janela: últimos 90 dias. Schema preservado (posicao, fornecedor, qtd_nf, custo_total,
-- pct_custo, pct_acumulado, curva) para não quebrar a tela Compras. qtd_nf agora = nº de
-- pagamentos no período (coluna exibida como "Pagtos").
--
-- Limitações herdadas do BTG: débitos sem nome de recebedor (PIX/TED) não entram;
-- depende do de-para estar completo. Detalhe por item/produto continua só no Everest.

CREATE OR REPLACE VIEW kpi_curva_abc_fornecedor AS
WITH mapa AS (
  SELECT DISTINCT upper(trim(descricao)) AS key
  FROM jafeb_despesas_mapping WHERE natureza = 'Custo'
),
custo AS (
  SELECT
    b.nome_pagador_recebedor AS fornecedor,
    count(*) AS qtd_nf,
    round(sum(b.valor), 2) AS custo_total
  FROM btg_movimentacoes b
  JOIN mapa m ON upper(trim(b.nome_pagador_recebedor)) = m.key
  WHERE b.tipo = 'Débito'
    AND b.nome_pagador_recebedor IS NOT NULL
    AND b.data_movimentacao >= (CURRENT_DATE - interval '90 days')
  GROUP BY b.nome_pagador_recebedor
),
total AS (SELECT sum(custo_total) AS geral FROM custo),
ranking AS (
  SELECT
    c.fornecedor, c.qtd_nf, c.custo_total,
    round((100.0 * c.custo_total) / NULLIF(t.geral, 0), 2) AS pct_custo,
    round((100.0 * sum(c.custo_total) OVER (ORDER BY c.custo_total DESC)) / NULLIF(t.geral, 0), 2) AS pct_acumulado,
    row_number() OVER (ORDER BY c.custo_total DESC) AS posicao
  FROM custo c, total t
)
SELECT
  posicao, fornecedor, qtd_nf, custo_total, pct_custo, pct_acumulado,
  CASE WHEN pct_acumulado <= 80 THEN 'A' WHEN pct_acumulado <= 95 THEN 'B' ELSE 'C' END AS curva
FROM ranking
ORDER BY posicao;
