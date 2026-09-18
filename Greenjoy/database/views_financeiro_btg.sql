-- views_financeiro_btg.sql
-- CMV, Prime Cost e DRE sobre btg_classificado.
--
-- Antes cada view repetia seu próprio JOIN contra jafeb_despesas_mapping com regras
-- divergentes: kpi_cmv_mensal usava COALESCE(nome, descricao), kpi_prime_cost_mensal
-- só nome (perdendo lançamentos sem recebedor), e a DRE procurava natureza 'Impostos'
-- no plural — que não existia, por isso impostos aparecia zerado e a margem inflada.

-- kpi_socios_painel consome kpi_prime_cost_mensal, então precisa sair da frente
-- antes de recriarmos as views daqui. Ele é recriado em views_socios_v2.sql,
-- que roda logo depois (ver aplicar_views.py).
DROP VIEW IF EXISTS kpi_socios_painel;

-- ============================================================
-- kpi_faturamento_mes — base comum de receita, com quebra por canal.
-- O recorte de iFood existe porque a comissão do marketplace é retida na
-- origem: ela nunca aparece como débito no extrato e precisa ser estimada.
-- ============================================================
CREATE OR REPLACE VIEW kpi_faturamento_mes AS
SELECT
    TO_CHAR(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') AS mes,
    ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2) AS faturamento,
    COUNT(*) AS pedidos,
    ROUND(AVG(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)), 2) AS ticket_medio,
    COUNT(DISTINCT DATE(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')) AS dias_operados,
    -- colunas novas vão no fim: CREATE OR REPLACE não deixa inserir no meio
    ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0))
          FILTER (WHERE origem_venda ILIKE '%IFOOD%'), 2) AS faturamento_ifood,
    ROUND(SUM(vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0))
          FILTER (WHERE origem_venda NOT ILIKE '%IFOOD%'), 2) AS faturamento_proprio
FROM ecletica_pagamentos
WHERE flag_canc <> 'C'
GROUP BY 1;

GRANT SELECT ON kpi_faturamento_mes TO anon, authenticated;

-- ============================================================
-- kpi_cmv_mensal — CMV via BTG (natureza Custo)
--
-- Denominador é a receita BRUTA de propósito: é a base contra a qual as metas
-- de bônus (CMV ≤31%) foram calibradas. A DRE usa receita líquida e chega a um
-- percentual maior — as duas convivem, com nomes diferentes.
-- ============================================================
DROP VIEW IF EXISTS kpi_cmv_mensal;
CREATE VIEW kpi_cmv_mensal AS
SELECT
    f.mes,
    COALESCE(ROUND(SUM(b.valor), 2), 0) AS total_compras,
    f.faturamento AS faturamento_mes,
    ROUND(100.0 * COALESCE(SUM(b.valor), 0) / NULLIF(f.faturamento, 0), 1) AS cmv_pct
FROM kpi_faturamento_mes f
LEFT JOIN btg_classificado b
       ON b.mes = f.mes AND b.tipo ILIKE 'D%' AND b.natureza = 'Custo'
GROUP BY f.mes, f.faturamento
ORDER BY f.mes;

-- ============================================================
-- kpi_prime_cost_mensal — CMV + custo total de pessoal
-- Benchmark food service: ≤58% ótimo, ≤65% aceitável, >65% crítico.
--
-- labor_total = folha paga em conta + encargos recolhidos (FGTS et al, que ficam
-- em natureza Imposto/categoria_1 Encargos). É medido, não estimado — o ×1.75 que
-- a versão anterior usava duplicava encargos que agora aparecem separados, e por
-- isso jogava o Prime Cost para 77% e acendia alarme falso no painel dos sócios.
-- labor_estimado fica só como referência de comparação.
--
-- A empresa é LUCRO PRESUMIDO (não Simples — ver btg_classificado.sql), então o
-- INSS patronal é guia própria e é custo de pessoal: 'Encargos' agora é
-- FGTS + INSS/terceiros, ~R$27k/mês em vez de ~R$6k.
--
-- Duas bases convivem de propósito:
--   *_pct          → sobre receita BRUTA. É a régua das metas de bônus.
--   *_liquido_pct  → sobre receita LÍQUIDA de comissão. É a régua do benchmark
--                    de 58%/65%, que o setor mede depois da retenção do canal.
-- O semáforo usa a base líquida: sobre a bruta ele dizia "ótimo" em quase todo
-- mês, e um KPI que nunca acende não serve para nada.
-- ============================================================
-- CASCADE porque views_premio.sql pendura kpi_premio_custo_mensal aqui. Ele roda
-- depois neste mesmo aplicador e recria o que cair junto.
DROP VIEW IF EXISTS kpi_prime_cost_mensal CASCADE;
CREATE VIEW kpi_prime_cost_mensal AS
WITH mov AS (
    SELECT mes,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Custo'), 2) AS cmv,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Folha'), 2) AS labor_direto,
        ROUND(COALESCE(SUM(valor) FILTER
              (WHERE natureza = 'Imposto' AND categoria_1 = 'Encargos'), 0), 2) AS encargos
    FROM btg_classificado
    WHERE tipo ILIKE 'D%'
    GROUP BY mes
)
SELECT
    f.mes,
    f.faturamento AS faturamento_mes,
    COALESCE(m.cmv, 0)          AS cmv,
    COALESCE(m.labor_direto, 0) AS labor_direto,
    COALESCE(m.encargos, 0)     AS encargos,
    COALESCE(m.labor_direto, 0) + COALESCE(m.encargos, 0) AS labor_total,
    ROUND(COALESCE(m.labor_direto, 0) * 1.75, 2) AS labor_estimado,
    ROUND(100.0 * COALESCE(m.cmv, 0) / NULLIF(f.faturamento, 0), 1) AS cmv_pct,
    ROUND(100.0 * COALESCE(m.labor_direto, 0) / NULLIF(f.faturamento, 0), 1) AS labor_direto_pct,
    ROUND(100.0 * (COALESCE(m.labor_direto, 0) + COALESCE(m.encargos, 0))
          / NULLIF(f.faturamento, 0), 1) AS labor_total_pct,
    ROUND(100.0 * COALESCE(m.labor_direto, 0) * 1.75 / NULLIF(f.faturamento, 0), 1) AS labor_estimado_pct,
    ROUND(100.0 * (COALESCE(m.cmv, 0) + COALESCE(m.labor_direto, 0))
          / NULLIF(f.faturamento, 0), 1) AS prime_cost_direto_pct,
    -- número oficial do painel: CMV + folha + encargos, tudo medido no extrato
    ROUND(100.0 * (COALESCE(m.cmv, 0) + COALESCE(m.labor_direto, 0) + COALESCE(m.encargos, 0))
          / NULLIF(f.faturamento, 0), 1) AS prime_cost_pct,
    ROUND(100.0 * (COALESCE(m.cmv, 0) + COALESCE(m.labor_direto, 0) * 1.75)
          / NULLIF(f.faturamento, 0), 1) AS prime_cost_estimado_pct,
    CASE
        WHEN 100.0 * (COALESCE(m.cmv,0) + COALESCE(m.labor_direto,0) + COALESCE(m.encargos,0))
             / NULLIF(rl.receita_liquida, 0) <= 58 THEN 'otimo'
        WHEN 100.0 * (COALESCE(m.cmv,0) + COALESCE(m.labor_direto,0) + COALESCE(m.encargos,0))
             / NULLIF(rl.receita_liquida, 0) <= 65 THEN 'bom'
        ELSE 'critico'
    END AS semaforo_prime_cost,
    -- colunas novas no fim: CREATE OR REPLACE não deixa inserir no meio
    ROUND(rl.receita_liquida, 2) AS receita_liquida,
    ROUND(100.0 * COALESCE(m.cmv, 0) / NULLIF(rl.receita_liquida, 0), 1) AS cmv_liquido_pct,
    ROUND(100.0 * (COALESCE(m.labor_direto, 0) + COALESCE(m.encargos, 0))
          / NULLIF(rl.receita_liquida, 0), 1) AS labor_liquido_pct,
    ROUND(100.0 * (COALESCE(m.cmv, 0) + COALESCE(m.labor_direto, 0) + COALESCE(m.encargos, 0))
          / NULLIF(rl.receita_liquida, 0), 1) AS prime_cost_liquido_pct
FROM kpi_faturamento_mes f
LEFT JOIN mov m ON m.mes = f.mes
CROSS JOIN LATERAL (
    SELECT f.faturamento
         - COALESCE(f.faturamento_ifood, 0)   * 0.159
         - COALESCE(f.faturamento_proprio, 0) * 0.055 AS receita_liquida
) rl
ORDER BY f.mes;

-- ============================================================
-- kpi_dre_btg_mensal — DRE de caixa completa
--
-- Escada igual à da DRE de competência do JAFEB (aposentada em mai/2026), que
-- serve de gabarito: para jan-abr/2026 o EBITDA daqui tem que ficar perto do
-- EBITDA de lá. A versão anterior desta view dava o dobro, por três motivos:
--
--  1. a comissão do iFood não existia em lugar nenhum. Ela é retida na origem e
--     nunca vira débito no extrato — some da conta se ninguém estimar. Com iFood
--     em ~70% da receita, era a maior despesa da operação, invisível;
--  2. royalty e fundo de propaganda estavam dentro do CMV (ver btg_classificado.sql);
--  3. o não classificado ficava fora do resultado, inflando a margem.
--
-- Duas deduções de receita, ambas retidas na origem, ambas ESTIMADAS. A tela
-- precisa dizer isso. Calibração contra a linha 'Descontos' da DRE do JAFEB,
-- que decompõe exatamente nestas parcelas, nos seis meses limpos de nov/2025 a
-- abr/2026:
--
--   15,9% do faturamento iFood — linha 'Taxas e Comissões - Ifood'.
--     Medido: 15,71 / 15,74 / 15,78 / 15,87 / 16,13 / 16,18.
--     Antes de ago/2025 era ~19%: mudou quando o contrato mudou.
--   5,5% do faturamento próprio — incentivos iFood, adquirente (Stone,
--     Pagbank) e vouchers (Alelo, Ticket, Pluxee, VR), que entram na conta já
--     líquidos. Medido: 4,09 / 4,38 / 5,48 / 6,33 / 6,34 / 6,66.
--
-- As duas juntas reproduzem a linha 'Descontos' do JAFEB com erro máximo de
-- 3,4% (±R$2k sobre ~R$70k).
--
-- mes_confiavel: o extrato BTG tem buraco em ago e set/2025 (185 e 24
-- lançamentos contra 480-650 normais). Sem isso a DRE desses meses vira ficção
-- (CMV aparecia como 8,4% e 1,0%). A view não esconde o mês — marca.
-- ============================================================
DROP VIEW IF EXISTS kpi_dre_btg_mensal;
CREATE VIEW kpi_dre_btg_mensal AS
WITH mov AS (
    SELECT mes,
        COUNT(*)                                                          AS n_debitos,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Custo'), 2)            AS cmv,
        -- folha inclui os encargos: FGTS e INSS patronal são custo de pessoal,
        -- não tributo sobre venda, e é assim que o benchmark de 18-24% mede
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Folha'
              OR (natureza = 'Imposto' AND categoria_1 = 'Encargos')), 2)  AS folha,
        -- tributo sobre faturamento (PIS, COFINS, ICMS, ISS): fica acima do EBITDA
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Imposto'
              AND categoria_1 <> 'Encargos'
              AND COALESCE(categoria_2, '') <> 'IRPJ e CSLL'), 2)          AS impostos,
        -- imposto sobre o lucro: fica ABAIXO do EBITDA, como na DRE do JAFEB
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Imposto'
              AND categoria_2 = 'IRPJ e CSLL'), 2)                         AS irpj_csll,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'CAPEX'), 2)            AS capex,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Transferência'), 2)    AS transferencias,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Não classificado'), 2) AS nao_classificado,
        -- despesa operacional quebrada nas rubricas que se cobram de um franqueado
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Despesa'
              AND categoria_2 = 'Royalties'), 2)                          AS royalties,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Despesa'
              AND categoria_2 IN ('Fundo de propaganda', 'Taxa fixa')), 2) AS fundo_propaganda,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Despesa'
              AND (categoria_1 ILIKE 'Aluguel%' OR categoria_1 IN ('Energia', 'Utilities', 'Gas')
                   OR categoria_2 IN ('Utilities', 'Água', 'Lixo'))), 2)  AS ocupacao,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Despesa'
              AND categoria_1 <> 'Franquia'
              AND NOT (categoria_1 ILIKE 'Aluguel%' OR categoria_1 IN ('Energia', 'Utilities', 'Gas')
                       OR categoria_2 IN ('Utilities', 'Água', 'Lixo'))), 2) AS outras_despesas,
        ROUND(SUM(valor) FILTER (WHERE natureza = 'Despesa'), 2)          AS despesas_op
    FROM btg_classificado
    WHERE tipo ILIKE 'D%'
    GROUP BY mes
),
base AS (
    SELECT
        f.mes,
        f.faturamento                        AS receita_bruta,
        COALESCE(f.faturamento_ifood, 0)     AS receita_ifood,
        COALESCE(f.faturamento_proprio, 0)   AS receita_propria,
        ROUND(COALESCE(f.faturamento_ifood, 0) * 0.159, 2) AS comissao_marketplace,
        ROUND(COALESCE(f.faturamento_proprio, 0) * 0.055, 2) AS taxas_cartao,
        COALESCE(m.cmv, 0)              AS cmv,
        COALESCE(m.folha, 0)            AS folha,
        COALESCE(m.royalties, 0)        AS royalties,
        COALESCE(m.fundo_propaganda, 0) AS fundo_propaganda,
        COALESCE(m.ocupacao, 0)         AS ocupacao,
        COALESCE(m.outras_despesas, 0)  AS outras_despesas,
        COALESCE(m.despesas_op, 0)      AS despesas_op,
        COALESCE(m.impostos, 0)         AS impostos,
        COALESCE(m.irpj_csll, 0)        AS irpj_csll,
        COALESCE(m.capex, 0)            AS capex,
        COALESCE(m.transferencias, 0)   AS transferencias,
        COALESCE(m.nao_classificado, 0) AS nao_classificado,
        (COALESCE(m.n_debitos, 0) >= 200 OR f.mes = TO_CHAR(hoje_br(), 'YYYY-MM'))
            AND f.faturamento > 100000  AS mes_confiavel,
        -- mês em curso não fecha: DAS e royalty caem depois do dia 20, então
        -- até lá o EBITDA parcial aparece alto por falta de despesa, não por lucro
        f.mes = TO_CHAR(hoje_br(), 'YYYY-MM') AS mes_em_curso
    FROM kpi_faturamento_mes f
    LEFT JOIN mov m ON m.mes = f.mes
),
escada AS (
    SELECT *,
        receita_bruta - comissao_marketplace - taxas_cartao AS receita_liquida,
        receita_bruta - comissao_marketplace - taxas_cartao - cmv AS lucro_bruto,
        -- EBITDA: tudo que é operação, inclusive o não classificado. Deixá-lo de
        -- fora era o mesmo que supor que todo débito sem de-para é irrelevante.
        receita_bruta - comissao_marketplace - taxas_cartao - cmv - folha - royalties
            - fundo_propaganda - ocupacao - outras_despesas - impostos
            - nao_classificado AS ebitda
    FROM base
),
-- O mês isolado não é confiável: contra a DRE de competência do JAFEB o erro
-- mensal chega a 85%, porque DAS e ICMS entram com defasagem e compra é lumpy.
-- Em janela de 3 meses o erro cai para menos de 1%. É esta a granularidade que
-- a tela deve destacar.
rolling AS (
    SELECT *,
        ROUND(AVG(ebitda) FILTER (WHERE mes_confiavel AND NOT mes_em_curso)
              OVER (ORDER BY mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS ebitda_3m,
        ROUND(100.0 * SUM(ebitda) FILTER (WHERE mes_confiavel AND NOT mes_em_curso)
                      OVER (ORDER BY mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
            / NULLIF(SUM(receita_liquida) FILTER (WHERE mes_confiavel AND NOT mes_em_curso)
                     OVER (ORDER BY mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0), 1) AS ebitda_3m_pct
    FROM escada
)
SELECT
    mes,
    mes_confiavel,
    mes_em_curso,
    receita_bruta,
    receita_ifood,
    receita_propria,
    comissao_marketplace,
    taxas_cartao,
    receita_liquida,
    cmv,
    lucro_bruto,
    folha,
    royalties,
    fundo_propaganda,
    ocupacao,
    outras_despesas,
    despesas_op,
    impostos,
    nao_classificado,
    ebitda,
    irpj_csll,
    ebitda - irpj_csll AS resultado_pre_investimento,
    capex,
    ebitda - irpj_csll - capex AS resultado_pos_capex,
    transferencias,
    -- percentuais sobre receita líquida: é o que o franqueado de fato fatura
    -- depois da retenção do marketplace, e a base correta para comparar com
    -- benchmark de fast casual
    ebitda_3m,
    ebitda_3m_pct,
    ROUND(100.0 * comissao_marketplace / NULLIF(receita_bruta, 0), 1) AS comissao_pct,
    ROUND(100.0 * taxas_cartao / NULLIF(receita_bruta, 0), 1) AS taxas_cartao_pct,
    ROUND(100.0 * cmv             / NULLIF(receita_liquida, 0), 1) AS cmv_pct,
    ROUND(100.0 * lucro_bruto     / NULLIF(receita_liquida, 0), 1) AS lucro_bruto_pct,
    ROUND(100.0 * folha           / NULLIF(receita_liquida, 0), 1) AS folha_pct,
    ROUND(100.0 * (royalties + fundo_propaganda)
                                  / NULLIF(receita_liquida, 0), 1) AS franquia_pct,
    ROUND(100.0 * ocupacao        / NULLIF(receita_liquida, 0), 1) AS ocupacao_pct,
    ROUND(100.0 * outras_despesas / NULLIF(receita_liquida, 0), 1) AS outras_despesas_pct,
    ROUND(100.0 * despesas_op     / NULLIF(receita_liquida, 0), 1) AS despesas_pct,
    ROUND(100.0 * impostos        / NULLIF(receita_liquida, 0), 1) AS impostos_pct,
    ROUND(100.0 * nao_classificado/ NULLIF(receita_liquida, 0), 1) AS nao_classificado_pct,
    ROUND(100.0 * ebitda          / NULLIF(receita_liquida, 0), 1) AS ebitda_pct,
    -- nome antigo mantido: kpi_socios_painel e a home ainda leem daqui
    ROUND(ebitda, 2)                                               AS resultado_op,
    ROUND(100.0 * ebitda          / NULLIF(receita_liquida, 0), 1) AS margem_op_pct,
    receita_bruta                                                  AS faturamento_mes
FROM rolling
ORDER BY mes;

-- ============================================================
-- kpi_conciliacao_royalty — controle de auditoria de graça.
--
-- O royalty é 5,000% exato do faturamento líquido do mês anterior. Então
-- pagamento ÷ 0,05 é uma medição do faturamento feita por um terceiro que tem
-- todo o incentivo de não subestimá-la. Divergência contra o PDV aponta venda
-- não registrada, sangria ou falha de sync — e custa uma view.
-- ============================================================
CREATE OR REPLACE VIEW kpi_conciliacao_royalty AS
WITH pago AS (
    SELECT mes AS mes_pagamento,
           TO_CHAR((TO_DATE(mes, 'YYYY-MM') - INTERVAL '1 month'), 'YYYY-MM') AS mes_base,
           ROUND(SUM(valor), 2) AS royalty
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND categoria_2 = 'Royalties'
    GROUP BY mes
)
SELECT
    p.mes_base,
    p.mes_pagamento,
    p.royalty,
    ROUND(p.royalty / 0.05, 2) AS faturamento_franqueadora,
    f.faturamento              AS faturamento_pdv,
    ROUND(p.royalty / 0.05 - f.faturamento, 2) AS divergencia,
    ROUND(100.0 * (p.royalty / 0.05 - f.faturamento) / NULLIF(f.faturamento, 0), 2) AS divergencia_pct,
    ABS(p.royalty / 0.05 - f.faturamento) > 500 AS alerta
FROM pago p
JOIN kpi_faturamento_mes f ON f.mes = p.mes_base
ORDER BY p.mes_base DESC;

GRANT SELECT ON kpi_cmv_mensal, kpi_prime_cost_mensal, kpi_dre_btg_mensal,
                kpi_conciliacao_royalty
      TO anon, authenticated;
