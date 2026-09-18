-- views_dashboard.sql
-- Rodar no SQL Editor do Supabase após greenjoy_schema.sql

-- ============================================================
-- VIEW 1: Faturamento diário por canal
-- ============================================================
CREATE OR REPLACE VIEW kpi_faturamento_diario AS
SELECT
    DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo') AS data,
    CASE
        WHEN origem_venda ILIKE '%IFOOD%'    THEN 'iFood'
        WHEN origem_venda ILIKE '%DELIVERY%' THEN 'Delivery'
        WHEN origem_venda ILIKE '%COMANDA%'  THEN 'Balcao'
        WHEN origem_venda ILIKE '%GARCOM%'   THEN 'Balcao'
        WHEN origem_venda IS NULL OR origem_venda = '' THEN 'Balcao'
        ELSE origem_venda
    END AS canal,
    COUNT(*)                 AS qtd_pedidos,
    SUM(vlr_total)           AS faturamento,
    ROUND(AVG(vlr_total), 2) AS ticket_medio
FROM ecletica_pagamentos
WHERE flag_canc != 'C'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

-- ============================================================
-- VIEW 2: Ticket médio e volume por canal (últimos 30 dias)
-- ============================================================
CREATE OR REPLACE VIEW kpi_ticket_por_canal AS
SELECT
    CASE
        WHEN origem_venda ILIKE '%IFOOD%'    THEN 'iFood'
        WHEN origem_venda ILIKE '%DELIVERY%' THEN 'Delivery'
        WHEN origem_venda ILIKE '%COMANDA%'  THEN 'Balcao'
        WHEN origem_venda ILIKE '%GARCOM%'   THEN 'Balcao'
        WHEN origem_venda IS NULL OR origem_venda = '' THEN 'Balcao'
        ELSE origem_venda
    END AS canal,
    COUNT(*)                                                        AS qtd_pedidos,
    ROUND(AVG(vlr_total), 2)                                        AS ticket_medio,
    SUM(vlr_total)                                                  AS faturamento_total,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)             AS pct_pedidos
FROM ecletica_pagamentos
WHERE flag_canc != 'C'
  AND data_hora_fecha >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY 1
ORDER BY faturamento_total DESC;

-- ============================================================
-- VIEW 3: Top produtos por receita (últimos 90 dias)
-- kpi_top_produtos_venda saiu daqui em Ago/2026: agora vive em
-- views_produtos.sql, sobre mv_produto_dia. A versão que existia aqui varria
-- ecletica_vendas cru e estourava o statement_timeout.

-- ============================================================
CREATE OR REPLACE VIEW kpi_compras_mensal AS
SELECT
    TO_CHAR(r.data_entrada, 'YYYY-MM') AS mes,
    i.categoria,
    COUNT(DISTINCT r.num_nf)           AS qtd_nf,
    ROUND(SUM(i.vlr_total), 2)         AS total_compras
FROM nf_itens i
JOIN nf_recebimento r ON i.num_nf = r.num_nf AND i.loja = r.loja
WHERE i.loja = 'analia_franco'
  AND r.data_entrada IS NOT NULL
GROUP BY 1, 2
ORDER BY 1 DESC, total_compras DESC;

-- ============================================================
-- VIEW 5: CMV proxy — compras do mês vs. faturamento do mês
-- (proxy até ter ficha técnica por produto)
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_proxy AS
SELECT
    mes,
    categoria,
    total_compras,
    faturamento_mes,
    ROUND(100.0 * total_compras / NULLIF(faturamento_mes, 0), 1) AS pct_cmv_proxy
FROM (
    SELECT
        TO_CHAR(r.data_entrada, 'YYYY-MM') AS mes,
        i.categoria,
        ROUND(SUM(i.vlr_total), 2)         AS total_compras
    FROM nf_itens i
    JOIN nf_recebimento r ON i.num_nf = r.num_nf AND i.loja = r.loja
    WHERE i.loja = 'analia_franco'
    GROUP BY 1, 2
) compras
JOIN (
    SELECT
        TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') AS mes,
        SUM(vlr_total) AS faturamento_mes
    FROM ecletica_pagamentos
    WHERE flag_canc != 'C'
    GROUP BY 1
) fat USING (mes)
ORDER BY mes DESC, total_compras DESC;
