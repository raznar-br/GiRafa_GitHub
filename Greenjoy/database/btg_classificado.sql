-- btg_classificado.sql
-- Camada única que todas as views de CMV, DRE e Prime Cost devem consumir.
-- Substitui os JOINs ad-hoc que cada view fazia contra jafeb_despesas_mapping.
--
-- Precedência: btg_classificacao (manual/inferido) > jafeb_despesas_mapping > 'Não classificado'.
-- A natureza do JAFEB é normalizada aqui: Despesa+Funcionários vira 'Folha' e
-- 'Impostos' (plural, como estava no JAFEB) vira 'Imposto'.

-- Grafia canônica de cada categoria: a variante mais usada no de-para vence.
-- O de-para tem 'Bebidas'/'bebidas' e 'Proteinas'/'Proteínas' como entradas
-- distintas, o que virava duas linhas no relatório semanal, cada uma com sua
-- própria média de 8 semanas — diluindo o desvio de ambas.
-- INITCAP resolveria a colisão, mas estragaria os rótulos ('Sobremesas E
-- Smoothies', 'Fgts'), então preservamos a grafia real mais frequente.
CREATE OR REPLACE VIEW categoria_canonica AS
WITH todas AS (
    SELECT TRIM(categoria_2) AS categoria, COUNT(*) AS n
    FROM jafeb_despesas_mapping WHERE categoria_2 IS NOT NULL GROUP BY 1
    UNION ALL
    SELECT TRIM(categoria_2), COUNT(*)
    FROM btg_classificacao WHERE categoria_2 IS NOT NULL GROUP BY 1
),
ranked AS (
    SELECT chave_texto(categoria) AS chave,
           categoria,
           ROW_NUMBER() OVER (PARTITION BY chave_texto(categoria)
                              ORDER BY SUM(n) DESC, categoria) AS rn
    FROM todas GROUP BY chave_texto(categoria), categoria
)
SELECT chave, categoria AS canonica FROM ranked WHERE rn = 1;

GRANT SELECT ON categoria_canonica TO anon, authenticated;

CREATE OR REPLACE VIEW btg_classificado AS
WITH jafeb AS (
    SELECT DISTINCT ON (UPPER(TRIM(descricao)))
        UPPER(TRIM(descricao)) AS chave,
        natureza, categoria_1, categoria_2
    FROM jafeb_despesas_mapping
    ORDER BY UPPER(TRIM(descricao)), id
),
-- Royalty (5%) e fundo de propaganda (1,5%) do faturamento do mês anterior,
-- pagos juntos por volta do dia 25. A razão entre os dois é exatamente 0,3000
-- em todos os meses da série, nas duas chaves — é contrato, não coincidência.
--
-- Até jul/2025 o boleto vinha por STARK BANK e o de-para mandava para
-- Despesa/Royalties. De out/2025 em diante virou PIX direto para a franqueadora
-- e o de-para passou a tratar como Custo/Molhos Cozinha Central: 6,5% do
-- faturamento entrou no CMV. Era isso que inflava o CMV publicado em ~6,5 p.p.
-- e tornava a meta de bônus do gerente (CMV ≤31%) inatingível por erro de
-- classificação.
--
-- GREENJOY COMERCIO DE ALIMENTOS e GREENJOY CENTRAL KITCHEN são a cozinha
-- central e continuam em Custo — são mercadoria de verdade.
--
-- Corte em 2024-02: antes disso os pagamentos à franqueadora eram implantação e
-- insumos de abertura, não royalty.
franquia AS (
    SELECT
        id_externo,
        CASE WHEN valor <= 1000 THEN 'Taxa fixa'
             WHEN ROW_NUMBER() OVER (PARTITION BY data_movimentacao
                                     ORDER BY valor DESC) = 1 THEN 'Royalties'
             ELSE 'Fundo de propaganda'
        END AS rubrica
    FROM btg_movimentacoes
    WHERE tipo ILIKE 'D%'
      AND data_movimentacao >= DATE '2024-02-01'
      AND (UPPER(TRIM(COALESCE(nome_pagador_recebedor, descricao))) LIKE 'GREENJOY FRANQUEADORA%'
        OR UPPER(TRIM(COALESCE(nome_pagador_recebedor, descricao))) = 'STARK BANK S.A.')
),
-- A chave 'DARF/DARF-SIMPLES 0385' vinha rotulada como 'Simples Nacional', e o
-- rótulo estava errado: a empresa é LUCRO PRESUMIDO. Provas — faturamento de
-- ~R$6,6M/ano estoura o teto do Simples (R$4,8M); a linha 'DAS - SIMPLES
-- NACIONAL' da DRE do JAFEB é zero; e as bases são as da presunção (IR 8%,
-- CSLL 12%). 0385 é só o código do formulário DARF.
--
-- São quatro guias por mês, separáveis pelo vencimento legal:
--   dia 20  → INSS patronal + terceiros  (~R$18k/mês)
--   dia 25  → PIS + COFINS
--   fim do mês → IRPJ + CSLL
-- Conferido ao centavo contra a DRE do JAFEB com um mês de defasagem: o DARF de
-- 24/04/2026 (R$18.940,75) = PIS 3.373,02 + COFINS 15.567,77 de mar/26.
--
-- Isso importa porque o INSS patronal é CUSTO DE PESSOAL, não tributo sobre
-- venda. Enquanto ficou em 'Federal', o Prime Cost saía ~3,5 p.p. baixo e o
-- semáforo dizia "ótimo" em quase todo mês.
darf AS (
    SELECT
        id_externo,
        CASE WHEN EXTRACT(DAY FROM data_movimentacao) <= 21 THEN 'INSS e terceiros'
             WHEN EXTRACT(DAY FROM data_movimentacao) <= 26 THEN 'PIS e COFINS'
             ELSE 'IRPJ e CSLL'
        END AS tributo
    FROM btg_movimentacoes
    WHERE tipo ILIKE 'D%'
      AND UPPER(TRIM(COALESCE(nome_pagador_recebedor, descricao))) = 'DARF/DARF-SIMPLES 0385'
)
SELECT
    b.id_externo,
    b.data_movimentacao,
    b.tipo,
    b.valor,
    b.descricao,
    b.nome_pagador_recebedor,
    UPPER(TRIM(COALESCE(b.nome_pagador_recebedor, b.descricao))) AS chave,
    COALESCE(
        CASE WHEN fr.rubrica IS NOT NULL THEN 'Despesa' END,
        c.natureza,
        CASE
            WHEN j.natureza = 'Despesa' AND j.categoria_2 = 'Funcionários' THEN 'Folha'
            WHEN j.natureza = 'Impostos' THEN 'Imposto'
            -- o de-para tem 'Capex' e 'CAPEX' como entradas distintas; a DRE
            -- filtrava só a maiúscula e perdia metade do investimento
            WHEN j.natureza ILIKE 'capex' THEN 'CAPEX'
            ELSE j.natureza
        END,
        'Não classificado'
    ) AS natureza,
    COALESCE(CASE WHEN fr.rubrica IS NOT NULL THEN 'Franquia' END,
             -- INSS entra como Encargos para o Prime Cost enxergar
             CASE WHEN dr.tributo = 'INSS e terceiros' THEN 'Encargos'
                  WHEN dr.tributo IS NOT NULL THEN 'Federal' END,
             c.categoria_1, j.categoria_1) AS categoria_1,
    COALESCE(fr.rubrica, dr.tributo,
             can.canonica, TRIM(COALESCE(c.categoria_2, j.categoria_2))) AS categoria_2,
    CASE
        WHEN fr.rubrica IS NOT NULL THEN 'contrato'
        WHEN dr.tributo IS NOT NULL THEN 'vencimento'
        WHEN c.chave IS NOT NULL THEN c.origem
        WHEN j.chave IS NOT NULL THEN 'jafeb'
        ELSE 'nenhuma'
    END AS origem_classificacao,
    TO_CHAR(b.data_movimentacao::timestamptz, 'YYYY-MM') AS mes,
    DATE_TRUNC('week', b.data_movimentacao::timestamptz)::DATE AS semana
FROM btg_movimentacoes b
LEFT JOIN btg_classificacao c
       ON c.chave = UPPER(TRIM(COALESCE(b.nome_pagador_recebedor, b.descricao)))
LEFT JOIN jafeb j
       ON j.chave = UPPER(TRIM(COALESCE(b.nome_pagador_recebedor, b.descricao)))
LEFT JOIN categoria_canonica can
       ON can.chave = chave_texto(COALESCE(c.categoria_2, j.categoria_2))
LEFT JOIN franquia fr ON fr.id_externo = b.id_externo
LEFT JOIN darf dr ON dr.id_externo = b.id_externo;

GRANT SELECT ON btg_classificado TO anon, authenticated;

-- ============================================================
-- kpi_cobertura_mapping — honestidade sobre a qualidade do dado.
-- Se pct_nao_classificado passar de 5%, os números de CMV e margem
-- não são confiáveis e o dashboard precisa dizer isso.
-- ============================================================
CREATE OR REPLACE VIEW kpi_cobertura_mapping AS
SELECT
    mes,
    ROUND(SUM(valor), 2) AS total_debitos,
    ROUND(SUM(valor) FILTER (WHERE natureza = 'Não classificado'), 2) AS nao_classificado,
    ROUND(100.0 * COALESCE(SUM(valor) FILTER (WHERE natureza = 'Não classificado'), 0)
          / NULLIF(SUM(valor), 0), 1) AS pct_nao_classificado,
    ROUND(100.0 * COALESCE(SUM(valor) FILTER (WHERE origem_classificacao = 'inferido'), 0)
          / NULLIF(SUM(valor), 0), 1) AS pct_inferido,
    COUNT(DISTINCT chave) FILTER (WHERE natureza = 'Não classificado') AS chaves_pendentes,
    CASE
        WHEN 100.0 * COALESCE(SUM(valor) FILTER (WHERE natureza = 'Não classificado'), 0)
             / NULLIF(SUM(valor), 0) <= 5  THEN 'ok'
        WHEN 100.0 * COALESCE(SUM(valor) FILTER (WHERE natureza = 'Não classificado'), 0)
             / NULLIF(SUM(valor), 0) <= 15 THEN 'atencao'
        ELSE 'critico'
    END AS status
FROM btg_classificado
WHERE tipo ILIKE 'D%'
GROUP BY mes
ORDER BY mes DESC;

GRANT SELECT ON kpi_cobertura_mapping TO anon, authenticated;

-- ============================================================
-- kpi_mapping_pendentes — fila de trabalho: o que classificar em seguida,
-- ordenado por quanto dinheiro cada chave representa.
-- ============================================================
CREATE OR REPLACE VIEW kpi_mapping_pendentes AS
SELECT
    chave,
    COUNT(*) AS ocorrencias,
    ROUND(SUM(valor), 2) AS total,
    ROUND(AVG(valor), 2) AS ticket_medio,
    MAX(data_movimentacao) AS ultima_ocorrencia
FROM btg_classificado
WHERE tipo ILIKE 'D%'
  AND natureza = 'Não classificado'
  AND data_movimentacao >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY chave
ORDER BY total DESC;

GRANT SELECT ON kpi_mapping_pendentes TO anon, authenticated;
