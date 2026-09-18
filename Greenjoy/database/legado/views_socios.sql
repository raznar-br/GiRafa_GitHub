-- ARQUIVO LEGADO — NÃO APLICAR.
-- Substituído em Ago/2026. Aplicar este arquivo REVERTE correções em produção.
-- Fonte atual: views_socios_v2.sql / views_produtos.sql (ver aplicar_views.py).

-- views_socios.sql
-- Views de KPI gerencial para sócios — painel executivo
-- Aplicar no SQL Editor do Supabase após views_dashboard.sql

-- ============================================================
-- VIEW: kpi_socios_painel
-- Linha única com resumo executivo do mês corrente + semáforos RAG
-- Semáforos CMV: ótimo ≤33%, bom ≤37%, crítico >37%
-- Semáforos meta: ótimo ≥100%, bom ≥70%, crítico <70%
-- ============================================================
CREATE OR REPLACE VIEW kpi_socios_painel AS
WITH fat_mes AS (
    SELECT
        ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2) AS fat_liquido,
        COUNT(*)                                                                      AS pedidos,
        ROUND(AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2)  AS ticket_medio,
        COUNT(DISTINCT DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'))       AS dias_com_venda
    FROM ecletica_pagamentos
    WHERE flag_canc != 'C'
      AND DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo') = DATE_TRUNC('month', CURRENT_DATE)
),
meta_mes AS (
    SELECT COALESCE(MAX(valor_meta), 0) AS valor_meta
    FROM metas
    WHERE tipo = 'faturamento'
      AND mes = DATE_TRUNC('month', CURRENT_DATE)::DATE
),
cmv_mes AS (
    SELECT COALESCE(ROUND(SUM(i.vlr_total), 2), 0) AS total_compras
    FROM nf_itens i
    JOIN nf_recebimento r ON i.num_nf = r.num_nf AND i.loja = r.loja
    WHERE i.loja = 'analia_franco'
      AND TO_CHAR(r.data_entrada, 'YYYY-MM') = TO_CHAR(CURRENT_DATE, 'YYYY-MM')
),
dias_mes AS (
    SELECT EXTRACT(day FROM DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month' - INTERVAL '1 day')::INT AS total
)
SELECT
    TO_CHAR(CURRENT_DATE, 'YYYY-MM')                                          AS mes,
    f.fat_liquido,
    m.valor_meta,
    ROUND(100.0 * f.fat_liquido / NULLIF(m.valor_meta, 0), 1)                 AS pct_meta,
    ROUND(f.fat_liquido / NULLIF(f.dias_com_venda, 0) * d.total, 2)           AS projecao_mes,
    f.pedidos,
    f.ticket_medio,
    c.total_compras                                                             AS cmv_compras,
    ROUND(100.0 * c.total_compras / NULLIF(f.fat_liquido, 0), 1)              AS cmv_pct,
    CASE
        WHEN ROUND(100.0 * c.total_compras / NULLIF(f.fat_liquido, 0), 1) <= 33 THEN 'otimo'
        WHEN ROUND(100.0 * c.total_compras / NULLIF(f.fat_liquido, 0), 1) <= 37 THEN 'bom'
        ELSE 'critico'
    END AS semaforo_cmv,
    CASE
        WHEN ROUND(100.0 * f.fat_liquido / NULLIF(m.valor_meta, 0), 1) >= 100 THEN 'otimo'
        WHEN ROUND(100.0 * f.fat_liquido / NULLIF(m.valor_meta, 0), 1) >= 70  THEN 'bom'
        ELSE 'critico'
    END AS semaforo_meta
FROM fat_mes f, meta_mes m, cmv_mes c, dias_mes d;

-- ============================================================
-- VIEW: kpi_historico_24m
-- 24 meses de tendência: resumo_mensal_historico (histórico consolidado)
-- + ecletica_pagamentos (meses recentes ao vivo)
-- ============================================================
CREATE OR REPLACE VIEW kpi_historico_24m AS
SELECT
    TO_CHAR(mes, 'YYYY-MM')   AS mes,
    faturamento_total          AS fat_liquido,
    pedidos_total              AS pedidos,
    ticket_medio_geral         AS ticket_medio,
    'historico'                AS origem
FROM resumo_mensal_historico
WHERE mes < DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')

UNION ALL

SELECT
    TO_CHAR(DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'), 'YYYY-MM') AS mes,
    ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2)              AS fat_liquido,
    COUNT(*)                                                                                   AS pedidos,
    ROUND(AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2)              AS ticket_medio,
    'live'                                                                                     AS origem
FROM ecletica_pagamentos
WHERE flag_canc != 'C'
  AND data_hora_fecha >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
GROUP BY 1

ORDER BY 1 DESC
LIMIT 24;

-- ============================================================
-- VIEW: kpi_canal_evolucao_6m
-- 6 meses de share por canal — visibilidade da dependência do iFood
-- ============================================================
CREATE OR REPLACE VIEW kpi_canal_evolucao_6m AS
SELECT
    TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') AS mes,
    CASE
        WHEN origem_venda ILIKE '%IFOOD%'    THEN 'iFood'
        WHEN origem_venda ILIKE '%DELIVERY%' THEN 'Delivery'
        ELSE 'Balcao'
    END AS canal,
    COUNT(*) AS pedidos,
    ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2) AS fat_liquido,
    ROUND(AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2) AS ticket_medio,
    ROUND(
        100.0 * SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0))
        / SUM(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0))) OVER (
            PARTITION BY TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM')
        ), 1
    ) AS pct_canal
FROM ecletica_pagamentos
WHERE flag_canc != 'C'
  AND data_hora_fecha >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '5 months')
GROUP BY 1, 2
ORDER BY 1 DESC, fat_liquido DESC;
