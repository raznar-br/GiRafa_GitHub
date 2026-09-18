-- kpi_bonus_semanal — alvo individual fixo (modelo gamificado)
-- Aplicada via MCP (migrations bonus_config_contadores_elegiveis → bonus_valores_individuais).
--
-- MODELO: cada cargo tem um ALVO INDIVIDUAL fixo por faixa (não dilui com o quadro).
--   bonus_config.valor_op_base/target/stretch = alvo MENSAL do operacional (115/165/230).
--   valor_por_cota = valor_op_<faixa> / 4  (valor SEMANAL do operacional, cota = 1)
--   O app multiplica por cota do cargo (líder ×1,2 · chefe ×1,5).
--   pool_semana (DERIVADO = custo coletivo) = valor_por_cota × divisor_cotas
--     divisor_cotas = qtd_operacional*cota_op + qtd_lider*cota_lider + qtd_chefe*cota_chefe
--
-- Diferença do modelo antigo (pool fixo dividido): aqui o custo varia com o nº de
-- elegíveis (sobe conforme efetivam), mas o prêmio individual é fixo e previsível.
-- A gestão edita os valores e o quadro de elegíveis em /bonus-gestao.

CREATE OR REPLACE VIEW kpi_bonus_semanal AS
WITH cfg AS (
  SELECT id, meta_semanal, pool_base, pool_target, pool_stretch, pct_base, pct_stretch,
         total_cotas, cota_operacional, cota_lider, cota_chefe, atualizado_em,
         qtd_operacional, qtd_lider, qtd_chefe,
         valor_op_base, valor_op_target, valor_op_stretch,
         GREATEST(
           qtd_operacional * cota_operacional + qtd_lider * cota_lider + qtd_chefe * cota_chefe,
           0
         ) AS divisor_cotas
  FROM bonus_config WHERE id = 1
), vendas AS (
  SELECT (date_trunc('week', (ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')))::date AS semana_inicio,
         sum((ecletica_pagamentos.vlr_total + COALESCE(ecletica_pagamentos.vlr_serv, 0)) - COALESCE(ecletica_pagamentos.vlr_desc_tot, 0)) AS faturamento_liquido
  FROM ecletica_pagamentos
  WHERE ecletica_pagamentos.flag_canc <> 'C'
    AND ecletica_pagamentos.data_hora_fecha >= (now() - '84 days'::interval)
  GROUP BY (date_trunc('week', (ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')))::date
), base AS (
  SELECT
    v.semana_inicio,
    (v.semana_inicio + 6) AS semana_fim,
    (date_trunc('month', v.semana_inicio::timestamptz))::date AS mes_referencia,
    round(v.faturamento_liquido, 2) AS faturamento_liquido,
    cfg.meta_semanal,
    round((v.faturamento_liquido / cfg.meta_semanal) * 100, 1) AS pct_meta,
    CASE
      WHEN v.faturamento_liquido >= (cfg.meta_semanal * cfg.pct_stretch) THEN 'Stretch'
      WHEN v.faturamento_liquido >= cfg.meta_semanal                     THEN 'Target'
      WHEN v.faturamento_liquido >= (cfg.meta_semanal * cfg.pct_base)    THEN 'Base'
      ELSE 'Sem bonus'
    END AS faixa,
    round(
      CASE
        WHEN v.faturamento_liquido >= (cfg.meta_semanal * cfg.pct_stretch) THEN cfg.valor_op_stretch
        WHEN v.faturamento_liquido >= cfg.meta_semanal                     THEN cfg.valor_op_target
        WHEN v.faturamento_liquido >= (cfg.meta_semanal * cfg.pct_base)    THEN cfg.valor_op_base
        ELSE 0::numeric
      END / 4.0, 2
    ) AS valor_por_cota,
    cfg.divisor_cotas,
    ((v.semana_inicio + 6) < ((now() AT TIME ZONE 'America/Sao_Paulo'))::date) AS semana_fechada
  FROM vendas v CROSS JOIN cfg
)
SELECT
  semana_inicio, semana_fim, mes_referencia, faturamento_liquido, meta_semanal,
  pct_meta, faixa,
  round(valor_por_cota * divisor_cotas, 2) AS pool_semana,  -- custo coletivo derivado
  valor_por_cota,
  semana_fechada
FROM base
ORDER BY semana_inicio DESC;
