-- views_socios_v2.sql
-- Painel executivo dos sócios: o número, e ao lado dele a explicação.
--
-- Correções sobre a versão anterior:
--  · CMV do semáforo passa a ser a janela móvel de 30 dias, não compras-do-mês-parcial
--    sobre faturamento-do-mês-parcial (que marcava 44,9% "crítico" no dia 15).
--  · Mês corrente é comparado com o MESMO NÚMERO DE DIAS do mês anterior, não com o
--    mês anterior inteiro.
--  · Prime Cost medido (folha + encargos), não estimado por multiplicador.

-- ============================================================
-- kpi_socios_painel — linha única do mês corrente
-- ============================================================
DROP VIEW IF EXISTS kpi_socios_painel;
CREATE VIEW kpi_socios_painel AS
WITH hoje AS (SELECT hoje_br() AS d),
mes_atual AS (
    SELECT
        SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS fat_liquido,
        COUNT(*) AS pedidos,
        AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS ticket_medio,
        COUNT(DISTINCT DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')) AS dias_operados,
        MAX(DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')) AS ultimo_dia
    FROM ecletica_pagamentos, hoje
    WHERE flag_canc <> 'C'
      AND DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')
          = DATE_TRUNC('month', hoje.d)
),
-- mesmo recorte de dias no mês anterior, para comparação justa
mes_anterior_parcial AS (
    SELECT
        SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS fat_liquido,
        COUNT(*) AS pedidos,
        AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS ticket_medio
    FROM ecletica_pagamentos, hoje
    WHERE flag_canc <> 'C'
      AND DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')
          = DATE_TRUNC('month', hoje.d - INTERVAL '1 month')
      AND EXTRACT(day FROM data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')
          <= EXTRACT(day FROM hoje.d)
),
ano_passado_parcial AS (
    SELECT SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS fat_liquido
    FROM ecletica_pagamentos, hoje
    WHERE flag_canc <> 'C'
      AND DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')
          = DATE_TRUNC('month', hoje.d - INTERVAL '1 year')
      AND EXTRACT(day FROM data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')
          <= EXTRACT(day FROM hoje.d)
),
meta_mes AS (
    SELECT COALESCE(MAX(valor_meta), 0) AS valor_meta
    FROM metas, hoje
    WHERE tipo = 'faturamento' AND mes = DATE_TRUNC('month', hoje.d)::DATE
),
cmv AS (
    SELECT cmv_30d_pct, cmv_90d_pct, semaforo_cmv, compras_30d
    FROM kpi_cmv_rolling ORDER BY dia DESC LIMIT 1
),
prime AS (
    SELECT labor_direto, encargos, labor_total, labor_total_pct,
           prime_cost_pct, semaforo_prime_cost, cmv_pct AS cmv_mes_pct
    FROM kpi_prime_cost_mensal, hoje
    WHERE mes = TO_CHAR(hoje.d, 'YYYY-MM')
),
cobertura AS (
    SELECT pct_nao_classificado, status AS status_dado
    FROM kpi_cobertura_mapping, hoje
    WHERE mes = TO_CHAR(hoje.d, 'YYYY-MM')
),
dias AS (
    SELECT EXTRACT(day FROM DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::INT AS total,
           EXTRACT(day FROM d)::INT AS decorridos
    FROM hoje
)
SELECT
    TO_CHAR(h.d, 'YYYY-MM') AS mes,
    ROUND(a.fat_liquido, 2)  AS fat_liquido,
    a.pedidos,
    ROUND(a.ticket_medio, 2) AS ticket_medio,
    a.dias_operados,
    a.ultimo_dia,
    d.decorridos AS dias_decorridos,
    d.total      AS dias_mes,
    m.valor_meta,
    ROUND(100.0 * a.fat_liquido / NULLIF(m.valor_meta, 0), 1) AS pct_meta,
    -- projeção pela média diária realizada
    ROUND(a.fat_liquido / NULLIF(a.dias_operados, 0) * d.total, 2) AS projecao_mes,
    ROUND(100.0 * (a.fat_liquido / NULLIF(a.dias_operados, 0) * d.total)
          / NULLIF(m.valor_meta, 0), 1) AS pct_meta_projetado,
    -- comparação justa: mesmo nº de dias do mês anterior e do ano passado
    ROUND(p.fat_liquido, 2) AS fat_mes_anterior_parcial,
    ROUND(100.0 * (a.fat_liquido - p.fat_liquido) / NULLIF(p.fat_liquido, 0), 1) AS var_mes_pct,
    ROUND(100.0 * (a.fat_liquido - y.fat_liquido) / NULLIF(y.fat_liquido, 0), 1) AS var_ano_pct,
    p.pedidos      AS pedidos_mes_anterior_parcial,
    ROUND(p.ticket_medio, 2) AS ticket_mes_anterior_parcial,
    -- CMV: janela móvel, imune ao calendário de compra
    c.cmv_30d_pct  AS cmv_pct,
    c.cmv_90d_pct,
    c.compras_30d,
    c.semaforo_cmv,
    -- pessoal e prime cost, medidos
    pr.labor_direto,
    pr.encargos,
    pr.labor_total,
    pr.labor_total_pct AS labor_pct,
    pr.cmv_mes_pct,
    pr.prime_cost_pct,
    pr.semaforo_prime_cost,
    CASE
        WHEN 100.0 * (a.fat_liquido / NULLIF(a.dias_operados,0) * d.total)
             / NULLIF(m.valor_meta,0) >= 100 THEN 'otimo'
        WHEN 100.0 * (a.fat_liquido / NULLIF(a.dias_operados,0) * d.total)
             / NULLIF(m.valor_meta,0) >= 90  THEN 'bom'
        ELSE 'critico'
    END AS semaforo_meta,
    cob.pct_nao_classificado,
    cob.status_dado
FROM hoje h, mes_atual a, mes_anterior_parcial p, ano_passado_parcial y,
     meta_mes m, dias d, cmv c
LEFT JOIN prime pr ON TRUE
LEFT JOIN cobertura cob ON TRUE;

GRANT SELECT ON kpi_socios_painel TO anon, authenticated;

-- ============================================================
-- FIX 10 — a decomposição volume+ticket não fechava exatamente (resíduo de até
-- R$33) porque kpi_faturamento_mes arredonda ticket_medio a 2 casas e a conta
-- usava esse valor arredondado. Agora o ticket usado no cálculo é derivado de
-- faturamento/pedidos sem arredondar; só a exibição é arredondada.
-- ============================================================
DROP VIEW IF EXISTS kpi_bridge_faturamento;
CREATE VIEW kpi_bridge_faturamento AS
WITH m AS (
    SELECT
        TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') AS mes,
        SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS faturamento,
        COUNT(*)::NUMERIC AS pedidos
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
    GROUP BY 1
),
comp AS (
    SELECT
        mes, faturamento, pedidos,
        faturamento / NULLIF(pedidos, 0) AS ticket,
        LAG(faturamento) OVER (ORDER BY mes) AS fat_ant,
        LAG(pedidos)     OVER (ORDER BY mes) AS ped_ant,
        LAG(faturamento / NULLIF(pedidos, 0)) OVER (ORDER BY mes) AS tkt_ant
    FROM m
)
SELECT
    mes,
    (mes = TO_CHAR(hoje_br(), 'YYYY-MM')) AS parcial,
    ROUND(faturamento, 2) AS faturamento,
    ROUND(fat_ant, 2)     AS faturamento_anterior,
    ROUND(faturamento - fat_ant, 2) AS variacao_total,
    ROUND(100.0 * (faturamento - fat_ant) / NULLIF(fat_ant, 0), 1) AS variacao_pct,
    pedidos::BIGINT AS pedidos,
    ped_ant::BIGINT AS pedidos_anterior,
    ROUND(ticket, 2)  AS ticket_medio,
    ROUND(tkt_ant, 2) AS ticket_anterior,
    ROUND((pedidos - ped_ant) * tkt_ant, 2)  AS efeito_volume,
    ROUND((ticket - tkt_ant) * pedidos, 2)   AS efeito_ticket,
    ROUND(100.0 * ((pedidos - ped_ant) * tkt_ant) / NULLIF(fat_ant, 0), 1) AS efeito_volume_pct,
    ROUND(100.0 * ((ticket - tkt_ant) * pedidos) / NULLIF(fat_ant, 0), 1)  AS efeito_ticket_pct
FROM comp
WHERE fat_ant IS NOT NULL
ORDER BY mes DESC;

GRANT SELECT ON kpi_bridge_faturamento TO anon, authenticated;

-- ============================================================
-- kpi_historico_24m — tendência de 24 meses.
-- A versão anterior emendava resumo_mensal_historico (congelado em Mai/2026) com
-- os meses "live", e o filtro deixava um buraco entre as duas fontes: junho sumia
-- do gráfico. Como os 24 meses estão em ecletica_pagamentos, lê direto de lá.
-- ============================================================
DROP VIEW IF EXISTS kpi_historico_24m;
CREATE VIEW kpi_historico_24m AS
SELECT
    mes,
    faturamento AS fat_liquido,
    pedidos,
    ticket_medio,
    dias_operados,
    CASE WHEN mes = TO_CHAR(hoje_br(), 'YYYY-MM') THEN 'parcial' ELSE 'fechado' END AS origem
FROM kpi_faturamento_mes
WHERE mes >= TO_CHAR(hoje_br() - INTERVAL '23 months', 'YYYY-MM')
ORDER BY mes;

GRANT SELECT ON kpi_historico_24m TO anon, authenticated;

-- ============================================================
-- kpi_canal_mensal — mix e ticket por canal.
-- Explica o efeito_ticket: quando iFood ganha share, o ticket médio cai
-- porque o ticket do iFood é estruturalmente diferente do balcão.
-- ============================================================
CREATE OR REPLACE VIEW kpi_canal_mensal AS
WITH base AS (
    SELECT
        TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') AS mes,
        CASE
            WHEN origem_venda ILIKE '%IFOOD%'    THEN 'iFood'
            WHEN origem_venda ILIKE '%DELIVERY%' THEN 'Delivery'
            ELSE 'Balcao'
        END AS canal,
        SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS faturamento,
        COUNT(*) AS pedidos,
        AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS ticket_medio
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '25 months'
    GROUP BY 1, 2
),
com_share AS (
    SELECT
        mes, canal, faturamento, pedidos, ticket_medio,
        100.0 * faturamento / SUM(faturamento) OVER (PARTITION BY mes) AS share_faturamento,
        100.0 * pedidos / SUM(pedidos) OVER (PARTITION BY mes) AS share_pedidos
    FROM base
)
SELECT
    mes, canal,
    ROUND(faturamento, 2)      AS faturamento,
    pedidos,
    ROUND(ticket_medio, 2)     AS ticket_medio,
    ROUND(share_faturamento, 1) AS share_faturamento,
    ROUND(share_pedidos, 1)     AS share_pedidos,
    ROUND(ticket_medio - LAG(ticket_medio) OVER (PARTITION BY canal ORDER BY mes), 2)
        AS var_ticket_mes,
    ROUND(share_faturamento - LAG(share_faturamento) OVER (PARTITION BY canal ORDER BY mes), 1)
        AS var_share_pp
FROM com_share
ORDER BY mes DESC, faturamento DESC;

GRANT SELECT ON kpi_canal_mensal TO anon, authenticated;

-- ============================================================
-- kpi_dia_semana — performance por dia da semana, 90 dias.
-- Mostra onde o volume nasce e onde dá para atacar.
-- ============================================================
CREATE OR REPLACE VIEW kpi_dia_semana AS
WITH base AS (
    SELECT
        EXTRACT(dow FROM data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::INT AS dow,
        DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo') AS dia,
        SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS faturamento,
        COUNT(*) AS pedidos
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '90 days'
    GROUP BY 1, 2
)
SELECT
    dow,
    CASE dow WHEN 0 THEN 'Domingo' WHEN 1 THEN 'Segunda' WHEN 2 THEN 'Terça'
             WHEN 3 THEN 'Quarta'  WHEN 4 THEN 'Quinta'  WHEN 5 THEN 'Sexta'
             ELSE 'Sábado' END AS dia_semana,
    COUNT(*) AS ocorrencias,
    ROUND(AVG(faturamento), 2) AS faturamento_medio,
    ROUND(AVG(pedidos), 0)     AS pedidos_medio,
    ROUND(AVG(faturamento / NULLIF(pedidos, 0)), 2) AS ticket_medio,
    ROUND(100.0 * AVG(faturamento) / SUM(AVG(faturamento)) OVER (), 1) AS share_pct
FROM base
GROUP BY dow
ORDER BY dow;

GRANT SELECT ON kpi_dia_semana TO anon, authenticated;

-- ============================================================
-- FIX 8 — buracos de venda não eram detectados. 10/05 e 03/07 aparecem com
-- faturamento zero e 02/07 com menos da metade do movimento normal; isso
-- infla o CMV (denominador menor) e a projeção do mês.
-- ============================================================
CREATE OR REPLACE VIEW kpi_dias_suspeitos AS
WITH dia AS (
    SELECT (data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
           SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS faturamento,
           COUNT(*) AS pedidos
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '120 days'
    GROUP BY 1
),
calendario AS (
    SELECT generate_series(hoje_br() - INTERVAL '120 days',
                           hoje_br() - INTERVAL '1 day', '1 day')::DATE AS dia
),
base AS (
    SELECT c.dia,
           COALESCE(d.faturamento, 0) AS faturamento,
           COALESCE(d.pedidos, 0)     AS pedidos,
           EXTRACT(dow FROM c.dia)::INT AS dow
    FROM calendario c LEFT JOIN dia d ON d.dia = c.dia
),
mediana AS (
    SELECT dow, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY faturamento)::NUMERIC AS mediana_dow
    FROM base WHERE faturamento > 0 GROUP BY dow
)
SELECT
    b.dia,
    b.dow,
    ROUND(b.faturamento, 2) AS faturamento,
    b.pedidos,
    ROUND(m.mediana_dow, 2) AS esperado_dia_semana,
    ROUND(100.0 * b.faturamento / NULLIF(m.mediana_dow, 0), 0) AS pct_do_esperado,
    CASE WHEN b.faturamento = 0 THEN 'sem_venda'
         WHEN b.faturamento < 0.5 * m.mediana_dow THEN 'muito_abaixo'
         ELSE 'ok' END AS situacao
FROM base b JOIN mediana m ON m.dow = b.dow
WHERE b.faturamento < 0.5 * m.mediana_dow
ORDER BY b.dia DESC;

GRANT SELECT ON kpi_dias_suspeitos TO anon, authenticated;
