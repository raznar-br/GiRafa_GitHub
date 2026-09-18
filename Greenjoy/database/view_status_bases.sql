-- kpi_status_bases — frescor/status de cada base do dashboard
-- Aplicada via MCP (migrations kpi_status_bases → v4_everest_desperdicio).
-- Alimenta o card "Status das bases" no dashboard e a skill /greenjoy-validar.
--
-- Fontes de compras/CMV:
--   • CMV e análise de compras por fornecedor/categoria: btg_movimentacoes x
--     jafeb_despesas_mapping (natureza='Custo'). O BTG tem o nome do recebedor
--     (fornecedor), então a curva ABC de fornecedores também sai dele
--     (ver view_curva_abc_fornecedor_btg.sql).
--   • Everest (nf_recebimento/nf_itens) ficou como APOIO do desperdício: alimenta
--     ref_custo_produto (custo unitário sugerido no formulário) e kpi_cmv_top_itens.
--     Não é mais fonte de compras/fornecedores — por isso entra com limite frouxo.
--
-- Limites de status por base:
--   Vendas (Eclética PDV)  · diário 00:30 · ok <26h, atenção <50h, senão crítico
--   Banco BTG (CMV/compras)· diário 06:00 · ok <30h, atenção <54h, senão crítico
--   Custo insumos (Everest)· apoio        · ok <30d, atenção <60d (referência de custo)
--   DRE/JAFEB              · mensal        · ok se tem mês anterior, atenção m-2, senão crítico
--   Desperdício            · manual        · sempre 'info'

CREATE OR REPLACE VIEW kpi_status_bases AS
WITH bases AS (
  SELECT
    1 AS ordem,
    'Vendas (PDV Eclética)' AS base,
    'ecletica_pagamentos' AS tabela,
    'Diário · 00:30' AS cadencia,
    'auto' AS tipo,
    (SELECT max(synced_at) FROM ecletica_pagamentos) AS ultima_sync,
    (SELECT max(data_hora_fecha) FROM ecletica_pagamentos) AS dado_recente,
    26::numeric  AS ok_horas,
    50::numeric  AS atencao_horas
  UNION ALL
  SELECT
    2, 'Banco BTG (CMV / compras)', 'btg_movimentacoes', 'Diário · 06:00', 'auto',
    (SELECT max(synced_at) FROM btg_movimentacoes),
    (SELECT max(data_movimentacao)::timestamptz FROM btg_movimentacoes),
    30, 54
  UNION ALL
  SELECT
    3, 'Custo insumos (Everest)', 'nf_recebimento', 'Apoio · desperdício', 'manual',
    (SELECT max(importado_em) FROM nf_recebimento),
    (SELECT max(data_entrada)::timestamptz FROM nf_recebimento),
    720, 1440
  UNION ALL
  SELECT
    4, 'DRE / JAFEB', 'dre_competencia', 'Mensal · manual', 'mensal',
    NULL::timestamptz,
    (SELECT max(periodo)::timestamptz FROM dre_competencia),
    NULL, NULL
  UNION ALL
  SELECT
    5, 'Desperdício', 'registro_desperdicio', 'Contínuo · manual', 'info',
    (SELECT max(criado_em) FROM registro_desperdicio),
    NULL::timestamptz,
    NULL, NULL
)
SELECT
  ordem, base, tabela, cadencia, tipo,
  ultima_sync,
  dado_recente,
  CASE
    WHEN tipo = 'info' THEN 'info'
    WHEN tipo = 'mensal' THEN
      CASE
        WHEN dado_recente >= date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo') - interval '1 month' THEN 'ok'
        WHEN dado_recente >= date_trunc('month', now() AT TIME ZONE 'America/Sao_Paulo') - interval '2 month' THEN 'atencao'
        ELSE 'critico'
      END
    WHEN ultima_sync IS NULL THEN 'critico'
    WHEN now() - ultima_sync <= make_interval(hours => ok_horas::int)      THEN 'ok'
    WHEN now() - ultima_sync <= make_interval(hours => atencao_horas::int) THEN 'atencao'
    ELSE 'critico'
  END AS status
FROM bases
ORDER BY ordem;

GRANT SELECT ON kpi_status_bases TO anon, authenticated;
