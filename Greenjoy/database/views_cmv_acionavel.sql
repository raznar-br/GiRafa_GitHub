-- views_cmv_acionavel.sql
-- CMV que dá para agir no dia a dia.
--
-- Problema: "CMV do mês" = compras do mês / faturamento do mês. Compra é lumpy
-- (uma entrega de sexta abastece a semana), então o indicador oscila 7 p.p. entre
-- meses por calendário de compra, não por gestão — e no dia 15 compara meio mês de
-- compra com meio mês de venda, acendendo alarme falso.
-- Solução: janela móvel para o número oficial, e desvio contra a própria média
-- histórica para apontar onde agir.

-- ============================================================
-- FIX 3 — kpi_cmv_rolling terminava no dia corrente, que ainda não tem vendas
-- sincronizadas. Como kpi_socios_painel lê a última linha, o semáforo mostrava
-- 37,5% "crítico" quando o último dia fechado dava 36,8% "bom" — alarme falso
-- todo dia até o sync das 00:30.
-- Agora a série termina no último dia com faturamento registrado.
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_rolling AS
WITH fat_dia AS (
    SELECT (data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
           SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)) AS faturamento
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '15 months'
    GROUP BY 1
),
compra_dia AS (
    SELECT data_movimentacao::DATE AS dia, SUM(valor) AS compras
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '15 months'
    GROUP BY 1
),
limite AS (SELECT MAX(dia) AS ate FROM fat_dia),
calendario AS (
    SELECT generate_series(hoje_br() - INTERVAL '13 months',
                           (SELECT ate FROM limite), '1 day')::DATE AS dia
),
base AS (
    SELECT c.dia,
           COALESCE(f.faturamento, 0) AS faturamento,
           COALESCE(p.compras, 0)     AS compras
    FROM calendario c
    LEFT JOIN fat_dia    f ON f.dia = c.dia
    LEFT JOIN compra_dia p ON p.dia = c.dia
)
SELECT
    dia,
    ROUND(faturamento, 2) AS faturamento_dia,
    ROUND(compras, 2)     AS compras_dia,
    ROUND(SUM(faturamento) OVER w30, 2) AS faturamento_30d,
    ROUND(SUM(compras)     OVER w30, 2) AS compras_30d,
    ROUND(100.0 * SUM(compras) OVER w30
          / NULLIF(SUM(faturamento) OVER w30, 0), 1) AS cmv_30d_pct,
    ROUND(100.0 * SUM(compras) OVER w90
          / NULLIF(SUM(faturamento) OVER w90, 0), 1) AS cmv_90d_pct,
    CASE
        WHEN 100.0 * SUM(compras) OVER w30
             / NULLIF(SUM(faturamento) OVER w30, 0) <= 33 THEN 'otimo'
        WHEN 100.0 * SUM(compras) OVER w30
             / NULLIF(SUM(faturamento) OVER w30, 0) <= 37 THEN 'bom'
        ELSE 'critico'
    END AS semaforo_cmv
FROM base
WINDOW w30 AS (ORDER BY dia RANGE BETWEEN INTERVAL '29 days' PRECEDING AND CURRENT ROW),
       w90 AS (ORDER BY dia RANGE BETWEEN INTERVAL '89 days' PRECEDING AND CURRENT ROW)
ORDER BY dia DESC;

GRANT SELECT ON kpi_cmv_rolling TO anon, authenticated;

-- ============================================================
-- FIX 5 — kpi_cmv_categoria_semanal ganha flag de semana parcial, para o
-- frontend não rotular a semana em curso como "última semana fechada".
-- ============================================================
DROP VIEW IF EXISTS kpi_cmv_acoes;
DROP VIEW IF EXISTS kpi_cmv_categoria_semanal;
CREATE VIEW kpi_cmv_categoria_semanal AS
WITH semanal AS (
    SELECT
        DATE_TRUNC('week', data_movimentacao::timestamptz)::DATE AS semana,
        COALESCE(categoria_2, 'Sem categoria') AS categoria,
        ROUND(SUM(valor), 2) AS total
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '12 months'
    GROUP BY 1, 2
),
com_media AS (
    SELECT
        semana, categoria, total,
        ROUND(AVG(total) OVER (PARTITION BY categoria ORDER BY semana
              ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING), 2) AS media_8s,
        ROUND(STDDEV_SAMP(total) OVER (PARTITION BY categoria ORDER BY semana
              ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING), 2) AS desvio_8s,
        COUNT(*) OVER (PARTITION BY categoria ORDER BY semana
              ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS semanas_base
    FROM semanal
)
SELECT
    semana,
    (semana >= DATE_TRUNC('week', hoje_br())::DATE) AS parcial,
    categoria, total, media_8s, semanas_base,
    ROUND(total - media_8s, 2) AS desvio_reais,
    ROUND(100.0 * (total - media_8s) / NULLIF(media_8s, 0), 1) AS desvio_pct,
    CASE
        WHEN semanas_base < 4 THEN 'sem_base'
        WHEN desvio_8s IS NULL OR desvio_8s = 0 THEN 'normal'
        WHEN total > media_8s + 2 * desvio_8s THEN 'muito_acima'
        WHEN total > media_8s + desvio_8s     THEN 'acima'
        WHEN total < media_8s - desvio_8s     THEN 'abaixo'
        ELSE 'normal'
    END AS situacao
FROM com_media
ORDER BY semana DESC, desvio_reais DESC NULLS LAST;

GRANT SELECT ON kpi_cmv_categoria_semanal TO anon, authenticated;

-- ============================================================
-- FIX 7 — formatação de moeda em pt-BR. TO_CHAR usa o lc_numeric do servidor
-- (US), então "R$ 3,672.87" saía trocado. Função explícita resolve.
-- FIX 11 — o mesmo evento aparecia duas vezes (categoria Tortas + fornecedor
-- Baked, mesmos R$2.789,77). Agora o alerta de fornecedor só aparece se não
-- houver um alerta de categoria com valor equivalente.
-- ============================================================
CREATE VIEW kpi_cmv_acoes AS
WITH ultima AS (
    SELECT MAX(semana) AS semana FROM kpi_cmv_categoria_semanal WHERE NOT parcial
),
cat AS (
    SELECT
        'categoria' AS tipo, c.categoria AS alvo, NULL::TEXT AS detalhe,
        c.total, c.media_8s, c.desvio_reais, c.desvio_pct, c.situacao,
        'Gasto com ' || c.categoria || ' ficou R$ ' || brl(c.desvio_reais)
        || ' acima da média de 8 semanas (' || c.desvio_pct
        || '%). Conferir pedido, preço e perda.' AS acao
    FROM kpi_cmv_categoria_semanal c, ultima u
    WHERE c.semana = u.semana
      AND c.situacao IN ('acima', 'muito_acima')
      AND c.desvio_reais > 300
),
forn AS (
    SELECT
        'fornecedor' AS tipo, f.fornecedor AS alvo, f.categoria AS detalhe,
        f.total, f.media_8s, f.desvio_reais,
        f.desvio_pct, NULL::TEXT AS situacao,
        'Pagamento a ' || INITCAP(f.fornecedor) || ' ficou R$ ' || brl(f.desvio_reais)
        || ' acima da média. Checar se houve compra extra, reajuste de preço '
        || 'ou pedido duplicado.' AS acao
    FROM kpi_cmv_fornecedor_semanal f, ultima u
    WHERE f.semana = u.semana
      AND f.semanas_base >= 4
      AND f.desvio_reais > 500
      -- não repetir o mesmo evento que já apareceu como categoria
      AND NOT EXISTS (
          SELECT 1 FROM cat c
          WHERE c.alvo = f.categoria
            AND ABS(c.desvio_reais - f.desvio_reais) < 1
      )
)
SELECT * FROM cat
UNION ALL
SELECT * FROM forn
ORDER BY desvio_reais DESC;

GRANT SELECT ON kpi_cmv_acoes TO anon, authenticated;

-- ============================================================
-- kpi_cmv_fornecedor_semanal — mesmo desvio, por fornecedor
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_fornecedor_semanal AS
WITH semanal AS (
    SELECT
        DATE_TRUNC('week', data_movimentacao::timestamptz)::DATE AS semana,
        chave AS fornecedor,
        COALESCE(categoria_2, 'Sem categoria') AS categoria,
        ROUND(SUM(valor), 2) AS total
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '12 months'
    GROUP BY 1, 2, 3
),
com_media AS (
    SELECT
        semana, fornecedor, categoria, total,
        ROUND(AVG(total) OVER (PARTITION BY fornecedor ORDER BY semana
              ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING), 2) AS media_8s,
        COUNT(*) OVER (PARTITION BY fornecedor ORDER BY semana
              ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS semanas_base
    FROM semanal
)
SELECT
    semana, fornecedor, categoria, total, media_8s, semanas_base,
    ROUND(total - media_8s, 2) AS desvio_reais,
    ROUND(100.0 * (total - media_8s) / NULLIF(media_8s, 0), 1) AS desvio_pct
FROM com_media
ORDER BY semana DESC, desvio_reais DESC NULLS LAST;

GRANT SELECT ON kpi_cmv_fornecedor_semanal TO anon, authenticated;

-- ============================================================
-- kpi_cmv_por_mil — custo por R$1.000 de venda, por categoria e mês.
-- Normaliza sazonalidade: compara meses de faturamento diferente.
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_por_mil AS
SELECT
    b.mes,
    COALESCE(b.categoria_2, 'Sem categoria') AS categoria,
    ROUND(SUM(b.valor), 2) AS total,
    f.faturamento,
    ROUND(1000.0 * SUM(b.valor) / NULLIF(f.faturamento, 0), 2) AS custo_por_mil,
    ROUND(100.0 * SUM(b.valor) / NULLIF(f.faturamento, 0), 2)  AS pct_faturamento
FROM btg_classificado b
JOIN kpi_faturamento_mes f ON f.mes = b.mes
WHERE b.tipo ILIKE 'D%' AND b.natureza = 'Custo'
GROUP BY b.mes, COALESCE(b.categoria_2, 'Sem categoria'), f.faturamento
ORDER BY b.mes DESC, total DESC;

GRANT SELECT ON kpi_cmv_por_mil TO anon, authenticated;
