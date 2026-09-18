-- views_premio.sql — Programa de premiação a partir do Q4/2026.
-- Regras: BONUS/Regras_Premiacao_Q4_2026.md. Convive com o modelo antigo (kpi_bonus_*)
-- até a virada de 01/10/2026.
--
-- Métrica = pedidos vendidos no dia (abertura do pedido no PDV, sem cancelados). A Eclética
-- grava hora de parede como UTC — AT TIME ZONE 'UTC' devolve a hora da loja (ver
-- views_fechamento.sql). Pela data de fechamento o dia oscila: pedido fechado em lote no dia
-- seguinte some de um dia e infla o outro. A meta do mês é congelada; a distribuição
-- diária usa pesos fixos por dia da semana, então a meta de cada dia também não muda.

CREATE TABLE IF NOT EXISTS premio_config (
    id                    INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    pct_quase_la          NUMERIC NOT NULL DEFAULT 0.95,
    pct_super_green       NUMERIC NOT NULL DEFAULT 1.05,
    pct_mega_green        NUMERIC NOT NULL DEFAULT 1.10,
    pct_ultra_green       NUMERIC NOT NULL DEFAULT 1.15,
    fator_quase_la        NUMERIC NOT NULL DEFAULT 0.80,
    valor_meta            NUMERIC NOT NULL DEFAULT 150,
    valor_super_green     NUMERIC NOT NULL DEFAULT 230,
    peso_operacao         NUMERIC NOT NULL DEFAULT 1.0,
    peso_treinador        NUMERIC NOT NULL DEFAULT 1.1,
    peso_estoquista       NUMERIC NOT NULL DEFAULT 1.1,
    peso_lider            NUMERIC NOT NULL DEFAULT 1.2,
    peso_chefe            NUMERIC NOT NULL DEFAULT 1.5,
    bonus_por_selo        NUMERIC NOT NULL DEFAULT 0.10,
    qualinut_min_pct      NUMERIC NOT NULL DEFAULT 65,
    google_min_avaliacoes INT     NOT NULL DEFAULT 30,
    google_min_media      NUMERIC NOT NULL DEFAULT 4.7,
    atualizado_em         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO premio_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Faixa de um volume de pedidos contra a meta do mês
CREATE OR REPLACE FUNCTION premio_faixa(p_pedidos NUMERIC, p_meta NUMERIC) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_pedidos IS NULL OR p_meta IS NULL          THEN NULL
                WHEN p_pedidos >= p_meta * c.pct_ultra_green      THEN 'Ultra Green'
                WHEN p_pedidos >= p_meta * c.pct_mega_green       THEN 'Mega Green'
                WHEN p_pedidos >= p_meta * c.pct_super_green      THEN 'Super Green'
                WHEN p_pedidos >= p_meta                          THEN 'Meta'
                WHEN p_pedidos >= p_meta * c.pct_quase_la         THEN 'Quase lá'
                ELSE 'Sem prêmio' END
    FROM premio_config c WHERE c.id = 1
$$;

-- Setembro é piloto (lançamento pago na Meta): Set/25 × 1,0504, o mesmo crescimento do Q4.
CREATE TABLE IF NOT EXISTS premio_metas_mensais (
    mes           DATE PRIMARY KEY CHECK (EXTRACT(DAY FROM mes) = 1),
    pedidos_meta  INT  NOT NULL,
    congelado_em  DATE NOT NULL DEFAULT hoje_br(),
    observacao    TEXT
);
INSERT INTO premio_metas_mensais (mes, pedidos_meta, congelado_em, observacao) VALUES
    ('2026-09-01', 7070, '2026-09-14', 'Piloto — lançamento pago na Meta'),
    ('2026-10-01', 7880, '2026-09-14', 'Q4: R$ 2,0M = 23.500 pedidos'),
    ('2026-11-01', 8340, '2026-09-14', 'Q4: R$ 2,0M = 23.500 pedidos'),
    ('2026-12-01', 7280, '2026-09-14', 'Q4: R$ 2,0M = 23.500 pedidos; 28 dias abertos')
ON CONFLICT (mes) DO NOTHING;

-- Pedidos médios por dia da semana ÷ média geral, 29/06 a 13/09/2026.
CREATE TABLE IF NOT EXISTS premio_peso_dia_semana (
    isodow INT PRIMARY KEY CHECK (isodow BETWEEN 1 AND 7),
    peso   NUMERIC NOT NULL
);
INSERT INTO premio_peso_dia_semana (isodow, peso) VALUES
    (1, 0.504), (2, 0.983), (3, 1.088), (4, 1.009), (5, 1.077), (6, 1.296), (7, 1.050)
ON CONFLICT (isodow) DO NOTHING;

-- Repete os fechamentos de dez/2025; confirmar a escala de fim de ano.
CREATE TABLE IF NOT EXISTS loja_dias_fechados (
    data   DATE PRIMARY KEY,
    motivo TEXT
);
INSERT INTO loja_dias_fechados (data, motivo) VALUES
    ('2026-12-25', 'Natal'),
    ('2026-12-30', 'Fim de ano'),
    ('2026-12-31', 'Fim de ano')
ON CONFLICT (data) DO NOTHING;

-- iFood e Google são apurados à mão até a automação; NULL = em apuração.
CREATE TABLE IF NOT EXISTS premio_selos_mensais (
    mes               DATE PRIMARY KEY CHECK (EXTRACT(DAY FROM mes) = 1),
    ifood_super       BOOLEAN,
    google_avaliacoes INT,
    google_media      NUMERIC,
    observacao        TEXT,
    atualizado_em     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- Um dia por linha, para todo mês com meta cadastrada
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW kpi_premio_diario AS
WITH pedidos AS (
    SELECT (data_hora_abre AT TIME ZONE 'UTC')::DATE AS dia,
           COUNT(*) AS pedidos
    FROM ecletica_pagamentos
    WHERE COALESCE(flag_canc, '') <> 'C'
      AND data_hora_abre >= (SELECT MIN(mes) FROM premio_metas_mensais) - INTERVAL '1 day'
    GROUP BY 1
), base AS (
    SELECT m.mes,
           g.dia::DATE                                        AS dia,
           m.pedidos_meta,
           f.data IS NULL                                     AS aberto,
           CASE WHEN f.data IS NULL THEN w.peso ELSE 0 END    AS peso
    FROM premio_metas_mensais m
    CROSS JOIN LATERAL generate_series(m.mes, m.mes + INTERVAL '1 month' - INTERVAL '1 day',
                                       INTERVAL '1 day') AS g(dia)
    JOIN premio_peso_dia_semana w ON w.isodow = EXTRACT(ISODOW FROM g.dia)
    LEFT JOIN loja_dias_fechados f ON f.data = g.dia::DATE
)
SELECT b.mes,
       b.dia,
       DATE_TRUNC('week', b.dia)::DATE                               AS semana_inicio,
       EXTRACT(ISODOW FROM b.dia)::INT                               AS isodow,
       b.aberto,
       b.dia < hoje_br()                                             AS encerrado,
       b.peso,
       ROUND(b.pedidos_meta * b.peso / SUM(b.peso) OVER (PARTITION BY b.mes))::INT AS meta_dia,
       COALESCE(p.pedidos, 0)::INT                                   AS pedidos
FROM base b
LEFT JOIN pedidos p ON p.dia = b.dia;

-- ------------------------------------------------------------
-- Selos do mês (Qualinut automático; iFood e Google manuais)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW kpi_premio_selos AS
WITH cfg AS (SELECT * FROM premio_config WHERE id = 1),
qualinut AS (
    SELECT m.mes,
           (SELECT ROUND(AVG(a.pct), 1) FROM auditoria_qualinut a
             WHERE a.data >= m.mes AND a.data < m.mes + INTERVAL '1 month') AS media_mes,
           (SELECT a.pct FROM auditoria_qualinut a
             WHERE a.data < m.mes + INTERVAL '1 month'
             ORDER BY a.data DESC LIMIT 1)                                  AS ultima_nota
    FROM premio_metas_mensais m
)
SELECT q.mes,
       COALESCE(q.media_mes, q.ultima_nota)                              AS qualinut_nota,
       q.media_mes IS NOT NULL                                           AS qualinut_teve_visita,
       COALESCE(q.media_mes, q.ultima_nota) >= cfg.qualinut_min_pct      AS qualinut_ok,
       s.ifood_super                                                     AS ifood_ok,
       s.google_avaliacoes,
       s.google_media,
       CASE WHEN s.google_avaliacoes IS NULL THEN NULL
            ELSE s.google_avaliacoes >= cfg.google_min_avaliacoes
                 AND s.google_media >= cfg.google_min_media END          AS google_ok,
       (COALESCE(COALESCE(q.media_mes, q.ultima_nota) >= cfg.qualinut_min_pct, FALSE)::INT
        + COALESCE(s.ifood_super, FALSE)::INT
        + COALESCE(s.google_avaliacoes >= cfg.google_min_avaliacoes
                   AND s.google_media >= cfg.google_min_media, FALSE)::INT) AS selos
FROM qualinut q
CROSS JOIN cfg
LEFT JOIN premio_selos_mensais s ON s.mes = q.mes;

-- ------------------------------------------------------------
-- Mês a mês: realizado, projeção pelo ritmo e faixa
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW kpi_premio_mensal AS
WITH cfg AS (SELECT * FROM premio_config WHERE id = 1),
agg AS (
    SELECT d.mes,
           SUM(d.pedidos)::INT                                  AS pedidos,
           SUM(d.peso)                                          AS peso_total,
           SUM(d.peso) FILTER (WHERE d.encerrado)               AS peso_decorrido,
           COUNT(*) FILTER (WHERE d.aberto AND NOT d.encerrado) AS dias_restantes,
           BOOL_AND(d.encerrado)                                AS mes_encerrado
    FROM kpi_premio_diario d
    GROUP BY d.mes
), calc AS (
    SELECT a.*, m.pedidos_meta,
           CASE WHEN a.mes_encerrado THEN a.pedidos
                WHEN COALESCE(a.peso_decorrido, 0) = 0 THEN NULL
                ELSE ROUND(a.pedidos / a.peso_decorrido * a.peso_total)::INT END AS projecao
    FROM agg a JOIN premio_metas_mensais m ON m.mes = a.mes
)
SELECT c.mes, c.pedidos_meta, c.pedidos,
       ROUND(100.0 * c.pedidos / c.pedidos_meta, 1)                  AS pct_meta,
       GREATEST(c.pedidos_meta - c.pedidos, 0)                       AS faltam_meta,
       c.dias_restantes, c.mes_encerrado, c.projecao,
       ROUND(100.0 * c.projecao / c.pedidos_meta, 1)                 AS pct_projecao,
       CEIL(c.pedidos_meta * cfg.pct_quase_la)::INT                  AS pedidos_quase_la,
       CEIL(c.pedidos_meta * cfg.pct_super_green)::INT               AS pedidos_super_green,
       CEIL(c.pedidos_meta * cfg.pct_mega_green)::INT                AS pedidos_mega_green,
       CEIL(c.pedidos_meta * cfg.pct_ultra_green)::INT               AS pedidos_ultra_green,
       premio_faixa(c.projecao, c.pedidos_meta)                     AS faixa,
       s.selos,
       1 + s.selos * cfg.bonus_por_selo                              AS multiplicador
FROM calc c
CROSS JOIN cfg
LEFT JOIN kpi_premio_selos s ON s.mes = c.mes;

-- ------------------------------------------------------------
-- Placar do dia (imagem do WhatsApp). premio_placar(data) permite reconstituir
-- qualquer dia; a view usa ontem. Tudo considera só os dias até a referência.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS kpi_premio_placar;
DROP FUNCTION IF EXISTS premio_placar(DATE);

CREATE FUNCTION premio_placar(p_ref DATE)
RETURNS TABLE (
    data_ref DATE, pedidos_ref INT, meta_ref INT, ultimo_dia_sincronizado DATE,
    semana_inicio DATE, semana_pedidos INT, semana_meta_ate_ref INT, semana_meta INT,
    mes DATE, pedidos_meta INT, mes_pedidos INT, pct_meta NUMERIC, faltam_meta INT,
    dias_restantes INT, projecao INT, pct_projecao NUMERIC, faixa_projetada TEXT,
    pedidos_quase_la INT, pedidos_super_green INT,
    hoje DATE, hoje_aberto BOOLEAN, meta_hoje INT,
    qualinut_nota NUMERIC, qualinut_teve_visita BOOLEAN, qualinut_ok BOOLEAN,
    ifood_ok BOOLEAN, google_avaliacoes INT, google_media NUMERIC, google_ok BOOLEAN, selos INT
)
LANGUAGE sql STABLE AS $$
WITH cfg AS (SELECT * FROM premio_config WHERE id = 1),
d AS (SELECT * FROM kpi_premio_diario WHERE mes = DATE_TRUNC('month', p_ref)::DATE),
d_hoje AS (SELECT * FROM kpi_premio_diario WHERE dia = p_ref + 1),
mes AS (
    SELECT MAX(m.pedidos_meta)                                   AS meta,
           SUM(d.pedidos) FILTER (WHERE d.dia <= p_ref)::INT      AS pedidos,
           SUM(d.peso)                                           AS peso_total,
           SUM(d.peso) FILTER (WHERE d.dia <= p_ref)              AS peso_decorrido,
           SUM(d.peso) FILTER (WHERE d.dia > p_ref)               AS peso_restante,
           COUNT(*) FILTER (WHERE d.aberto AND d.dia > p_ref)::INT AS dias_restantes
    FROM d JOIN premio_metas_mensais m ON m.mes = d.mes
),
proj AS (
    SELECT mes.*,
           CASE WHEN COALESCE(peso_decorrido, 0) = 0 THEN NULL
                ELSE ROUND(pedidos / peso_decorrido * peso_total)::INT END AS projecao
    FROM mes
),
semana AS (
    SELECT SUM(k.pedidos) FILTER (WHERE k.dia <= p_ref)::INT  AS pedidos,
           SUM(k.meta_dia) FILTER (WHERE k.dia <= p_ref)::INT AS meta_ate_ref,
           SUM(k.meta_dia)::INT                               AS meta
    FROM kpi_premio_diario k
    WHERE k.semana_inicio = DATE_TRUNC('week', p_ref)::DATE
)
SELECT p_ref,
       (SELECT pedidos  FROM d WHERE dia = p_ref),
       (SELECT meta_dia FROM d WHERE dia = p_ref),
       (SELECT MAX((data_hora_abre AT TIME ZONE 'UTC')::DATE) FROM ecletica_pagamentos
         WHERE data_hora_abre >= p_ref - 7),
       DATE_TRUNC('week', p_ref)::DATE,
       semana.pedidos, semana.meta_ate_ref, semana.meta,
       DATE_TRUNC('month', p_ref)::DATE, proj.meta, proj.pedidos,
       ROUND(100.0 * proj.pedidos / proj.meta, 1),
       GREATEST(proj.meta - proj.pedidos, 0),
       proj.dias_restantes, proj.projecao,
       ROUND(100.0 * proj.projecao / proj.meta, 1),
       premio_faixa(proj.projecao, proj.meta),
       CEIL(proj.meta * cfg.pct_quase_la)::INT,
       CEIL(proj.meta * cfg.pct_super_green)::INT,
       p_ref + 1,
       d_hoje.aberto,
       CASE WHEN d_hoje.mes = DATE_TRUNC('month', p_ref)::DATE AND proj.peso_restante > 0
            THEN CEIL(GREATEST(proj.meta - proj.pedidos, 0) * d_hoje.peso / proj.peso_restante)::INT
            ELSE d_hoje.meta_dia END,
       s.qualinut_nota, s.qualinut_teve_visita, s.qualinut_ok,
       s.ifood_ok, s.google_avaliacoes, s.google_media, s.google_ok, s.selos
FROM proj
CROSS JOIN cfg
LEFT JOIN semana ON TRUE
LEFT JOIN d_hoje ON TRUE
LEFT JOIN kpi_premio_selos s ON s.mes = DATE_TRUNC('month', p_ref)::DATE
$$;

CREATE VIEW kpi_premio_placar AS
SELECT * FROM premio_placar(hoje_br() - 1);

-- Valores do mês por cargo (sem selos)
CREATE OR REPLACE VIEW kpi_premio_valores_cargo AS
SELECT c.cargo, c.ordem, c.peso,
       ROUND(cfg.valor_meta * cfg.fator_quase_la * c.peso, 2) AS valor_quase_la,
       ROUND(cfg.valor_meta * c.peso, 2)                      AS valor_meta,
       ROUND(cfg.valor_super_green * c.peso, 2)               AS valor_super_green
FROM premio_config cfg
CROSS JOIN LATERAL (VALUES
    ('Operação',   1, cfg.peso_operacao),
    ('Treinador',  2, cfg.peso_treinador),
    ('Estoquista', 3, cfg.peso_estoquista),
    ('Líder',      4, cfg.peso_lider),
    ('Chefe',      5, cfg.peso_chefe)
) AS c(cargo, ordem, peso)
WHERE cfg.id = 1;

-- ------------------------------------------------------------
-- Custo e previsibilidade (tela Premiação do Time, para os sócios)
-- ------------------------------------------------------------
ALTER TABLE premio_metas_mensais ADD COLUMN IF NOT EXISTS piloto BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE premio_metas_mensais SET piloto = TRUE WHERE mes = '2026-09-01' AND NOT piloto;

ALTER TABLE premio_config
    ADD COLUMN IF NOT EXISTS ger_faturamento_meta       NUMERIC NOT NULL DEFAULT 1200,
    ADD COLUMN IF NOT EXISTS ger_faturamento_super      NUMERIC NOT NULL DEFAULT 1800,
    ADD COLUMN IF NOT EXISTS ger_custos_meta            NUMERIC NOT NULL DEFAULT 800,
    ADD COLUMN IF NOT EXISTS ger_custos_super           NUMERIC NOT NULL DEFAULT 1200,
    ADD COLUMN IF NOT EXISTS prime_cost_meta_pct        NUMERIC NOT NULL DEFAULT 52,
    ADD COLUMN IF NOT EXISTS prime_cost_super_pct       NUMERIC NOT NULL DEFAULT 50.5,
    ADD COLUMN IF NOT EXISTS ger_degrau                 NUMERIC NOT NULL DEFAULT 1000,
    ADD COLUMN IF NOT EXISTS fator_subgerente           NUMERIC NOT NULL DEFAULT 0.5,
    ADD COLUMN IF NOT EXISTS estoq_cmv_pct_1            NUMERIC NOT NULL DEFAULT 30,
    ADD COLUMN IF NOT EXISTS estoq_cmv_valor_1          NUMERIC NOT NULL DEFAULT 150,
    ADD COLUMN IF NOT EXISTS estoq_cmv_pct_2            NUMERIC NOT NULL DEFAULT 28.5,
    ADD COLUMN IF NOT EXISTS estoq_cmv_valor_2          NUMERIC NOT NULL DEFAULT 250,
    ADD COLUMN IF NOT EXISTS estoq_min_dias_desperdicio INT     NOT NULL DEFAULT 20;

-- Elegíveis por cargo; mês sem linha usa o último quadro informado.
-- Semente = Relatório de Quadro de Pessoal de 09/09/2026 (estagiários, ADM e gerência fora).
CREATE TABLE IF NOT EXISTS premio_quadro_mensal (
    mes           DATE PRIMARY KEY CHECK (EXTRACT(DAY FROM mes) = 1),
    operacao      INT NOT NULL DEFAULT 0,
    treinador     INT NOT NULL DEFAULT 0,
    estoquista    INT NOT NULL DEFAULT 0,
    lider         INT NOT NULL DEFAULT 0,
    chefe         INT NOT NULL DEFAULT 0,
    observacao    TEXT,
    atualizado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO premio_quadro_mensal (mes, operacao, treinador, estoquista, lider, chefe, observacao) VALUES
    ('2026-09-01', 12, 4, 1, 1, 3, 'Relatório 09/09: Ribie e Ana Carolina em experiência'),
    ('2026-10-01', 11, 4, 1, 1, 3, 'Sem Juan (aviso prévio); líder de pista a definir')
ON CONFLICT (mes) DO NOTHING;

-- Gatilhos de contagem do estoquista (manual até integrar o Greenjoy Stock); NULL = em apuração
CREATE TABLE IF NOT EXISTS premio_estoquista_mensal (
    mes                 DATE PRIMARY KEY CHECK (EXTRACT(DAY FROM mes) = 1),
    contagem_diaria_ok  BOOLEAN,
    contagem_semanal_ok BOOLEAN,
    observacao          TEXT,
    atualizado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Custo de um mês numa faixa. Gatilho do estoquista NULL conta como pago (previsão conservadora).
-- Mês piloto: time e subgerente recebem no mínimo a Meta; a gerente fica fora (regra dela vale de outubro).
DROP FUNCTION IF EXISTS premio_custo(DATE, TEXT, INT, NUMERIC, NUMERIC, BOOLEAN) CASCADE;
CREATE FUNCTION premio_custo(p_mes DATE, p_faixa TEXT, p_selos INT, p_prime NUMERIC,
                             p_cmv NUMERIC, p_estoquista_ok BOOLEAN)
RETURNS TABLE (equipe NUMERIC, estoquista NUMERIC, gerente NUMERIC, subgerente NUMERIC, total NUMERIC)
LANGUAGE sql STABLE AS $$
WITH cfg AS (SELECT * FROM premio_config WHERE id = 1),
q AS (
    SELECT operacao, treinador, estoquista AS qtd_estoquista, lider, chefe
    FROM premio_quadro_mensal WHERE mes <= p_mes ORDER BY mes DESC LIMIT 1
),
v AS (
    SELECT q.*,
           COALESCE((SELECT piloto FROM premio_metas_mensais WHERE mes = p_mes), FALSE) AS piloto,
           COALESCE(p_faixa, 'Sem prêmio') AS faixa,
           1 + COALESCE(p_selos, 0) * cfg.bonus_por_selo AS mult,
           cfg.*
    FROM q CROSS JOIN cfg
),
valores AS (
    SELECT v.*,
           CASE WHEN piloto AND faixa IN ('Sem prêmio', 'Quase lá') THEN valor_meta
                WHEN faixa = 'Sem prêmio' THEN 0
                WHEN faixa = 'Quase lá'   THEN valor_meta * fator_quase_la
                WHEN faixa = 'Meta'       THEN valor_meta
                ELSE valor_super_green END AS valor_cota,
           CASE WHEN piloto AND faixa IN ('Sem prêmio', 'Quase lá') THEN ger_faturamento_meta
                WHEN faixa = 'Sem prêmio' THEN 0
                WHEN faixa = 'Quase lá'   THEN ger_faturamento_meta * fator_quase_la
                WHEN faixa = 'Meta'       THEN ger_faturamento_meta
                ELSE ger_faturamento_super END AS ger_faturamento,
           CASE WHEN p_prime IS NULL               THEN 0
                WHEN p_prime <  prime_cost_super_pct THEN ger_custos_super
                WHEN p_prime <= prime_cost_meta_pct  THEN ger_custos_meta
                ELSE 0 END AS ger_custos,
           CASE WHEN p_prime IS NULL OR p_prime > prime_cost_meta_pct THEN 0
                WHEN faixa = 'Ultra Green' THEN 2 * ger_degrau
                WHEN faixa = 'Mega Green'  THEN ger_degrau
                ELSE 0 END AS ger_escada,
           CASE WHEN p_cmv IS NULL            THEN 0
                WHEN p_cmv <= estoq_cmv_pct_2 THEN estoq_cmv_valor_2
                WHEN p_cmv <= estoq_cmv_pct_1 THEN estoq_cmv_valor_1
                ELSE 0 END AS estoq_cmv
    FROM v
),
c AS (
    SELECT ROUND((operacao * peso_operacao + treinador * peso_treinador + lider * peso_lider
                  + chefe * peso_chefe) * valor_cota * mult, 2)                   AS equipe,
           CASE WHEN p_estoquista_ok IS FALSE THEN 0
                ELSE ROUND(qtd_estoquista * (peso_estoquista * valor_cota * mult + estoq_cmv), 2) END AS estoquista,
           ROUND((ger_faturamento + ger_custos) * mult + ger_escada, 2)             AS gerencia,
           fator_subgerente, piloto
    FROM valores
)
SELECT equipe, estoquista,
       CASE WHEN piloto THEN 0 ELSE gerencia END,
       ROUND(gerencia * fator_subgerente, 2),
       equipe + estoquista + CASE WHEN piloto THEN 0 ELSE gerencia END + ROUND(gerencia * fator_subgerente, 2)
FROM c
$$;

CREATE OR REPLACE VIEW kpi_premio_custo_mensal AS
WITH cfg AS (SELECT * FROM premio_config WHERE id = 1),
prime AS (
    SELECT TO_DATE(p.mes, 'YYYY-MM') AS mes, p.prime_cost_pct, p.faturamento_mes,
           p.cmv + p.labor_total AS custo
    FROM kpi_prime_cost_mensal p
),
base AS (
    SELECT m.mes, m.pedidos_meta, m.pedidos, m.pct_meta, m.projecao, m.pct_projecao, m.dias_restantes,
           m.selos, m.multiplicador, mm.piloto,
           CASE WHEN m.mes_encerrado       THEN 'fechado'
                WHEN m.mes <= hoje_br() - 1 THEN 'em_curso'
                ELSE 'futuro' END                                                 AS status,
           CASE WHEN m.mes <= hoje_br() - 1 THEN m.faixa END                      AS faixa,
           -- dezembro carrega o 13º: o gate de custos usa o prime cost acumulado do trimestre
           CASE WHEN EXTRACT(MONTH FROM m.mes) = 12
                THEN (SELECT ROUND(100 * SUM(x.custo) / NULLIF(SUM(x.faturamento_mes), 0), 1)
                        FROM prime x
                       WHERE x.mes BETWEEN DATE_TRUNC('quarter', m.mes) AND m.mes)
                ELSE pr.prime_cost_pct END                                        AS prime_cost_pct,
           (SELECT ROUND(AVG(r.cmv_30d_pct), 1) FROM kpi_cmv_rolling r
             WHERE r.dia >= m.mes AND r.dia < m.mes + INTERVAL '1 month')          AS cmv_30d_medio,
           (SELECT COUNT(DISTINCT d.data)::INT FROM registro_desperdicio d
             WHERE d.data >= m.mes AND d.data < m.mes + INTERVAL '1 month')        AS dias_desperdicio,
           e.contagem_diaria_ok, e.contagem_semanal_ok
    FROM kpi_premio_mensal m
    JOIN premio_metas_mensais mm ON mm.mes = m.mes
    LEFT JOIN prime pr ON pr.mes = m.mes
    LEFT JOIN premio_estoquista_mensal e ON e.mes = m.mes
),
gatilho AS (
    SELECT b.*,
           CASE WHEN b.piloto THEN TRUE
                WHEN b.contagem_diaria_ok IS FALSE OR b.contagem_semanal_ok IS FALSE THEN FALSE
                WHEN b.status = 'fechado' AND b.dias_desperdicio < cfg.estoq_min_dias_desperdicio THEN FALSE
                WHEN b.contagem_diaria_ok AND b.contagem_semanal_ok
                     AND b.dias_desperdicio >= cfg.estoq_min_dias_desperdicio THEN TRUE
           END AS estoquista_ok
    FROM base b CROSS JOIN cfg
)
SELECT g.mes, g.status, g.piloto, g.pedidos_meta, g.pedidos, g.pct_meta, g.projecao, g.pct_projecao,
       g.dias_restantes, g.faixa, g.selos, g.multiplicador, g.prime_cost_pct, g.cmv_30d_medio,
       g.dias_desperdicio, g.contagem_diaria_ok, g.contagem_semanal_ok, g.estoquista_ok,
       prev.equipe     AS previsto_equipe,
       prev.estoquista AS previsto_estoquista,
       prev.gerente    AS previsto_gerente,
       prev.subgerente AS previsto_subgerente,
       CASE WHEN g.faixa IS NULL THEN NULL ELSE prev.total END AS previsto_total,
       sem.total   AS cenario_sem_premio,
       quase.total AS cenario_quase_la,
       meta.total  AS cenario_meta,
       sup.total   AS cenario_super_green,
       teto.total  AS teto,
       CASE WHEN g.faixa IN ('Sem prêmio', 'Quase lá') AND NOT g.piloto
            THEN meta_real.total - prev.total ELSE 0 END      AS recuperacao_potencial
FROM gatilho g
CROSS JOIN LATERAL premio_custo(g.mes, g.faixa, g.selos, g.prime_cost_pct, g.cmv_30d_medio, g.estoquista_ok) prev
-- cenários: prime cost real se o mês fechou; senão o estimado para a faixa (análise de 14/09/2026)
CROSS JOIN LATERAL premio_custo(g.mes, 'Sem prêmio', g.selos,
    CASE WHEN g.status = 'fechado' THEN g.prime_cost_pct ELSE 53 END, g.cmv_30d_medio, g.estoquista_ok) sem
CROSS JOIN LATERAL premio_custo(g.mes, 'Quase lá', g.selos,
    CASE WHEN g.status = 'fechado' THEN g.prime_cost_pct ELSE 53 END, g.cmv_30d_medio, g.estoquista_ok) quase
CROSS JOIN LATERAL premio_custo(g.mes, 'Meta', g.selos,
    CASE WHEN g.status = 'fechado' THEN g.prime_cost_pct ELSE 50.9 END, g.cmv_30d_medio, g.estoquista_ok) meta
CROSS JOIN LATERAL premio_custo(g.mes, 'Super Green', g.selos,
    CASE WHEN g.status = 'fechado' THEN g.prime_cost_pct ELSE 49.9 END, g.cmv_30d_medio, g.estoquista_ok) sup
CROSS JOIN LATERAL premio_custo(g.mes, 'Ultra Green', 3, 49, 28, TRUE) teto
-- recuperação: diferença até a Meta com o mesmo prime cost (componente de custos se cancela)
CROSS JOIN LATERAL premio_custo(g.mes, 'Meta', g.selos, g.prime_cost_pct, g.cmv_30d_medio, g.estoquista_ok) meta_real;

-- Trimestre: pedidos contra a meta e faixa de custo (fechado + em curso + cenário dos meses futuros)
CREATE OR REPLACE VIEW kpi_premio_trimestre AS
SELECT DATE_TRUNC('quarter', c.mes)::DATE                                       AS trimestre,
       COUNT(*)::INT                                                             AS meses,
       BOOL_AND(c.piloto)                                                        AS piloto,
       SUM(c.pedidos_meta)::INT                                                  AS pedidos_meta,
       SUM(c.pedidos)::INT                                                       AS pedidos,
       ROUND(100.0 * SUM(c.pedidos) / SUM(c.pedidos_meta), 1)                    AS pct_meta,
       COALESCE(SUM(c.previsto_total) FILTER (WHERE c.status = 'fechado'), 0)    AS custo_realizado,
       COALESCE(SUM(c.previsto_total) FILTER (WHERE c.status <> 'futuro'), 0)    AS custo_ate_agora,
       COALESCE(SUM(c.cenario_sem_premio)  FILTER (WHERE c.status = 'futuro'), 0) AS futuro_sem_premio,
       COALESCE(SUM(c.cenario_meta)        FILTER (WHERE c.status = 'futuro'), 0) AS futuro_meta,
       COALESCE(SUM(c.cenario_super_green) FILTER (WHERE c.status = 'futuro'), 0) AS futuro_super_green,
       SUM(c.teto)                                                               AS teto,
       SUM(c.recuperacao_potencial)                                              AS recuperacao_potencial
FROM kpi_premio_custo_mensal c
GROUP BY 1;

ALTER TABLE premio_config            ENABLE ROW LEVEL SECURITY;
ALTER TABLE premio_metas_mensais     ENABLE ROW LEVEL SECURITY;
ALTER TABLE premio_peso_dia_semana   ENABLE ROW LEVEL SECURITY;
ALTER TABLE loja_dias_fechados       ENABLE ROW LEVEL SECURITY;
ALTER TABLE premio_selos_mensais     ENABLE ROW LEVEL SECURITY;
ALTER TABLE premio_quadro_mensal     ENABLE ROW LEVEL SECURITY;
ALTER TABLE premio_estoquista_mensal ENABLE ROW LEVEL SECURITY;

-- Leitura para quem está logado; escrita só nas tabelas que a tela de gestão edita.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['premio_config', 'premio_metas_mensais', 'premio_peso_dia_semana',
                             'loja_dias_fechados', 'premio_selos_mensais', 'premio_quadro_mensal',
                             'premio_estoquista_mensal'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_leitura', t);
        EXECUTE format('CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (true)', t || '_leitura', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['premio_selos_mensais', 'premio_quadro_mensal', 'premio_estoquista_mensal'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_escrita', t);
        EXECUTE format('CREATE POLICY %I ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t || '_escrita', t);
    END LOOP;
END $$;

-- O Supabase dá GRANT padrão para anon em tudo que nasce no public, e views ignoram o RLS das
-- tabelas base (ver acesso_views.sql). Custo de prêmio é dado de sócio: fechado para anon.
REVOKE ALL ON premio_config, premio_metas_mensais, premio_peso_dia_semana, loja_dias_fechados,
              premio_selos_mensais, premio_quadro_mensal, premio_estoquista_mensal,
              kpi_premio_diario, kpi_premio_selos, kpi_premio_mensal, kpi_premio_placar,
              kpi_premio_valores_cargo, kpi_premio_custo_mensal, kpi_premio_trimestre
FROM anon;
REVOKE EXECUTE ON FUNCTION premio_placar(DATE), premio_faixa(NUMERIC, NUMERIC),
                           premio_custo(DATE, TEXT, INT, NUMERIC, NUMERIC, BOOLEAN) FROM PUBLIC, anon;

GRANT SELECT ON premio_config, premio_metas_mensais, premio_peso_dia_semana, loja_dias_fechados,
                premio_selos_mensais, premio_quadro_mensal, premio_estoquista_mensal,
                kpi_premio_diario, kpi_premio_selos, kpi_premio_mensal, kpi_premio_placar,
                kpi_premio_valores_cargo, kpi_premio_custo_mensal, kpi_premio_trimestre
TO authenticated;
GRANT INSERT, UPDATE ON premio_selos_mensais, premio_quadro_mensal, premio_estoquista_mensal TO authenticated;
GRANT EXECUTE ON FUNCTION premio_placar(DATE), premio_faixa(NUMERIC, NUMERIC),
                          premio_custo(DATE, TEXT, INT, NUMERIC, NUMERIC, BOOLEAN) TO authenticated;
