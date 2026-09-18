-- views_fechamento.sql — conciliação do fechamento: o que foi vendido no dia x o que foi fechado no dia.
-- A Eclética data a venda pelo fechamento; pedido fechado depois da meia-noite some do dia em que foi vendido
-- e infla o seguinte. Horários da Eclética chegam sem fuso e são gravados como UTC — por isso AT TIME ZONE 'UTC'
-- devolve a hora de parede da loja. Deliverup entra com abertura = fechamento: não dá para verificar atraso.

CREATE OR REPLACE VIEW kpi_fechamento_base AS
SELECT
    num_ticket,
    cod_ctrl,
    origem_venda,
    nome_cliente,
    CASE
        WHEN origem_venda ILIKE '%IFOOD%'                       THEN 'iFood'
        WHEN origem_venda = 'ENCOMENDA RETIRADA WEB OLGA TECH'  THEN 'Deliverup (retirada)'
        WHEN origem_venda = 'DELIVERY WEB OLGA TECH'            THEN 'Delivery próprio (Woovi)'
        WHEN COALESCE(origem_venda, '') = ''
          OR origem_venda ILIKE 'COMANDA E-GAR%'
          OR origem_venda ILIKE 'BALC%'                         THEN 'Salão'
        ELSE 'Outros'
    END AS canal,
    data_hora_abre  AT TIME ZONE 'UTC' AS aberto_em,
    data_hora_fecha AT TIME ZONE 'UTC' AS fechado_em,
    (data_hora_abre  AT TIME ZONE 'UTC')::DATE AS dia_venda,
    (data_hora_fecha AT TIME ZONE 'UTC')::DATE AS dia_fechamento,
    (data_hora_fecha AT TIME ZONE 'UTC')::DATE - (data_hora_abre AT TIME ZONE 'UTC')::DATE AS atraso_dias,
    vlr_total + COALESCE(vlr_serv, 0) - COALESCE(vlr_desc_tot, 0) AS valor
FROM ecletica_pagamentos
WHERE COALESCE(flag_canc, '') <> 'C'
  AND data_hora_abre IS NOT NULL;

CREATE OR REPLACE VIEW kpi_fechamento_dia_canal AS
WITH vendido AS (
    SELECT dia_venda AS dia, canal,
           COUNT(*)                                          AS pedidos,
           SUM(valor)                                        AS vendido,
           COALESCE(SUM(valor) FILTER (WHERE atraso_dias = 0), 0) AS fechado_no_dia,
           COALESCE(SUM(valor) FILTER (WHERE atraso_dias > 0), 0) AS nao_fechado,
           COUNT(*) FILTER (WHERE atraso_dias > 0)           AS pedidos_nao_fechados
    FROM kpi_fechamento_base
    GROUP BY 1, 2
), chegou AS (
    SELECT dia_fechamento AS dia, canal,
           SUM(valor) AS chegou_de_dias_anteriores,
           COUNT(*)   AS pedidos_chegaram
    FROM kpi_fechamento_base
    WHERE atraso_dias > 0
    GROUP BY 1, 2
)
SELECT
    COALESCE(v.dia, c.dia)                         AS dia,
    COALESCE(v.canal, c.canal)                     AS canal,
    COALESCE(v.pedidos, 0)                         AS pedidos,
    COALESCE(v.vendido, 0)                         AS vendido,
    COALESCE(v.fechado_no_dia, 0)                  AS fechado_no_dia,
    COALESCE(v.nao_fechado, 0)                     AS nao_fechado,
    COALESCE(v.pedidos_nao_fechados, 0)            AS pedidos_nao_fechados,
    COALESCE(c.chegou_de_dias_anteriores, 0)       AS chegou_de_dias_anteriores,
    COALESCE(c.pedidos_chegaram, 0)                AS pedidos_chegaram,
    COALESCE(v.fechado_no_dia, 0) + COALESCE(c.chegou_de_dias_anteriores, 0)  AS aparece_no_relatorio,
    COALESCE(v.fechado_no_dia, 0) + COALESCE(c.chegou_de_dias_anteriores, 0)
        - COALESCE(v.vendido, 0)                   AS erro_do_dia,
    COALESCE(v.canal, c.canal) <> 'Deliverup (retirada)' AS verificavel,
    CASE
        WHEN COALESCE(v.canal, c.canal) = 'Deliverup (retirada)' THEN 'Sem hora da venda'
        WHEN COALESCE(v.pedidos_nao_fechados, 0) > 0            THEN 'Não fechou'
        WHEN COALESCE(c.chegou_de_dias_anteriores, 0) > 0       THEN 'Recebeu atraso'
        ELSE 'OK'
    END AS status
FROM vendido v
FULL JOIN chegou c ON c.dia = v.dia AND c.canal = v.canal;

CREATE OR REPLACE VIEW kpi_fechamento_pendencias AS
SELECT
    dia_venda,
    canal,
    dia_fechamento,
    MAX(atraso_dias)                     AS atraso_dias,
    COUNT(*)                             AS pedidos,
    SUM(valor)                           AS valor,
    TO_CHAR(MIN(aberto_em), 'HH24:MI')   AS primeiro_aberto,
    TO_CHAR(MAX(aberto_em), 'HH24:MI')   AS ultimo_aberto,
    TO_CHAR(MIN(fechado_em), 'HH24:MI')  AS fechado_de,
    TO_CHAR(MAX(fechado_em), 'HH24:MI')  AS fechado_ate
FROM kpi_fechamento_base
WHERE atraso_dias > 0
GROUP BY dia_venda, canal, dia_fechamento;

GRANT SELECT ON kpi_fechamento_base, kpi_fechamento_dia_canal, kpi_fechamento_pendencias TO anon, authenticated;
