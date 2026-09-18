-- mv_produto_dia.sql
-- Agregado dia × produto × canal sobre ecletica_vendas (1,37M linhas).
--
-- Motivo: kpi_curva_abc, kpi_top_produtos_venda e kpi_ifood_top_produtos varriam a
-- tabela de itens crua a cada request e estouravam o statement_timeout do Postgres —
-- ou seja, a página /curva-abc, o card de top produtos da home e o bloco de produtos
-- do iFood estavam quebrados em produção, não apenas lentos.
--
-- Refresh: ao final do sync diário (sync_ecletica.py).

DROP MATERIALIZED VIEW IF EXISTS mv_produto_dia CASCADE;

CREATE MATERIALIZED VIEW mv_produto_dia AS
SELECT
    (p.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
    v.cod_item,
    COALESCE(pr.descr_item, v.cod_item)   AS produto,
    COALESCE(g.descr_grupo, 'Sem grupo')  AS grupo,
    CASE
        WHEN p.origem_venda ILIKE '%IFOOD%'    THEN 'iFood'
        WHEN p.origem_venda ILIKE '%DELIVERY%' THEN 'Delivery'
        ELSE 'Balcao'
    END AS canal,
    COUNT(DISTINCT v.num_ticket)          AS pedidos,
    ROUND(SUM(v.qtde), 2)                 AS qtde,
    ROUND(SUM(v.vlr_unit * v.qtde), 2)    AS receita
FROM ecletica_vendas v
JOIN ecletica_pagamentos p
      ON p.num_ticket = v.num_ticket
     AND p.flag_canc <> 'C'
     AND p.data_hora_fecha >= CURRENT_DATE - INTERVAL '24 months'
LEFT JOIN ecletica_produtos pr ON pr.cod_item  = v.cod_item
LEFT JOIN ecletica_grupos   g  ON g.cod_grupo  = pr.cod_grupo
WHERE v.data_hora >= CURRENT_DATE - INTERVAL '24 months'
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX mv_produto_dia_pk  ON mv_produto_dia (dia, cod_item, canal);
CREATE INDEX mv_produto_dia_dia        ON mv_produto_dia (dia);
CREATE INDEX mv_produto_dia_canal_dia  ON mv_produto_dia (canal, dia);

GRANT SELECT ON mv_produto_dia TO anon, authenticated;
