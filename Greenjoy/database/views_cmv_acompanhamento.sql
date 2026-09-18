-- views_cmv_acompanhamento.sql
-- Acompanhamento de CMV e compras na cadência que a operação usa: semana e mês.
--
-- O que faltava: o dashboard tinha o CMV rolling (número oficial, imune ao calendário
-- de compra) e o desvio por categoria, mas não tinha o **orçamento de compras** —
-- quanto a loja pode comprar dado o que ela vendeu, e quanto já gastou desse
-- orçamento. Sem isso o gestor só descobre o estouro no fechamento do mês.
--
-- Régua adotada:
--   · orçamento de compras da semana = faturamento da semana × meta de CMV
--   · o desvio acumula dentro do mês — uma semana de compra grande pode ser
--     compensada pela seguinte, e é o saldo acumulado que decide o mês
--   · o semáforo da semana lê a janela de 4 semanas, não a semana crua:
--     compra é lumpy e a semana isolada oscila mais de 10 p.p. por calendário
--   · tudo é ancorado no último dia COM VENDA registrada (d_ref), nunca em
--     CURRENT_DATE — senão o dia de hoje, ainda sem sync do PDV, entra com
--     faturamento zero e infla o CMV

-- Recriar do zero: CREATE OR REPLACE não aceita renomear ou reordenar coluna,
-- e estas views ainda estão em evolução. Ordem inversa da dependência.
DROP VIEW IF EXISTS kpi_cmv_alertas;
DROP VIEW IF EXISTS kpi_cmv_historico_mensal;
DROP VIEW IF EXISTS kpi_compras_mes_acompanhamento;
DROP VIEW IF EXISTS kpi_compras_semana;
DROP VIEW IF EXISTS kpi_meta_cmv;

-- ============================================================
-- kpi_meta_cmv — meta de CMV por mês, com fallback.
-- A tabela `metas` é preenchida à mão e vive desatualizada (parou em Ago/2026).
-- Sem fallback, todo mês novo aparecia sem orçamento e a tela ficava vazia.
-- Precedência: meta do próprio mês → última meta anterior → meta do prêmio do
-- estoquista (premio_config.estoq_cmv_pct_1) → 31%.
-- ============================================================
CREATE OR REPLACE VIEW kpi_meta_cmv AS
WITH meses AS (
    SELECT DISTINCT mes FROM kpi_faturamento_mes
),
m AS (
    SELECT TO_CHAR(mes, 'YYYY-MM') AS mes, valor_meta::NUMERIC AS valor_meta
    FROM metas WHERE tipo = 'cmv_pct'
),
padrao AS (
    SELECT COALESCE(MAX(estoq_cmv_pct_1), 31)::NUMERIC AS pct FROM premio_config
)
SELECT
    ms.mes,
    COALESCE(
        (SELECT x.valor_meta FROM m x WHERE x.mes <= ms.mes ORDER BY x.mes DESC LIMIT 1),
        (SELECT pct FROM padrao)
    ) AS meta_cmv_pct,
    EXISTS (SELECT 1 FROM m x WHERE x.mes = ms.mes) AS meta_do_mes,
    CASE
        WHEN EXISTS (SELECT 1 FROM m x WHERE x.mes = ms.mes) THEN 'meta do mês'
        WHEN EXISTS (SELECT 1 FROM m x WHERE x.mes <= ms.mes) THEN 'última meta cadastrada'
        ELSE 'padrão do programa de prêmio'
    END AS origem_meta
FROM meses ms;

GRANT SELECT ON kpi_meta_cmv TO anon, authenticated;

-- ============================================================
-- kpi_compras_semana — a visão semanal que faltava.
-- Uma linha por semana ISO (segunda a domingo), 14 meses.
-- O mês da semana é o mês da SEGUNDA-FEIRA: semana que cruza a virada conta
-- inteira no mês em que começou, para o acumulado de orçamento não contar duas vezes.
-- ============================================================
CREATE OR REPLACE VIEW kpi_compras_semana AS
WITH venda_dia AS (
    SELECT (data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
           SUM(vlr_total + COALESCE(vlr_serv, 0) - COALESCE(vlr_desc_tot, 0)) AS faturamento,
           COUNT(*) AS pedidos
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '16 months'
    GROUP BY 1
),
ref AS (SELECT MAX(dia) AS d_ref FROM venda_dia),
compra_dia AS (
    SELECT data_movimentacao::DATE AS dia, SUM(valor) AS compras
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '16 months'
      AND data_movimentacao <= (SELECT d_ref FROM ref)
    GROUP BY 1
),
cal AS (
    SELECT generate_series(
             DATE_TRUNC('week', (hoje_br() - INTERVAL '14 months')::timestamp)::DATE,
             (SELECT d_ref FROM ref), '1 day')::DATE AS dia
),
base AS (
    SELECT c.dia,
           DATE_TRUNC('week', c.dia::timestamp)::DATE AS semana,
           TO_CHAR(c.dia, 'YYYY-MM')  AS mes_dia,
           COALESCE(v.faturamento, 0) AS faturamento,
           COALESCE(v.pedidos, 0)     AS pedidos,
           COALESCE(p.compras, 0)     AS compras
    FROM cal c
    LEFT JOIN venda_dia  v ON v.dia = c.dia
    LEFT JOIN compra_dia p ON p.dia = c.dia
),
-- Acumulado do mês apurado NO DIA, não somando semanas.
-- Somar semanas erra por até R$72k: a semana que cruza a virada conta inteira no
-- mês da segunda-feira, então 1 a 6 de setembro caíam dentro de agosto. A aba
-- semanal dizia 'acima do orçamento' e a mensal 'abaixo' para o mesmo mês.
acum_dia AS (
    SELECT
        b.dia,
        b.mes_dia,
        SUM(b.compras) OVER (PARTITION BY b.mes_dia ORDER BY b.dia) AS compras_mtd,
        SUM(b.faturamento * mt.meta_cmv_pct / 100.0)
            OVER (PARTITION BY b.mes_dia ORDER BY b.dia)            AS orcamento_mtd
    FROM base b
    LEFT JOIN kpi_meta_cmv mt ON mt.mes = b.mes_dia
),
sem AS (
    SELECT semana,
           MAX(dia)                                      AS ultimo_dia,
           SUM(faturamento)                              AS faturamento,
           SUM(pedidos)                                  AS pedidos,
           SUM(compras)                                  AS compras,
           COUNT(*) FILTER (WHERE faturamento > 0)       AS dias_com_venda,
           COUNT(*)                                      AS dias_na_serie
    FROM base
    GROUP BY 1
),
movel AS (
    SELECT s.*,
           SUM(compras)     OVER w4 AS compras_4s,
           SUM(faturamento) OVER w4 AS faturamento_4s,
           AVG(compras)     OVER w8 AS media_8s_compras,
           COUNT(*)         OVER w8 AS semanas_base
    FROM sem s
    WINDOW w4 AS (ORDER BY semana ROWS BETWEEN 3 PRECEDING AND CURRENT ROW),
           w8 AS (ORDER BY semana ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING)
),
calc AS (
    SELECT
        m.semana,
        (m.semana + 6)                                        AS semana_fim,
        TO_CHAR(m.semana, 'DD/MM') || ' a ' || TO_CHAR(m.semana + 6, 'DD/MM') AS rotulo,
        TO_CHAR(m.semana, 'YYYY-MM')                          AS mes,
        (m.semana >= DATE_TRUNC('week', (SELECT d_ref FROM ref)::timestamp)::DATE) AS parcial,
        m.ultimo_dia,
        m.dias_com_venda,
        m.dias_na_serie,
        ROUND(m.faturamento, 2)                               AS faturamento,
        m.pedidos,
        ROUND(m.compras, 2)                                   AS compras,
        ROUND(100.0 * m.compras / NULLIF(m.faturamento, 0), 1) AS cmv_semana_pct,
        ROUND(100.0 * m.compras_4s / NULLIF(m.faturamento_4s, 0), 1) AS cmv_4s_pct,
        ROUND(m.media_8s_compras, 2)                          AS media_8s_compras,
        m.semanas_base,
        mt.meta_cmv_pct,
        ROUND(m.faturamento * mt.meta_cmv_pct / 100.0, 2)     AS orcamento_compras,
        ROUND(m.compras - m.faturamento * mt.meta_cmv_pct / 100.0, 2) AS desvio_orcamento,
        r.cmv_30d_pct,
        ad.mes_dia                                            AS mes_acum,
        ad.dia                                                AS acum_ate,
        ROUND(ad.compras_mtd, 2)                              AS compras_mes_ate_semana,
        ROUND(ad.orcamento_mtd, 2)                            AS orcamento_mes_ate_semana,
        ROUND(ad.compras_mtd - ad.orcamento_mtd, 2)           AS desvio_acum_mes
    FROM movel m
    LEFT JOIN kpi_meta_cmv    mt ON mt.mes = TO_CHAR(m.semana, 'YYYY-MM')
    LEFT JOIN kpi_cmv_rolling r  ON r.dia  = m.ultimo_dia
    LEFT JOIN acum_dia        ad ON ad.dia = m.ultimo_dia
)
SELECT
    c.*,
    CASE
        WHEN c.parcial                                   THEN 'parcial'
        WHEN c.cmv_4s_pct IS NULL                        THEN 'sem_base'
        WHEN c.cmv_4s_pct <= c.meta_cmv_pct              THEN 'otimo'
        WHEN c.cmv_4s_pct <= c.meta_cmv_pct + 3          THEN 'bom'
        ELSE 'critico'
    END AS situacao
FROM calc c
ORDER BY c.semana DESC;

GRANT SELECT ON kpi_compras_semana TO anon, authenticated;

-- ============================================================
-- kpi_compras_mes_acompanhamento — o mês em curso com projeção ponderada.
--
-- Duas projeções, com réguas diferentes de propósito.
--
-- VENDA: run-rate por dia DECORRIDO aberto. Já foram testadas duas alternativas e
-- as duas são piores. Ponderar por dia da semana (premio_peso_dia_semana) não ganha
-- nada — erro médio no dia 17 de 4,36% contra 4,20% — e a tabela de pesos está
-- desatualizada (segunda mede 0,73 e a tabela diz 0,50). Dividir por dia COM VENDA
-- é pior ainda (4,91%): dia zerado por falha de sync sai do denominador, a média
-- diária sobe e a projeção infla — em mai/2026 projetava R$621k contra R$535k
-- realizados. Dia sem venda tem que doer na projeção; se a loja fechou de verdade,
-- o lugar de dizer isso é `loja_dias_fechados`.
--
-- COMPRA: não é run-rate. Se compra e venda fossem projetadas pela mesma razão, o
-- CMV projetado sairia idêntico ao realizado e o card não diria nada. Aqui a venda
-- que falta é comprada ao CMV da janela móvel de 30 dias (`kpi_cmv_rolling`), que é
-- o número oficial da casa. O que já foi comprado é fato e entra inteiro.
--
-- O rolling entra com BANDA de 20% a 50%. Em 16% dos dias da série ele está fora
-- dela — é a cauda de 30 dias do buraco do extrato em ago e set/2025, onde chegou a
-- 0%. Sem a banda, uma parada do sync do BTG derrubaria o CMV projetado e acenderia
-- o semáforo como `otimo` justamente quando o dado quebrou. Fora da banda vale a
-- meta. Em 17/10/2025 isso reduz o erro da projeção de 6,3 p.p. para 0,7 p.p.
--
-- Nenhuma das duas é o número de decisão. O de decisão é `saldo_orcamento`: quanto
-- ainda cabe comprar até o fim do mês.
-- ============================================================
CREATE OR REPLACE VIEW kpi_compras_mes_acompanhamento AS
WITH venda_dia AS (
    SELECT (data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS dia,
           SUM(vlr_total + COALESCE(vlr_serv, 0) - COALESCE(vlr_desc_tot, 0)) AS faturamento,
           COUNT(*) AS pedidos
    FROM ecletica_pagamentos
    WHERE flag_canc <> 'C'
      AND data_hora_fecha >= hoje_br() - INTERVAL '26 months'
    GROUP BY 1
),
ref AS (SELECT MAX(dia) AS d_ref FROM venda_dia),
compra_dia AS (
    SELECT data_movimentacao::DATE AS dia, SUM(valor) AS compras
    FROM btg_classificado
    WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
      AND data_movimentacao >= hoje_br() - INTERVAL '26 months'
      AND data_movimentacao <= (SELECT d_ref FROM ref)
    GROUP BY 1
),
meses AS (
    SELECT DISTINCT DATE_TRUNC('month', dia)::DATE AS m1 FROM venda_dia
),
-- todos os dias de cada mês, marcando quais já passaram e quais a loja abre
dias AS (
    SELECT
        ms.m1,
        d::DATE AS dia,
        (d::DATE <= (SELECT d_ref FROM ref))                    AS passou,
        NOT EXISTS (SELECT 1 FROM loja_dias_fechados f WHERE f.data = d::DATE) AS abre
    FROM meses ms
    CROSS JOIN LATERAL generate_series(
        ms.m1, (ms.m1 + INTERVAL '1 month - 1 day')::DATE, '1 day') d
),
agg AS (
    SELECT
        d.m1,
        COUNT(*)                                           AS dias_no_mes,
        COUNT(*) FILTER (WHERE d.abre)                     AS dias_operaveis,
        COUNT(*) FILTER (WHERE d.abre AND NOT d.passou)    AS dias_restantes,
        -- só dia aberto: em dezembro, contar 31 decorridos contra 28 operáveis
        -- fazia a projeção de compra sair ABAIXO do já realizado
        COUNT(*) FILTER (WHERE d.passou AND d.abre)        AS dias_decorridos
    FROM dias d
    GROUP BY 1
),
real AS (
    SELECT
        ms.m1,
        COALESCE(SUM(v.faturamento), 0)                        AS faturamento,
        COALESCE(SUM(v.pedidos), 0)                            AS pedidos,
        COUNT(v.dia) FILTER (WHERE v.faturamento > 0)          AS dias_com_venda
    FROM meses ms
    LEFT JOIN venda_dia v ON DATE_TRUNC('month', v.dia)::DATE = ms.m1
    GROUP BY 1
),
compras AS (
    SELECT ms.m1, COALESCE(SUM(p.compras), 0) AS compras
    FROM meses ms
    LEFT JOIN compra_dia p ON DATE_TRUNC('month', p.dia)::DATE = ms.m1
    GROUP BY 1
),
-- densidade do extrato: o BTG tem buraco de 09/08/2025 a 30/09/2025, e mês com
-- pouco débito lançado produz CMV de 1% — pior que não ter número. Mesma régua
-- de kpi_dre_btg_mensal.
debitos AS (
    SELECT DATE_TRUNC('month', data_movimentacao)::DATE AS m1, COUNT(*) AS n_debitos
    FROM btg_classificado
    WHERE tipo ILIKE 'D%'
    GROUP BY 1
),
-- CMV da janela de 30 dias no dia de referência, limpo de valor implausível
rolling_ref AS (
    SELECT CASE WHEN cmv_30d_pct BETWEEN 20 AND 50 THEN cmv_30d_pct END AS cmv_30d_pct
    FROM kpi_cmv_rolling
    WHERE dia = (SELECT d_ref FROM ref)
),
calc AS (
    SELECT
        TO_CHAR(a.m1, 'YYYY-MM')                                       AS mes,
        a.m1                                                           AS mes_inicio,
        (a.m1 + INTERVAL '1 month - 1 day')::DATE                      AS mes_fim,
        (a.m1 = DATE_TRUNC('month', (SELECT d_ref FROM ref))::DATE)    AS em_curso,
        (SELECT d_ref FROM ref)                                        AS dado_ate,
        a.dias_no_mes, a.dias_operaveis, a.dias_restantes, a.dias_decorridos,
        r.dias_com_venda,
        ROUND(r.faturamento, 2)                                        AS faturamento_mtd,
        r.pedidos                                                      AS pedidos_mtd,
        ROUND(c.compras, 2)                                            AS compras_mtd,
        ROUND(100.0 * c.compras / NULLIF(r.faturamento, 0), 1)         AS cmv_mtd_pct,
        mt.meta_cmv_pct,
        mt.origem_meta,
        (SELECT valor_meta::NUMERIC FROM metas g
          WHERE g.tipo = 'faturamento' AND g.mes = a.m1)               AS meta_faturamento,
        ROUND(r.faturamento * a.dias_operaveis::NUMERIC
              / NULLIF(a.dias_decorridos, 0), 2)                       AS faturamento_proj,
        ROUND(c.compras
              + GREATEST(r.faturamento * a.dias_operaveis::NUMERIC
                         / NULLIF(a.dias_decorridos, 0) - r.faturamento, 0)
                * COALESCE(rol.cmv_30d_pct, mt.meta_cmv_pct) / 100.0, 2)
                                                                       AS compras_proj,
        -- só no mês em curso: é o rolling de HOJE, e num mês fechado ele não tem
        -- nada a ver com a linha
        CASE WHEN a.m1 = DATE_TRUNC('month', (SELECT d_ref FROM ref))::DATE
             THEN COALESCE(rol.cmv_30d_pct, mt.meta_cmv_pct) END       AS cmv_rolling_30d,
        -- Mês comparável = as DUAS bases inteiras.
        --  · piso em mai/2025: jan e fev/2025 têm R$19k de faturamento contra
        --    R$200k de compra, e mar e abr dão 57,5% e 41,4% — o PDV Eclética
        --    ainda estava entrando no ar. Mai, jun e jul/2025 passam em tudo (259
        --    a 294 débitos, mês cheio de venda, CMV de 32% a 34%) e ficam: é
        --    deles que sai a comparação contra o ano anterior. O buraco de 09/08
        --    a 30/09/2025 no extrato cai sozinho pela densidade de débito (93 e
        --    14 lançamentos).
        --  · densidade de débito no extrato;
        --  · venda em quase todo dia aberto. A tolerância é de 4 dias porque
        --    loja_dias_fechados não tem os feriados de 2025 cadastrados, e sem
        --    isso dez/2025 caía fora por causa de Natal e Ano Novo.
        (a.m1 = DATE_TRUNC('month', (SELECT d_ref FROM ref))::DATE
         OR (a.m1 >= DATE '2025-05-01'
             AND COALESCE(d.n_debitos, 0) >= 200
             AND r.faturamento > 100000
             AND r.dias_com_venda >= a.dias_operaveis - 4))            AS confiavel
    FROM agg a
    JOIN real    r ON r.m1 = a.m1
    JOIN compras c ON c.m1 = a.m1
    LEFT JOIN debitos d ON d.m1 = a.m1
    LEFT JOIN kpi_meta_cmv mt ON mt.mes = TO_CHAR(a.m1, 'YYYY-MM')
    CROSS JOIN rolling_ref rol
),
fechado AS (
    SELECT
        c.*,
        -- no mês fechado a projeção é o próprio realizado
        CASE WHEN c.em_curso THEN c.faturamento_proj ELSE c.faturamento_mtd END AS fat_ref,
        CASE WHEN c.em_curso THEN c.compras_proj     ELSE c.compras_mtd     END AS compras_ref
    FROM calc c
)
SELECT
    f.mes, f.mes_inicio, f.mes_fim, f.em_curso, f.confiavel, f.dado_ate,
    f.cmv_rolling_30d,
    f.dias_no_mes, f.dias_operaveis, f.dias_restantes, f.dias_decorridos, f.dias_com_venda,
    f.faturamento_mtd, f.pedidos_mtd, f.compras_mtd, f.cmv_mtd_pct,
    f.meta_cmv_pct, f.origem_meta, f.meta_faturamento,
    ROUND(f.fat_ref, 2)                                              AS faturamento_projetado,
    ROUND(f.compras_ref, 2)                                          AS compras_projetadas,
    ROUND(100.0 * f.compras_ref / NULLIF(f.fat_ref, 0), 1)           AS cmv_projetado_pct,
    -- orçamento de compras do mês: sobre a venda projetada (realista) e sobre a
    -- meta de faturamento (ambicioso). Mostrar os dois evita a armadilha de
    -- liberar compra com base numa meta de venda que não vai acontecer.
    ROUND(f.fat_ref * f.meta_cmv_pct / 100.0, 2)                     AS orcamento_mes,
    ROUND(f.meta_faturamento * f.meta_cmv_pct / 100.0, 2)            AS orcamento_sobre_meta,
    ROUND(f.fat_ref * f.meta_cmv_pct / 100.0 - f.compras_mtd, 2)     AS saldo_orcamento,
    ROUND((f.fat_ref * f.meta_cmv_pct / 100.0 - f.compras_mtd)
          / NULLIF(f.dias_restantes, 0), 2)                          AS ritmo_diario_permitido,
    ROUND(f.compras_mtd / NULLIF(f.dias_decorridos, 0), 2)           AS ritmo_diario_atual,
    CASE
        WHEN f.faturamento_mtd = 0 THEN 'sem_base'
        WHEN 100.0 * f.compras_ref / NULLIF(f.fat_ref, 0) <= f.meta_cmv_pct       THEN 'otimo'
        WHEN 100.0 * f.compras_ref / NULLIF(f.fat_ref, 0) <= f.meta_cmv_pct + 3   THEN 'bom'
        ELSE 'critico'
    END AS semaforo
FROM fechado f
ORDER BY f.mes DESC;

GRANT SELECT ON kpi_compras_mes_acompanhamento TO anon, authenticated;

-- ============================================================
-- kpi_cmv_historico_mensal — a série longa para olhar tendência, não o mês.
-- Traz média móvel de 3 e 12 meses e a comparação com o mesmo mês do ano anterior,
-- que é o único jeito de separar sazonalidade de deterioração real.
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_historico_mensal AS
WITH b AS (
    SELECT mes, mes_inicio, em_curso, confiavel, faturamento_mtd AS faturamento,
           compras_mtd AS compras, cmv_mtd_pct AS cmv_pct, meta_cmv_pct
    FROM kpi_compras_mes_acompanhamento
),
-- médias móveis só sobre mês confiável, e só com a janela cheia e contígua:
-- um ago/2025 com 8% de CMV contamina a média por meio ano. 6 meses em vez de
-- 12 porque a série confiável só começa em out/2025 — uma janela de 12 meses
-- ficaria vazia em quase todo mês
bc AS (SELECT * FROM b WHERE confiavel),
movel AS (
    SELECT mes_inicio,
           SUM(compras)     OVER w3  AS compras_3m,
           SUM(faturamento) OVER w3  AS faturamento_3m,
           MIN(mes_inicio)  OVER w3  AS ini_3m,
           COUNT(*)         OVER w3  AS n_3m,
           SUM(compras)     OVER w6 AS compras_6m,
           SUM(faturamento) OVER w6 AS faturamento_6m,
           MIN(mes_inicio)  OVER w6 AS ini_6m,
           COUNT(*)         OVER w6 AS n_6m
    FROM bc
    WINDOW w3  AS (ORDER BY mes_inicio ROWS BETWEEN 2 PRECEDING  AND CURRENT ROW),
           w6 AS (ORDER BY mes_inicio ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
)
SELECT
    b.mes,
    b.mes_inicio,
    b.em_curso                                                     AS parcial,
    b.confiavel,
    b.faturamento,
    b.compras,
    b.cmv_pct,
    b.meta_cmv_pct,
    ROUND(b.cmv_pct - b.meta_cmv_pct, 1)                           AS desvio_meta_pp,
    CASE WHEN mv.n_3m = 3 AND mv.ini_3m = (b.mes_inicio - INTERVAL '2 months')::DATE
         THEN ROUND(100.0 * mv.compras_3m / NULLIF(mv.faturamento_3m, 0), 1) END
                                                                   AS cmv_3m_pct,
    CASE WHEN mv.n_6m = 6 AND mv.ini_6m = (b.mes_inicio - INTERVAL '5 months')::DATE
         THEN ROUND(100.0 * mv.compras_6m / NULLIF(mv.faturamento_6m, 0), 1) END
                                                                   AS cmv_6m_pct,
    a.cmv_pct                                                      AS cmv_ano_anterior_pct,
    CASE WHEN a.confiavel THEN ROUND(b.cmv_pct - a.cmv_pct, 1) END AS var_yoy_pp,
    ROUND(b.compras - b.faturamento * b.meta_cmv_pct / 100.0, 2)   AS excesso_compra_reais
FROM b
LEFT JOIN movel mv ON mv.mes_inicio = b.mes_inicio
LEFT JOIN bc    a  ON a.mes_inicio = (b.mes_inicio - INTERVAL '1 year')::DATE
ORDER BY b.mes_inicio DESC;

GRANT SELECT ON kpi_cmv_historico_mensal TO anon, authenticated;

-- ============================================================
-- kpi_cmv_alertas — o feed de "dá para confiar neste número?".
--
-- Cada linha é um problema com nome, evidência e ação. O painel de CMV mente de
-- três jeitos conhecidos: fornecedor novo sem classificação (CMV subestimado),
-- buraco de sync no PDV (denominador menor, CMV inflado) e semana sem lançamento
-- no extrato (CMV artificialmente baixo, e o estouro aparece na semana seguinte).
-- Everest e DRE JAFEB estão fora de propósito — foram aposentados em Ago/2026 e
-- só gerariam ruído permanente.
-- ============================================================
CREATE OR REPLACE VIEW kpi_cmv_alertas AS
WITH ref AS (
    SELECT MAX((data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE) AS d_ref
    FROM ecletica_pagamentos WHERE flag_canc <> 'C'
),
-- 1. cobertura do de-para no mês corrente
cobertura AS (
    SELECT
        CASE WHEN pct_nao_classificado > 5 THEN 'critico'
             WHEN pct_nao_classificado > 2 THEN 'atencao'
             ELSE 'ok' END                                    AS severidade,
        'Classificação'                                       AS area,
        'Débitos sem natureza em ' || mes                     AS titulo,
        ROUND(pct_nao_classificado, 1) || '% do que saiu da conta em ' || mes
        || ' ainda não tem natureza (' || chaves_pendentes || ' chaves, R$ '
        || brl(nao_classificado) || ').'                      AS detalhe,
        CASE WHEN pct_nao_classificado > 2
             THEN 'Classificar as chaves de kpi_mapping_pendentes. Parte vira CMV e parte '
                  || 'vira Folha — até resolver os dois estão subestimados.'
             ELSE 'Nada a fazer — cobertura dentro do aceitável.' END AS acao,
        ROUND(pct_nao_classificado, 1)                        AS valor,
        1                                                     AS ordem
    FROM kpi_cobertura_mapping
    ORDER BY mes DESC
    LIMIT 1
),
-- 2. fornecedores novos de valor relevante ainda sem classificação
pendentes AS (
    SELECT
        -- Severidade pelo que entrou nos últimos 60 dias: a fila carrega resíduo
        -- de 12 meses e nunca sairia de crítico se olhasse o total.
        -- O recente sai do extrato filtrado por DATA. Filtrar a fila por
        -- `ultima_ocorrencia` trazia o total de 12 meses das chaves com movimento
        -- recente — 12% a mais.
        CASE WHEN rec.valor > 5000 THEN 'critico'
             WHEN rec.valor > 1000 THEN 'atencao'
             ELSE 'ok' END                                    AS severidade,
        'Classificação'                                       AS area,
        'Fila de classificação'                               AS titulo,
        f.chaves || ' chaves pendentes somando R$ ' || brl(f.total) || ', sendo R$ '
        || brl(rec.valor) || ' lançados nos últimos 60 dias. Maior: ' || f.maior
                                                              AS detalhe,
        'Classificar por valor. Boa parte é pessoa física e vale-refeição, que vira '
        || 'Folha e não CMV — só a parcela de fornecedor sobe o CMV quando entrar.' AS acao,
        ROUND(f.total, 2)                                     AS valor,
        2                                                     AS ordem
    FROM (
        SELECT COUNT(*) AS chaves, SUM(total) AS total,
               (SELECT chave FROM kpi_mapping_pendentes
                 ORDER BY total DESC NULLS LAST LIMIT 1) AS maior
        FROM kpi_mapping_pendentes
    ) f
    CROSS JOIN (
        SELECT COALESCE(SUM(valor), 0) AS valor
        FROM btg_classificado
        WHERE tipo ILIKE 'D%' AND natureza = 'Não classificado'
          AND data_movimentacao >= hoje_br() - 60
    ) rec
    WHERE f.chaves > 0
),
-- 3. frescor das duas bases que sustentam o CMV
frescor AS (
    SELECT
        CASE WHEN dias > 3 THEN 'critico' WHEN dias > 1 THEN 'atencao' ELSE 'ok' END,
        'Base',
        base_nome,
        'Último dado em ' || TO_CHAR(ultimo, 'DD/MM/YYYY') || ' — ' || dias || ' dia(s) atrás.',
        CASE WHEN dias > 1
             THEN 'Conferir o sync (' || rotina || ') antes de usar o número.'
             ELSE 'Atualizada.' END,
        dias::NUMERIC,
        3
    FROM (
        SELECT 'Vendas (PDV Eclética)' AS base_nome,
               'Task GreenjoySync, 00:30 BRT' AS rotina,
               (SELECT d_ref FROM ref) AS ultimo,
               (hoje_br() - (SELECT d_ref FROM ref)) AS dias
        UNION ALL
        SELECT 'Extrato BTG (compras)',
               'Apps Script, 06:00 BRT',
               MAX(data_movimentacao)::DATE,
               (hoje_br() - MAX(data_movimentacao)::DATE)
        FROM btg_classificado
    ) x
),
-- 4. buracos de venda nos últimos 45 dias distorcem o denominador do CMV
buracos AS (
    SELECT
        CASE WHEN COUNT(*) FILTER (WHERE situacao = 'sem_venda') > 0 THEN 'critico'
             WHEN COUNT(*) > 0 THEN 'atencao' ELSE 'ok' END,
        'Vendas',
        'Dias suspeitos nos últimos 45 dias',
        CASE WHEN COUNT(*) = 0 THEN 'Nenhum dia sem venda ou muito abaixo do padrão.'
             ELSE COUNT(*) || ' dia(s) fora do padrão — o mais recente em '
                  || TO_CHAR(MAX(dia), 'DD/MM') || '.' END,
        CASE WHEN COUNT(*) = 0 THEN 'Nada a fazer.'
             ELSE 'Dia sem venda derruba o denominador e infla o CMV. Confirmar se a loja fechou (loja_dias_fechados) ou se o sync falhou.' END,
        COUNT(*)::NUMERIC,
        4
    FROM kpi_dias_suspeitos
    WHERE dia >= hoje_br() - 45
),
-- 5. semana com venda e sem nenhuma compra lançada: lançamento atrasado no extrato
sem_compra AS (
    SELECT
        CASE WHEN COUNT(*) > 0 THEN 'atencao' ELSE 'ok' END,
        'Compras',
        'Semanas sem compra lançada',
        CASE WHEN COUNT(*) = 0 THEN 'Todas as semanas fechadas dos últimos 3 meses têm compra registrada.'
             ELSE COUNT(*) || ' semana(s) fechada(s) com venda e R$ 0 de compra: '
                  || STRING_AGG(rotulo, ', ' ORDER BY semana DESC) END,
        CASE WHEN COUNT(*) = 0 THEN 'Nada a fazer.'
             ELSE 'Compra lançada com atraso joga o custo para a semana seguinte. Comparar sempre pela janela de 4 semanas, não pela semana crua.' END,
        COUNT(*)::NUMERIC,
        5
    FROM kpi_compras_semana
    WHERE NOT parcial
      AND semana >= hoje_br() - INTERVAL '3 months'
      AND faturamento > 0
      AND compras = 0
),
-- 6. o número em si: CMV rolling fora da meta
nivel AS (
    SELECT
        CASE WHEN r.cmv_30d_pct > m.meta_cmv_pct + 3 THEN 'critico'
             WHEN r.cmv_30d_pct > m.meta_cmv_pct     THEN 'atencao'
             ELSE 'ok' END,
        'CMV',
        'CMV 30 dias móveis',
        'Está em ' || ROUND(r.cmv_30d_pct, 1) || '% contra meta de '
        || ROUND(m.meta_cmv_pct, 1) || '% (90 dias: ' || ROUND(r.cmv_90d_pct, 1) || '%).',
        CASE WHEN r.cmv_30d_pct > m.meta_cmv_pct
             THEN 'Ver o card de ações da semana: qual categoria e qual fornecedor puxaram.'
             ELSE 'Dentro da meta.' END,
        ROUND(r.cmv_30d_pct, 1),
        6
    FROM (SELECT * FROM kpi_cmv_rolling ORDER BY dia DESC LIMIT 1) r
    CROSS JOIN (SELECT meta_cmv_pct FROM kpi_meta_cmv
                 ORDER BY mes DESC LIMIT 1) m
),
-- 7. royalty dentro do CMV: o de-para jogou a franqueadora em Custo até Ago/2026
royalty AS (
    SELECT
        CASE WHEN SUM(valor) > 5000 THEN 'critico'
             WHEN COUNT(*) > 0       THEN 'atencao'
             ELSE 'ok' END,
        'Classificação',
        'Royalty classificado como custo',
        CASE WHEN COUNT(*) = 0 THEN 'Nenhum pagamento à franqueadora dentro do CMV nos últimos 6 meses.'
             ELSE COUNT(*) || ' lançamento(s) da franqueadora somando R$ ' || brl(SUM(valor))
                  || ' caíram em natureza Custo.' END,
        CASE WHEN COUNT(*) = 0 THEN 'Nada a fazer.'
             ELSE 'Royalty + fundo de propaganda são 6,5% do faturamento e não são CMV. Corrigir a regra em btg_classificado.sql.' END,
        COALESCE(ROUND(SUM(valor), 2), 0),
        7
    FROM btg_classificado
    WHERE natureza = 'Custo'
      -- sem este filtro o alerta pegava CRÉDITO da franqueadora (estorno), que
      -- nenhuma view de CMV lê, e mandava corrigir uma regra que está certa
      AND tipo ILIKE 'D%'
      AND chave ILIKE '%FRANQUEADORA%'
      AND data_movimentacao >= hoje_br() - INTERVAL '6 months'
),
tudo AS (
    SELECT severidade, area, titulo, detalhe, acao, valor, ordem FROM cobertura
    UNION ALL SELECT * FROM pendentes
    UNION ALL SELECT * FROM frescor
    UNION ALL SELECT * FROM buracos
    UNION ALL SELECT * FROM sem_compra
    UNION ALL SELECT * FROM nivel
    UNION ALL SELECT * FROM royalty
)
SELECT
    severidade, area, titulo, detalhe, acao, valor, ordem,
    CASE severidade WHEN 'critico' THEN 0 WHEN 'atencao' THEN 1 ELSE 2 END AS peso
FROM tudo
ORDER BY peso, ordem;

GRANT SELECT ON kpi_cmv_alertas TO anon, authenticated;
