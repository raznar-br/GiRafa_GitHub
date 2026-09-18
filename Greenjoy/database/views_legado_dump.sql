-- views_legado_dump.sql — GERADO AUTOMATICAMENTE por dump_views_faltantes.py
-- Views que existem no banco e não foram reescritas na revisão de Ago/2026.
-- Estão aqui para o schema ser reproduzível do zero. Ao mexer em alguma,
-- mova a definição para o arquivo temático correspondente e rode o dump de novo.

CREATE OR REPLACE VIEW kpi_bonus_diario AS
WITH cfg AS (
         SELECT bonus_config.meta_semanal
           FROM bonus_config
          WHERE (bonus_config.id = 1)
        ), dias AS (
         SELECT ((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text))::date AS dia,
            count(*) AS pedidos,
            sum(((ecletica_pagamentos.vlr_total + COALESCE(ecletica_pagamentos.vlr_serv, (0)::numeric)) - COALESCE(ecletica_pagamentos.vlr_desc_tot, (0)::numeric))) AS faturamento_liquido
           FROM ecletica_pagamentos
          WHERE ((ecletica_pagamentos.flag_canc <> 'C'::text) AND (ecletica_pagamentos.data_hora_fecha >= (((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date - '35 days'::interval)))
          GROUP BY (((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text))::date)
        )
 SELECT d.dia,
    (date_trunc('week'::text, (d.dia)::timestamp with time zone))::date AS semana_inicio,
    (EXTRACT(isodow FROM d.dia))::integer AS dia_semana,
    d.pedidos,
    round(((d.faturamento_liquido / (cfg.meta_semanal / (7)::numeric)) * (100)::numeric), 1) AS pct_meta_diaria
   FROM (dias d
     CROSS JOIN cfg)
  ORDER BY d.dia DESC;
GRANT SELECT ON kpi_bonus_diario TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_bonus_mensal AS
WITH cfg AS (
         SELECT bonus_config.id,
            bonus_config.meta_semanal,
            bonus_config.pool_base,
            bonus_config.pool_target,
            bonus_config.pool_stretch,
            bonus_config.pct_base,
            bonus_config.pct_stretch,
            bonus_config.total_cotas,
            bonus_config.cota_operacional,
            bonus_config.cota_lider,
            bonus_config.cota_chefe,
            bonus_config.atualizado_em,
            bonus_config.bonus_cmv_mensal
           FROM bonus_config
          WHERE (bonus_config.id = 1)
        )
 SELECT s.mes_referencia AS mes,
    count(*) FILTER (WHERE s.semana_fechada) AS semanas_fechadas,
    sum(s.pool_semana) FILTER (WHERE s.semana_fechada) AS pool_acumulado,
    m.qualinut,
    m.ifood_super,
    m.google,
    m.cmv_abaixo_30,
    m.cmv_pct,
    ((((1)::numeric +
        CASE
            WHEN m.qualinut THEN 0.10
            ELSE (0)::numeric
        END) +
        CASE
            WHEN m.ifood_super THEN 0.05
            ELSE (0)::numeric
        END) +
        CASE
            WHEN m.google THEN 0.05
            ELSE (0)::numeric
        END) AS multiplicador,
        CASE
            WHEN (m.cmv_abaixo_30 = true) THEN cfg.bonus_cmv_mensal
            ELSE (0)::numeric
        END AS bonus_cmv,
    round(((COALESCE(sum(s.pool_semana) FILTER (WHERE s.semana_fechada), (0)::numeric) * ((((1)::numeric +
        CASE
            WHEN m.qualinut THEN 0.10
            ELSE (0)::numeric
        END) +
        CASE
            WHEN m.ifood_super THEN 0.05
            ELSE (0)::numeric
        END) +
        CASE
            WHEN m.google THEN 0.05
            ELSE (0)::numeric
        END)) +
        CASE
            WHEN (m.cmv_abaixo_30 = true) THEN cfg.bonus_cmv_mensal
            ELSE (0)::numeric
        END), 2) AS pool_final_projetado
   FROM ((kpi_bonus_semanal s
     LEFT JOIN bonus_multiplicadores m ON ((m.mes = s.mes_referencia)))
     CROSS JOIN cfg)
  GROUP BY s.mes_referencia, m.qualinut, m.ifood_super, m.google, m.cmv_abaixo_30, m.cmv_pct, cfg.bonus_cmv_mensal
  ORDER BY s.mes_referencia DESC;
GRANT SELECT ON kpi_bonus_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_canal_evolucao_6m AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
        CASE
            WHEN (origem_venda ~~* '%IFOOD%'::text) THEN 'iFood'::text
            WHEN (origem_venda ~~* '%DELIVERY%'::text) THEN 'Delivery'::text
            ELSE 'Balcao'::text
        END AS canal,
    count(*) AS pedidos,
    round(sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS fat_liquido,
    round(avg(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS ticket_medio,
    round(((100.0 * sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric)))) / sum(sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric)))) OVER (PARTITION BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)))), 1) AS pct_canal
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (data_hora_fecha >= date_trunc('month'::text, (CURRENT_DATE - '5 mons'::interval))))
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)),
        CASE
            WHEN (origem_venda ~~* '%IFOOD%'::text) THEN 'iFood'::text
            WHEN (origem_venda ~~* '%DELIVERY%'::text) THEN 'Delivery'::text
            ELSE 'Balcao'::text
        END
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC, (round(sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2)) DESC;
GRANT SELECT ON kpi_canal_evolucao_6m TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_cmv_categoria_mensal AS
WITH mapa AS (
         SELECT DISTINCT ON ((upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)))) upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)) AS key,
                CASE
                    WHEN (lower(TRIM(BOTH FROM jafeb_despesas_mapping.categoria_2)) = 'bebidas'::text) THEN 'Bebidas'::text
                    ELSE jafeb_despesas_mapping.categoria_2
                END AS categoria_2
           FROM jafeb_despesas_mapping
          WHERE (jafeb_despesas_mapping.natureza = 'Custo'::text)
          ORDER BY (upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao))), jafeb_despesas_mapping.id
        ), cmv_cat AS (
         SELECT to_char(date_trunc('month'::text, (b.data_movimentacao)::timestamp with time zone), 'YYYY-MM'::text) AS mes,
            m.categoria_2,
            round(sum(b.valor), 2) AS total
           FROM (btg_movimentacoes b
             JOIN mapa m ON ((upper(TRIM(BOTH FROM b.nome_pagador_recebedor)) = m.key)))
          WHERE (b.tipo = 'Débito'::text)
          GROUP BY (to_char(date_trunc('month'::text, (b.data_movimentacao)::timestamp with time zone), 'YYYY-MM'::text)), m.categoria_2
        ), fat AS (
         SELECT to_char(date_trunc('month'::text, (date((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)))::timestamp with time zone), 'YYYY-MM'::text) AS mes,
            round(sum(((ecletica_pagamentos.vlr_total + COALESCE(ecletica_pagamentos.vlr_serv, (0)::numeric)) - COALESCE(ecletica_pagamentos.vlr_desc_tot, (0)::numeric))), 2) AS faturamento_mes
           FROM ecletica_pagamentos
          WHERE (ecletica_pagamentos.flag_canc <> 'C'::text)
          GROUP BY (to_char(date_trunc('month'::text, (date((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)))::timestamp with time zone), 'YYYY-MM'::text))
        )
 SELECT c.mes,
    c.categoria_2,
    c.total,
    f.faturamento_mes,
    round(((c.total / NULLIF(f.faturamento_mes, (0)::numeric)) * (100)::numeric), 1) AS pct_faturamento
   FROM (cmv_cat c
     LEFT JOIN fat f ON ((c.mes = f.mes)))
  ORDER BY c.mes DESC, c.total DESC;
GRANT SELECT ON kpi_cmv_categoria_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_cmv_fornecedor_mensal AS
WITH mapa AS (
         SELECT DISTINCT ON ((upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)))) upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)) AS key,
            jafeb_despesas_mapping.categoria_2 AS categoria
           FROM jafeb_despesas_mapping
          WHERE (jafeb_despesas_mapping.natureza = 'Custo'::text)
          ORDER BY (upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao))), jafeb_despesas_mapping.id
        )
 SELECT to_char((b.data_movimentacao)::timestamp with time zone, 'YYYY-MM'::text) AS mes,
    b.nome_pagador_recebedor AS fornecedor,
    round(sum(b.valor), 2) AS custo_total,
    count(*) AS qtd_nf,
    m.categoria
   FROM (btg_movimentacoes b
     JOIN mapa m ON ((upper(TRIM(BOTH FROM b.nome_pagador_recebedor)) = m.key)))
  WHERE (b.tipo = 'Débito'::text)
  GROUP BY (to_char((b.data_movimentacao)::timestamp with time zone, 'YYYY-MM'::text)), b.nome_pagador_recebedor, m.categoria
  ORDER BY (to_char((b.data_movimentacao)::timestamp with time zone, 'YYYY-MM'::text)) DESC, (round(sum(b.valor), 2)) DESC;
GRANT SELECT ON kpi_cmv_fornecedor_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_cmv_semanal AS
WITH mapa AS (
         SELECT DISTINCT ON ((upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)))) upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)) AS key
           FROM jafeb_despesas_mapping
          WHERE (jafeb_despesas_mapping.natureza = 'Custo'::text)
          ORDER BY (upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao))), jafeb_despesas_mapping.id
        ), compras AS (
         SELECT (date_trunc('week'::text, (b.data_movimentacao)::timestamp with time zone))::date AS semana_inicio,
            round(sum(b.valor), 2) AS total_compras
           FROM (btg_movimentacoes b
             JOIN mapa m ON ((upper(TRIM(BOTH FROM b.nome_pagador_recebedor)) = m.key)))
          WHERE (b.tipo = 'Débito'::text)
          GROUP BY ((date_trunc('week'::text, (b.data_movimentacao)::timestamp with time zone))::date)
        ), fat AS (
         SELECT (date_trunc('week'::text, (ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)))::date AS semana_inicio,
            round(sum(((ecletica_pagamentos.vlr_total + COALESCE(ecletica_pagamentos.vlr_serv, (0)::numeric)) - COALESCE(ecletica_pagamentos.vlr_desc_tot, (0)::numeric))), 2) AS faturamento_semana
           FROM ecletica_pagamentos
          WHERE (ecletica_pagamentos.flag_canc <> 'C'::text)
          GROUP BY ((date_trunc('week'::text, (ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)))::date)
        )
 SELECT c.semana_inicio,
    c.total_compras,
    COALESCE(f.faturamento_semana, (0)::numeric) AS faturamento_semana,
    round(((100.0 * c.total_compras) / NULLIF(f.faturamento_semana, (0)::numeric)), 1) AS cmv_pct
   FROM (compras c
     LEFT JOIN fat f USING (semana_inicio))
  ORDER BY c.semana_inicio DESC;
GRANT SELECT ON kpi_cmv_semanal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_cmv_top_itens AS
SELECT i.descr_produto,
    i.categoria,
    COALESCE(i.fornecedor, r.fornecedor) AS fornecedor,
    count(DISTINCT i.num_nf) AS qtd_nf,
    round(sum(i.qtde), 2) AS qtde_total,
    max(i.unidade) AS unidade,
    round(sum(i.vlr_total), 2) AS custo_total,
    round(((100.0 * sum(i.vlr_total)) / NULLIF(sum(sum(i.vlr_total)) OVER (), (0)::numeric)), 1) AS pct_total
   FROM (nf_itens i
     LEFT JOIN nf_recebimento r ON (((i.num_nf = r.num_nf) AND (i.loja = r.loja))))
  WHERE (i.loja = 'analia_franco'::text)
  GROUP BY i.descr_produto, i.categoria, COALESCE(i.fornecedor, r.fornecedor)
  ORDER BY (round(sum(i.vlr_total), 2)) DESC
 LIMIT 50;
GRANT SELECT ON kpi_cmv_top_itens TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_conciliacao_diaria AS
SELECT dia,
    fat_pdv,
    creditos_btg,
    debitos_btg,
    round((COALESCE(fat_pdv, (0)::numeric) - COALESCE(creditos_btg, (0)::numeric)), 2) AS diferenca
   FROM ( SELECT COALESCE(p.dia, b.dia) AS dia,
            p.fat_pdv,
            b.creditos_btg,
            b.debitos_btg
           FROM (( SELECT date((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)) AS dia,
                    round(sum(((ecletica_pagamentos.vlr_total + COALESCE(ecletica_pagamentos.vlr_serv, (0)::numeric)) - COALESCE(ecletica_pagamentos.vlr_desc_tot, (0)::numeric))), 2) AS fat_pdv
                   FROM ecletica_pagamentos
                  WHERE ((ecletica_pagamentos.flag_canc <> 'C'::text) AND (ecletica_pagamentos.data_hora_fecha >= (now() - '90 days'::interval)))
                  GROUP BY (date((ecletica_pagamentos.data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text)))) p
             FULL JOIN ( SELECT btg_movimentacoes.data_movimentacao AS dia,
                    round(sum(btg_movimentacoes.valor) FILTER (WHERE (btg_movimentacoes.tipo = 'Crédito'::text)), 2) AS creditos_btg,
                    round(sum(btg_movimentacoes.valor) FILTER (WHERE (btg_movimentacoes.tipo = 'Débito'::text)), 2) AS debitos_btg
                   FROM btg_movimentacoes
                  GROUP BY btg_movimentacoes.data_movimentacao) b ON ((p.dia = b.dia)))) t
  ORDER BY dia DESC;
GRANT SELECT ON kpi_conciliacao_diaria TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_curva_abc_cmv AS
WITH mapa AS (
         SELECT DISTINCT ON ((upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)))) upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)) AS key,
            jafeb_despesas_mapping.categoria_2 AS categoria
           FROM jafeb_despesas_mapping
          WHERE (jafeb_despesas_mapping.natureza = 'Custo'::text)
          ORDER BY (upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao))), jafeb_despesas_mapping.id
        ), custo AS (
         SELECT COALESCE(m.categoria, 'Sem categoria'::text) AS categoria,
            count(*) AS qtd_nf,
            round(sum(b.valor), 2) AS custo_total
           FROM (btg_movimentacoes b
             JOIN mapa m ON ((upper(TRIM(BOTH FROM b.nome_pagador_recebedor)) = m.key)))
          WHERE (b.tipo = 'Débito'::text)
          GROUP BY COALESCE(m.categoria, 'Sem categoria'::text)
        ), total AS (
         SELECT sum(custo.custo_total) AS geral
           FROM custo
        ), ranking AS (
         SELECT c.categoria,
            c.qtd_nf,
            c.custo_total,
            round(((100.0 * c.custo_total) / NULLIF(t.geral, (0)::numeric)), 2) AS pct_custo,
            round(((100.0 * sum(c.custo_total) OVER (ORDER BY c.custo_total DESC)) / NULLIF(t.geral, (0)::numeric)), 2) AS pct_acumulado,
            row_number() OVER (ORDER BY c.custo_total DESC) AS posicao
           FROM custo c,
            total t
        )
 SELECT posicao,
    categoria,
    qtd_nf,
    custo_total,
    pct_custo,
    pct_acumulado,
        CASE
            WHEN (pct_acumulado <= (80)::numeric) THEN 'A'::text
            WHEN (pct_acumulado <= (95)::numeric) THEN 'B'::text
            ELSE 'C'::text
        END AS curva
   FROM ranking
  ORDER BY posicao;
GRANT SELECT ON kpi_curva_abc_cmv TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_desperdicio_mensal AS
SELECT (date_trunc('month'::text, (data)::timestamp with time zone))::date AS mes,
    count(*) AS qtde_registros,
    count(DISTINCT data) AS dias_com_registro,
    round(sum((qtde * COALESCE(vlr_unit, (0)::numeric))), 2) AS total_valor,
    round((sum((qtde * COALESCE(vlr_unit, (0)::numeric))) / (NULLIF(count(DISTINCT data), 0))::numeric), 2) AS media_dia
   FROM registro_desperdicio
  WHERE (loja = 'analia_franco'::text)
  GROUP BY ((date_trunc('month'::text, (data)::timestamp with time zone))::date)
  ORDER BY ((date_trunc('month'::text, (data)::timestamp with time zone))::date) DESC;
GRANT SELECT ON kpi_desperdicio_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_desperdicio_por_motivo AS
SELECT motivo,
    count(*) AS ocorrencias,
    round(sum((qtde * COALESCE(vlr_unit, (0)::numeric))), 2) AS total_valor,
    round(((sum((qtde * COALESCE(vlr_unit, (0)::numeric))) * 100.0) / NULLIF(sum(sum((qtde * COALESCE(vlr_unit, (0)::numeric)))) OVER (), (0)::numeric)), 1) AS pct_total
   FROM registro_desperdicio
  WHERE (loja = 'analia_franco'::text)
  GROUP BY motivo
  ORDER BY (round(sum((qtde * COALESCE(vlr_unit, (0)::numeric))), 2)) DESC;
GRANT SELECT ON kpi_desperdicio_por_motivo TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_desperdicio_top_itens AS
SELECT descr_livre,
    count(*) AS ocorrencias,
    round(sum(qtde), 3) AS qtde_total,
    max(unidade) AS unidade,
    round(sum((qtde * COALESCE(vlr_unit, (0)::numeric))), 2) AS total_valor
   FROM registro_desperdicio
  WHERE (loja = 'analia_franco'::text)
  GROUP BY descr_livre
  ORDER BY (round(sum((qtde * COALESCE(vlr_unit, (0)::numeric))), 2)) DESC
 LIMIT 20;
GRANT SELECT ON kpi_desperdicio_top_itens TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_despesas_por_categoria AS
WITH mapa AS (
         SELECT DISTINCT ON ((upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)))) upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao)) AS key,
            jafeb_despesas_mapping.categoria_2,
            jafeb_despesas_mapping.natureza
           FROM jafeb_despesas_mapping
          ORDER BY (upper(TRIM(BOTH FROM jafeb_despesas_mapping.descricao))), jafeb_despesas_mapping.id
        )
 SELECT (date_trunc('month'::text, (b.data_movimentacao)::timestamp with time zone))::date AS mes,
    COALESCE(m.categoria_2, 'Não mapeado'::text) AS categoria,
    COALESCE(m.natureza, 'Não mapeado'::text) AS natureza,
    count(*) AS qtd_nf,
    round(sum(b.valor), 2) AS total
   FROM (btg_movimentacoes b
     LEFT JOIN mapa m ON ((upper(TRIM(BOTH FROM COALESCE(b.nome_pagador_recebedor, b.descricao))) = m.key)))
  WHERE (b.tipo = 'Débito'::text)
  GROUP BY ((date_trunc('month'::text, (b.data_movimentacao)::timestamp with time zone))::date), COALESCE(m.categoria_2, 'Não mapeado'::text), COALESCE(m.natureza, 'Não mapeado'::text)
  ORDER BY ((date_trunc('month'::text, (b.data_movimentacao)::timestamp with time zone))::date) DESC, (round(sum(b.valor), 2)) DESC;
GRANT SELECT ON kpi_despesas_por_categoria TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_dre_clevel AS
WITH linhas AS (
         SELECT dre_competencia.periodo,
            dre_competencia.linha_dre,
            sum(dre_competencia.valor) AS valor
           FROM dre_competencia
          WHERE (dre_competencia.linha_dre = ANY (ARRAY['Receita Bruta'::text, 'Descontos'::text, 'Taxas e Comissões - Ifood'::text, 'Receita Líquida de descontos'::text, 'Impostos Diretos'::text, 'Receita Líquida de impostos'::text, 'Custos'::text, 'Lucro Bruto'::text, 'Funcionários'::text, 'Royalties'::text, 'Aluguel e IPTU'::text, 'Utilities'::text, 'Produtos de Limpeza'::text, 'Mensalidade'::text, 'Despesas'::text, 'EBITDA'::text, 'IRPJ e CSLL'::text]))
          GROUP BY dre_competencia.periodo, dre_competencia.linha_dre
        ), rec_bruta AS (
         SELECT linhas.periodo,
            linhas.valor AS receita_bruta
           FROM linhas
          WHERE (linhas.linha_dre = 'Receita Bruta'::text)
        )
 SELECT l.periodo,
    l.linha_dre,
    round(l.valor, 2) AS valor,
    round(((100.0 * l.valor) / NULLIF(r.receita_bruta, (0)::numeric)), 1) AS pct_receita
   FROM (linhas l
     JOIN rec_bruta r ON ((l.periodo = r.periodo)))
  ORDER BY l.periodo DESC, (abs(l.valor)) DESC;
GRANT SELECT ON kpi_dre_clevel TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_dre_resumo AS
SELECT dc.periodo,
    m.natureza,
    m.categoria_2 AS categoria,
    round(sum(dc.valor), 2) AS valor
   FROM (dre_competencia dc
     JOIN jafeb_despesas_mapping m ON ((dc.linha_dre = m.descricao)))
  GROUP BY dc.periodo, m.natureza, m.categoria_2
  ORDER BY dc.periodo DESC, (abs(sum(dc.valor))) DESC;
GRANT SELECT ON kpi_dre_resumo TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_cancelamentos_mensal AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
    count(*) AS total_pedidos,
    count(
        CASE
            WHEN (flag_canc = 'C'::text) THEN 1
            ELSE NULL::integer
        END) AS cancelados,
    round(((100.0 * (count(
        CASE
            WHEN (flag_canc = 'C'::text) THEN 1
            ELSE NULL::integer
        END))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS taxa_cancelamento_pct,
    round(sum(
        CASE
            WHEN (flag_canc = 'C'::text) THEN vlr_total
            ELSE (0)::numeric
        END), 2) AS fat_cancelado
   FROM ecletica_pagamentos
  WHERE (origem_venda ~~* '%IFOOD%'::text)
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC;
GRANT SELECT ON kpi_ifood_cancelamentos_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_descontos_faixa AS
SELECT
        CASE
            WHEN (vlr_desc_tot = (0)::numeric) THEN 'Sem desconto'::text
            WHEN (vlr_desc_tot < (5)::numeric) THEN 'Até R$5'::text
            WHEN (vlr_desc_tot < (10)::numeric) THEN 'R$5–10'::text
            WHEN (vlr_desc_tot < (20)::numeric) THEN 'R$10–20'::text
            ELSE 'Acima R$20'::text
        END AS faixa,
    count(*) AS pedidos,
    round(((100.0 * (count(*))::numeric) / sum(count(*)) OVER ()), 1) AS pct_pedidos,
    round(sum(vlr_desc_tot), 2) AS total_descontado,
    round(avg(vlr_total), 2) AS ticket_bruto_medio,
    round(avg(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS ticket_liquido_medio
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text) AND (data_hora_fecha >= (CURRENT_DATE - '90 days'::interval)))
  GROUP BY
        CASE
            WHEN (vlr_desc_tot = (0)::numeric) THEN 'Sem desconto'::text
            WHEN (vlr_desc_tot < (5)::numeric) THEN 'Até R$5'::text
            WHEN (vlr_desc_tot < (10)::numeric) THEN 'R$5–10'::text
            WHEN (vlr_desc_tot < (20)::numeric) THEN 'R$10–20'::text
            ELSE 'Acima R$20'::text
        END
  ORDER BY (min(vlr_desc_tot));
GRANT SELECT ON kpi_ifood_descontos_faixa TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_descontos_mensal AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
    count(*) AS pedidos_total,
    count(
        CASE
            WHEN (vlr_desc_tot > (0)::numeric) THEN 1
            ELSE NULL::integer
        END) AS pedidos_com_desconto,
    round(((100.0 * (count(
        CASE
            WHEN (vlr_desc_tot > (0)::numeric) THEN 1
            ELSE NULL::integer
        END))::numeric) / (count(*))::numeric), 1) AS pct_com_desconto,
    round(sum(vlr_desc_tot), 2) AS total_descontado,
    round(((100.0 * sum(vlr_desc_tot)) / NULLIF(sum(vlr_total), (0)::numeric)), 1) AS pct_desconto_sobre_bruto,
    round(avg(
        CASE
            WHEN (vlr_desc_tot > (0)::numeric) THEN vlr_desc_tot
            ELSE NULL::numeric
        END), 2) AS desconto_medio,
    round(avg(
        CASE
            WHEN (vlr_desc_tot = (0)::numeric) THEN vlr_total
            ELSE NULL::numeric
        END), 2) AS ticket_sem_desconto,
    round(avg(
        CASE
            WHEN (vlr_desc_tot > (0)::numeric) THEN vlr_total
            ELSE NULL::numeric
        END), 2) AS ticket_com_desconto_bruto
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text))
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC;
GRANT SELECT ON kpi_ifood_descontos_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_dia_semana AS
SELECT (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'ID'::text))::integer AS dia_num,
    TRIM(BOTH FROM to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'Day'::text)) AS dia_nome,
    count(*) AS pedidos,
    round(avg(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS ticket_medio,
    round(sum(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS faturamento
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text) AND (data_hora_fecha >= (CURRENT_DATE - '90 days'::interval)))
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'ID'::text))::integer, (TRIM(BOTH FROM to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'Day'::text)))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'ID'::text))::integer;
GRANT SELECT ON kpi_ifood_dia_semana TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_hora AS
SELECT (EXTRACT(hour FROM data_hora_fecha))::integer AS hora,
    count(*) AS pedidos,
    round(avg(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS ticket_medio,
    round(sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS faturamento
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text) AND (data_hora_fecha >= (CURRENT_DATE - '90 days'::interval)))
  GROUP BY ((EXTRACT(hour FROM data_hora_fecha))::integer)
  ORDER BY ((EXTRACT(hour FROM data_hora_fecha))::integer);
GRANT SELECT ON kpi_ifood_hora TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_mensal AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
    count(*) AS pedidos,
    round(sum(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS faturamento_liquido,
    round(avg(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS ticket_medio,
    round(sum(vlr_desc_tot), 2) AS total_descontos,
    count(
        CASE
            WHEN (origem_venda ~~* '%RETIRADA%'::text) THEN 1
            ELSE NULL::integer
        END) AS pedidos_retirada,
    count(
        CASE
            WHEN (origem_venda !~~* '%RETIRADA%'::text) THEN 1
            ELSE NULL::integer
        END) AS pedidos_entrega
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text))
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC;
GRANT SELECT ON kpi_ifood_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_retirada_vs_entrega AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
    count(
        CASE
            WHEN (origem_venda ~~* '%RETIRADA%'::text) THEN 1
            ELSE NULL::integer
        END) AS pedidos_retirada,
    count(
        CASE
            WHEN (origem_venda !~~* '%RETIRADA%'::text) THEN 1
            ELSE NULL::integer
        END) AS pedidos_entrega,
    round(sum(
        CASE
            WHEN (origem_venda ~~* '%RETIRADA%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE (0)::numeric
        END), 2) AS fat_retirada,
    round(sum(
        CASE
            WHEN (origem_venda !~~* '%RETIRADA%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE (0)::numeric
        END), 2) AS fat_entrega,
    round(avg(
        CASE
            WHEN (origem_venda ~~* '%RETIRADA%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE NULL::numeric
        END), 2) AS ticket_retirada,
    round(avg(
        CASE
            WHEN (origem_venda !~~* '%RETIRADA%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE NULL::numeric
        END), 2) AS ticket_entrega
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (origem_venda ~~* '%IFOOD%'::text))
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC;
GRANT SELECT ON kpi_ifood_retirada_vs_entrega TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_ifood_vs_balcao AS
SELECT to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text) AS mes,
    round(sum(
        CASE
            WHEN (origem_venda ~~* '%IFOOD%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE (0)::numeric
        END), 2) AS fat_ifood,
    round(sum(
        CASE
            WHEN (origem_venda !~~* '%IFOOD%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE (0)::numeric
        END), 2) AS fat_balcao,
    round(sum(((vlr_total + vlr_serv) - vlr_desc_tot)), 2) AS fat_total,
    round(((100.0 * sum(
        CASE
            WHEN (origem_venda ~~* '%IFOOD%'::text) THEN ((vlr_total + vlr_serv) - vlr_desc_tot)
            ELSE (0)::numeric
        END)) / NULLIF(sum(((vlr_total + vlr_serv) - vlr_desc_tot)), (0)::numeric)), 1) AS pct_ifood
   FROM ecletica_pagamentos
  WHERE (flag_canc <> 'C'::text)
  GROUP BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text))
  ORDER BY (to_char((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo'::text), 'YYYY-MM'::text)) DESC;
GRANT SELECT ON kpi_ifood_vs_balcao TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_metas_vs_realizado AS
SELECT mes,
    tipo,
    valor_meta,
        CASE tipo
            WHEN 'faturamento'::text THEN ( SELECT COALESCE(sum(kpi_faturamento_diario.faturamento), (0)::numeric) AS "coalesce"
               FROM kpi_faturamento_diario
              WHERE (date_trunc('month'::text, (kpi_faturamento_diario.data)::timestamp with time zone) = m.mes))
            WHEN 'ticket_medio'::text THEN ( SELECT COALESCE(avg(kpi_ticket_por_canal.ticket_medio), (0)::numeric) AS "coalesce"
               FROM kpi_ticket_por_canal)
            ELSE NULL::numeric
        END AS valor_realizado
   FROM metas m;
GRANT SELECT ON kpi_metas_vs_realizado TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_pedidos_por_hora AS
SELECT (EXTRACT(hour FROM data_hora_fecha))::integer AS hora,
    count(*) AS pedidos,
    round(sum(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS faturamento_hora,
    round(avg(((vlr_total + COALESCE(vlr_serv, (0)::numeric)) - COALESCE(vlr_desc_tot, (0)::numeric))), 2) AS ticket_medio_hora
   FROM ecletica_pagamentos
  WHERE ((flag_canc <> 'C'::text) AND (data_hora_fecha >= (CURRENT_DATE - '30 days'::interval)))
  GROUP BY ((EXTRACT(hour FROM data_hora_fecha))::integer)
  ORDER BY ((EXTRACT(hour FROM data_hora_fecha))::integer);
GRANT SELECT ON kpi_pedidos_por_hora TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_rh_mensal AS
SELECT dc.periodo,
    round(sum(dc.valor), 2) AS custo_rh
   FROM (dre_caixa dc
     JOIN jafeb_despesas_mapping m ON ((dc.linha_dre = m.descricao)))
  WHERE (m.categoria_2 = 'Funcionários'::text)
  GROUP BY dc.periodo
  ORDER BY dc.periodo DESC;
GRANT SELECT ON kpi_rh_mensal TO anon, authenticated;

CREATE OR REPLACE VIEW kpi_semana_vs_meta AS
WITH meta_mes AS (
         SELECT metas.valor_meta
           FROM metas
          WHERE ((metas.tipo = 'faturamento'::text) AND (metas.mes = (date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone))::date))
        ), dias_no_mes AS (
         SELECT (EXTRACT(day FROM ((date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone) + '1 mon'::interval) - '1 day'::interval)))::integer AS total
        ), fat_semana AS (
         SELECT kpi_faturamento_diario.data,
            sum(kpi_faturamento_diario.faturamento) AS faturamento_dia
           FROM kpi_faturamento_diario
          WHERE ((kpi_faturamento_diario.data >= (date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone))::date) AND (kpi_faturamento_diario.data <= CURRENT_DATE))
          GROUP BY kpi_faturamento_diario.data
        ), fat_mes AS (
         SELECT sum(kpi_faturamento_diario.faturamento) AS realizado_mes,
            count(DISTINCT kpi_faturamento_diario.data) AS dias_corridos
           FROM kpi_faturamento_diario
          WHERE (date_trunc('month'::text, (kpi_faturamento_diario.data)::timestamp without time zone) = date_trunc('month'::text, (CURRENT_DATE)::timestamp with time zone))
        ), semana_stats AS (
         SELECT COALESCE(sum(fat_semana.faturamento_dia), (0)::numeric) AS realizado_semana,
            count(*) AS dias_corridos_semana
           FROM fat_semana
        )
 SELECT mm.valor_meta AS meta_mensal,
    round((mm.valor_meta / (dm.total)::numeric), 2) AS meta_diaria,
    round(((mm.valor_meta / (dm.total)::numeric) * (7)::numeric), 2) AS meta_semana,
    ss.realizado_semana,
    fm.realizado_mes,
    fm.dias_corridos,
    round(
        CASE
            WHEN (fm.dias_corridos > 0) THEN ((fm.realizado_mes / (fm.dias_corridos)::numeric) * (dm.total)::numeric)
            ELSE (0)::numeric
        END, 2) AS projecao_mes,
    round((mm.valor_meta - fm.realizado_mes), 2) AS falta_para_meta,
    ss.dias_corridos_semana,
    round((GREATEST((0)::numeric, (((mm.valor_meta / (dm.total)::numeric) * (7)::numeric) - ss.realizado_semana)) / (NULLIF((7 - ss.dias_corridos_semana), 0))::numeric), 2) AS meta_diaria_ajustada
   FROM meta_mes mm,
    dias_no_mes dm,
    fat_mes fm,
    semana_stats ss;
GRANT SELECT ON kpi_semana_vs_meta TO anon, authenticated;

CREATE OR REPLACE VIEW ref_custo_produto AS
SELECT DISTINCT ON (i.descr_produto) i.descr_produto AS produto,
    initcap(lower(i.descr_produto)) AS produto_label,
    i.unidade,
    i.vlr_unit AS custo_unit,
    r.data_entrada AS ultima_nf
   FROM (nf_itens i
     JOIN nf_recebimento r ON (((i.num_nf = r.num_nf) AND (i.loja = r.loja))))
  WHERE ((i.loja = 'analia_franco'::text) AND (r.data_entrada >= (CURRENT_DATE - '180 days'::interval)) AND (i.vlr_unit IS NOT NULL) AND (i.vlr_unit > (0)::numeric) AND (i.descr_produto !~~* '%SACO%'::text) AND (i.descr_produto !~~* '%EMBAL%'::text))
  ORDER BY i.descr_produto, r.data_entrada DESC;
GRANT SELECT ON ref_custo_produto TO anon, authenticated;
