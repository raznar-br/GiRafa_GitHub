-- views_qualinut.sql
-- Aba de Qualidade: a curva, o gap, e principalmente COMO fechar o gap.
--
-- Fonte: PDFs das auditorias Qualinut, extraídos por Qualinut/importar_auditorias.py.
-- Três níveis, todos vindos do próprio relatório:
--   · auditoria_qualinut           — score e % totais (cabeçalho do PDF)
--   · auditoria_qualinut_categoria — subtotais por categoria (impressos no PDF)
--   · auditoria_qualinut_itens     — resposta item a item, para reincidência e simulador
-- Categoria NÃO é derivada da soma dos itens: o checklist v.3 tem perguntas fora do
-- critério v.4 usado como catálogo, e derivar subestimava o máximo de cada categoria.

-- ============================================================
-- qualinut_acoes — o "como". De-para item do checklist -> ação concreta.
-- padrao é usado com ILIKE contra item_chave (normalizado, sem acento).
-- ============================================================
-- critico_sanitario marca o achado que pode adoecer cliente ou render auto de
-- infração no dia da visita — temperatura fora de faixa, descongelamento errado,
-- químico solto, produto vencido em uso, praga. Esses entram na pauta da semana
-- independente de pontuação: a régua de pontos do checklist mede perda de nota,
-- não gravidade. Sem esse override, "peça de suíno descongelando sobre a bancada"
-- (03/08) caía para o décimo lugar por valer 5 pts e ter reprovado só 1 vez em 8.
DROP TABLE IF EXISTS qualinut_acoes CASCADE;
CREATE TABLE qualinut_acoes (
    id                SERIAL PRIMARY KEY,
    padrao            TEXT NOT NULL,
    acao              TEXT NOT NULL,
    responsavel       TEXT NOT NULL,
    frequencia        TEXT NOT NULL,
    verificacao       TEXT,
    critico_sanitario BOOLEAN NOT NULL DEFAULT FALSE,
    -- rotina de turno se cobra todo dia e disputa a atenção da equipe; tarefa com
    -- prazo tem dono único e fecha ou não fecha. Misturar as duas na mesma lista
    -- faz a reunião tratar "comprar dispenser" e "etiquetar tudo" com a mesma
    -- linguagem, e nenhuma das duas anda
    natureza          TEXT NOT NULL DEFAULT 'rotina de turno'
);

INSERT INTO qualinut_acoes
    (padrao, acao, responsavel, frequencia, verificacao, critico_sanitario) VALUES
 ('%produtos vencidos%',
  'Checklist de validades na abertura e na troca de turno, com responsável nomeado. Caixa de troca identificada e afastada dos alimentos, no estoque seco e na câmara.',
  'Chefe de Turno', 'Abertura e troca de turno',
  'Foto do checklist assinado no grupo da gestão', TRUE),
 -- o operador responde pela etiqueta na praça; a validade errada no cadastro do
 -- sistema (suco a 12h em vez de 6h) não é dele, é do gerente
 ('%produtos identificados e protegidos%',
  'Etiquetadora abastecida em cada praça na abertura. Item sem etiqueta é descarte, não recolocação — e o descarte é registrado com o nome do responsável. Em paralelo, o gerente corrige no sistema as validades erradas (suco 6h, não 12h) e revisa o cadastro item a item.',
  'Cozinheiro + Atendente (cadastro: Gerente)', 'Contínuo',
  'Ronda do líder a cada 2h — zero item sem etiqueta', FALSE),
 ('%contaminacao cruzada%',
  'Ordem fixa de prateleira: pronto para consumo em cima, cru embaixo, nunca proteína animal ao lado de molho ou bolo. Foto-padrão colada na porta da câmara. Tábuas e utensílios por tipo de alimento; papelão e celular fora da área de manipulação.',
  'Líder de Setor', 'Ronda a cada 2h',
  'Registro da ronda no histórico diário', TRUE),
 -- a decisão do degelo é de D-1, na puxada do freezer: por isso o dono é o chefe
 -- de turno, não o cozinheiro que executa
 ('%descongelamento%',
  'Descongelar só sob refrigeração a 5°C ou direto na cocção. Nada de carne sobre bancada em temperatura ambiente. Programar a retirada do congelador na véspera, com etiqueta de início do degelo.',
  'Chefe de Turno', 'Puxada do freezer na véspera',
  'Etiqueta de degelo com data e hora conferida pelo líder', TRUE),
 ('%manipuladores%uniforme%',
  'Conferir uniforme, touca e ausência de adornos na entrada de cada colaborador. Uniforme completo para todo novo funcionário antes do primeiro turno. Reincidência gera feedback formal registrado.',
  'Chefe de Turno', 'Entrada de cada turno',
  'Lista de presença com campo de conformidade', FALSE),
 ('%pia de lavagem%',
  'Pia abastecida com sabonete antisséptico e papel toalha na abertura e na troca de turno. Repor os dispensers quebrados da cozinha, do refeitório e do salão, e identificar cada dispenser novo com o nome do produto.',
  'Gerente + Líder de Setor', 'Abertura e troca de turno',
  'Item fixo do checklist de abertura', TRUE),
 ('%higiene das areas de manipulacao%',
  'POP de higienização por área com escala nominal. Limpeza pesada semanal de piso, rodapé e rejunte das áreas de pré-preparo e produção, incluindo a escada entre pista e cozinha e o piso do delivery.',
  'Líder de Setor', 'Diário + pesada semanal',
  'Escala assinada afixada na área', FALSE),
 ('%caixas e potes limpos%',
  'Manter estoque reserva de potes e trocar para etiqueta removível. Pote trincado vai ao lixo no ato em que for visto, não no fechamento. Panela e cuba encrustada volta para a lavagem antes de ir à prateleira de louça limpa.',
  'Aj. de Cozinha', 'Contínuo + reposição semanal',
  'Conferência do líder no fechamento', FALSE),
 ('%produtos quimicos%',
  'Borrifador identificado com nome do produto e diluição, sem exceção. Só produto sem perfume em área de manipulação — detergente perfumado e pasta de sabão saem da cozinha. Químicos e medicamentos em área exclusiva, longe de alimento e embalagem.',
  'Líder de Setor', 'Ronda diária',
  'Foto da prateleira de químicos', TRUE),
 ('%higienizacao adequado%',
  'Reforçar o ciclo lavar + desinfetar com tempo de contato. Verificar funcionamento e temperatura da lava-louças.',
  'Aj. de Cozinha', 'Contínuo',
  'Registro de temperatura da lava-louças', FALSE),
 ('%higienizacao correta de frutas%',
  'Padronizar a diluição do sanitizante e o tempo de imersão, com proporção de água por quantidade de produto afixada na pia de hortifrúti.',
  'Cozinheiro', 'A cada preparo',
  'Registro no formulário de higienização', TRUE),
 ('%estoque%pvps%',
  'Aplicar PVPS: o que vence primeiro fica à frente. Tudo afastado do piso e da parede, em prateleira ou estrado.',
  'Estoquista', 'A cada recebimento',
  'Conferência do gerente na entrada de mercadoria', FALSE),
 ('%freezers%',
  'Ordem de prateleira nos freezers, geladeiras e câmaras: pronto em cima, pré-preparado no meio, cru embaixo. Substituir a prateleira da câmara em mau estado.',
  'Estoquista', 'Diário',
  'Foto-padrão na porta de cada equipamento', TRUE),
 ('%recebimento adequado%',
  'Conferir e registrar temperatura na entrada de todo perecível e recusar carga fora de faixa. Produto cárneo só entra com identificação do fornecedor; item sem data de validade do fabricante é devolvido e o fornecedor, notificado.',
  'Estoquista', 'A cada recebimento',
  'Planilha de recebimento com temperatura e nota', TRUE),
 ('%epi%',
  'Disponibilizar e cobrar luva de borracha, bota, sapato de segurança, óculos e máscara na higienização pesada e no manuseio de químicos. Ficha de EPI assinada e atualizada por colaborador.',
  'Gerente', 'Contínuo',
  'Estoque mínimo de EPI conferido semanalmente', FALSE),
 ('%equipamentos de coccao%',
  'Lista única de ordens de serviço com data de abertura e prazo: porta da máquina de gelo, tomada da geladeira da cozinha, prateleira da câmara. Nada fecha sem foto do reparo. Higienizar a evaporadora das geladeiras e freezers toda segunda, com registro.',
  'Gerente', 'Semanal',
  'Lista de OS com foto do reparo', TRUE),
 ('%temperatura adequada dos equipamentos%',
  'Medir e registrar a temperatura de todo equipamento na abertura, às 14h e no fechamento. Fora de faixa, agir na hora — transferir o produto e abrir OS — e anotar a ação ao lado do valor.',
  'Chefe de Turno', 'Três vezes ao dia',
  'Planilha de temperatura com ação corretiva registrada', TRUE),
 -- é o único registro que prova o controle de temperatura: sem ele a próxima
 -- pista a 15,8°C só aparece na visita seguinte, e é o primeiro documento que a
 -- vigilância pede. Por isso entra como risco sanitário, apesar dos 4 pts
 ('%formularios de qualidade%',
  'Preencher no ato, não no fim do dia. Planilha sem ação corretiva registrada ao lado do valor fora de faixa conta como não preenchida.',
  'Chefe de Turno', 'Diário',
  'Auditoria interna semanal dos formulários', TRUE),
 ('%pragas%',
  'Manter contrato de controle de pragas em dia, com certificado visível, e vedar frestas e ralos.',
  'Gerente', 'Trimestral',
  'Certificado dentro da validade', TRUE),
 ('%lixeiras%',
  'Lixeiras com pedal funcionando e tampa fechada. Trocar as que estiverem com pedal quebrado.',
  'Gerente', 'Semanal',
  'Checagem física de todas as lixeiras', FALSE),
 ('%sala de convivencia%',
  'Armário individual com porta e cadeado para cada colaborador — pertence não fica sobre armário, cadeira ou escada. Repor dispenser de sabonete e papel dos sanitários e desentupir a pia do feminino.',
  'Gerente', 'Semanal',
  'Vistoria do vestiário na reunião de segunda', FALSE),
 ('%utensilios de limpeza%',
  'Suporte de parede para rodo, vassoura e mop — nada apoiado no chão. Utensílio de sanitário fica em local separado e identificado.',
  'Aj. de Cozinha', 'Diário no fechamento',
  'Conferência visual do líder no fechamento', FALSE),
 -- alimento encostado na parede e sujidade atrás da porta são layout e acesso,
 -- não faxina: quem responde é quem manda no estoque
 ('%higiene do estoque%',
  'Incluir o vão atrás da porta e os cantos na rotina de limpeza do estoque — é sempre onde a sujidade fica. Nada encostado na parede.',
  'Líder de Setor', 'Semanal',
  'Escala de limpeza assinada', FALSE),
 ('%controle de documentacao%',
  'Pasta única, física e digital, com índice e data de validade de cada documento. Pendências abertas hoje: PGR, PCMSO e ASO vencidos, PMOC sem preenchimento desde abril, higienização de reservatório e potabilidade da água vencendo em 05/08.',
  'Gerente', 'Mensal',
  'Índice da pasta com data de validade de cada documento', TRUE);

-- o resto é rotina de turno (default). Estes têm dono único, data e um fim:
-- compra-se, instala-se, renova-se, abre-se a OS — e aí fecha
UPDATE qualinut_acoes SET natureza = 'tarefa com prazo'
WHERE padrao IN ('%pia de lavagem%', '%produtos quimicos%', '%equipamentos de coccao%',
                 '%controle de documentacao%', '%sala de convivencia%',
                 '%utensilios de limpeza%', '%freezers%', '%epi%', '%pragas%', '%lixeiras%');

GRANT SELECT ON qualinut_acoes TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_evolucao — a curva, com meta e variação
-- ============================================================
CREATE OR REPLACE VIEW kpi_qualinut_evolucao AS
SELECT
    data,
    TO_CHAR(data, 'DD/MM/YY') AS rotulo,
    versao_checklist,
    auditor,
    score, score_max, pct,
    70.0 AS meta_pct,
    ROUND(pct - LAG(pct) OVER (ORDER BY data), 2) AS var_pp,
    ROUND(70.0 - pct, 2) AS gap_pp,
    CEIL(score_max * 0.70 - score) AS pontos_para_meta,
    CASE WHEN pct >= 70 THEN 'meta'
         WHEN pct >= 50 THEN 'atencao'
         ELSE 'critico' END AS faixa,
    ROUND(AVG(pct) OVER (ORDER BY data ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
        AS media_movel_3
FROM auditoria_qualinut
ORDER BY data;

GRANT SELECT ON kpi_qualinut_evolucao TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_categoria — evolução por categoria.
-- obtido/maximo vêm dos subtotais impressos no próprio relatório
-- (auditoria_qualinut_categoria), não da soma dos itens casados: o checklist v.3
-- tem perguntas fora do critério v.4, então derivar por item subestimava o máximo
-- (ex.: Pontos Críticos aparecia como 22/46 em vez de 23/59).
-- A contagem de não conformes vem dos itens, que é onde ela existe.
-- ============================================================
DROP VIEW IF EXISTS kpi_qualinut_categoria;
CREATE VIEW kpi_qualinut_categoria AS
SELECT
    c.data,
    TO_CHAR(c.data, 'DD/MM/YY') AS rotulo,
    c.categoria,
    c.obtido,
    c.maximo,
    c.pct,
    c.maximo - c.obtido AS pontos_perdidos,
    COALESCE(i.nao_conformes, 0) AS nao_conformes
FROM auditoria_qualinut_categoria c
LEFT JOIN (
    SELECT data, categoria, COUNT(*) FILTER (WHERE resposta = 'NC') AS nao_conformes
    FROM auditoria_qualinut_itens GROUP BY data, categoria
) i ON i.data = c.data AND i.categoria = c.categoria
ORDER BY c.data DESC, pontos_perdidos DESC NULLS LAST;

GRANT SELECT ON kpi_qualinut_categoria TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_gap — Pareto da última auditoria: onde estão os pontos perdidos
-- ============================================================
DROP VIEW IF EXISTS kpi_qualinut_gap;
CREATE VIEW kpi_qualinut_gap AS
WITH ultima AS (SELECT MAX(data) AS data FROM auditoria_qualinut),
perdas AS (
    SELECT c.categoria,
           (c.maximo - c.obtido) AS perdidos,
           COALESCE((SELECT COUNT(*) FROM auditoria_qualinut_itens i
                     WHERE i.data = c.data AND i.categoria = c.categoria
                       AND i.resposta = 'NC'), 0) AS itens_nc
    FROM auditoria_qualinut_categoria c, ultima u
    WHERE c.data = u.data
)
SELECT
    categoria,
    COALESCE(perdidos, 0) AS pontos_perdidos,
    itens_nc,
    ROUND(100.0 * perdidos / NULLIF(SUM(perdidos) OVER (), 0), 1) AS pct_das_perdas,
    ROUND(100.0 * SUM(perdidos) OVER (ORDER BY perdidos DESC
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / NULLIF(SUM(perdidos) OVER (), 0), 1) AS pct_acumulado
FROM perdas
WHERE perdidos > 0
ORDER BY perdidos DESC;

GRANT SELECT ON kpi_qualinut_gap TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_reincidencia — o coração da aba.
-- Item a item: quantas vezes reprovou, quantos pontos custou no acumulado,
-- se ainda está aberto, e qual a ação e o responsável.
-- ============================================================
CREATE OR REPLACE VIEW kpi_qualinut_reincidencia AS
WITH ultima AS (SELECT MAX(data) AS data FROM auditoria_qualinut),
item AS (
    SELECT
        i.item_chave,
        MAX(i.item)      AS item,
        MAX(i.categoria) AS categoria,
        MAX(i.pontos_max) AS pontos_max,
        COUNT(*) FILTER (WHERE i.resposta <> 'NA') AS auditorias_avaliado,
        COUNT(*) FILTER (WHERE i.resposta = 'NC')  AS vezes_nc,
        SUM(i.pontos_max) FILTER (WHERE i.resposta = 'NC') AS pontos_perdidos_total,
        BOOL_OR(i.resposta = 'NC' AND i.data = (SELECT data FROM ultima)) AS nc_na_ultima
    FROM auditoria_qualinut_itens i
    GROUP BY i.item_chave
)
SELECT
    it.item_chave,
    it.item,
    it.categoria,
    it.pontos_max,
    it.vezes_nc,
    it.auditorias_avaliado,
    ROUND(100.0 * it.vezes_nc / NULLIF(it.auditorias_avaliado, 0), 0) AS taxa_nc_pct,
    COALESCE(it.pontos_perdidos_total, 0) AS pontos_perdidos_total,
    it.nc_na_ultima,
    CASE
        WHEN it.vezes_nc = it.auditorias_avaliado AND it.auditorias_avaliado >= 4
             THEN 'cronico'
        WHEN it.nc_na_ultima THEN 'aberto'
        WHEN it.vezes_nc > 0 THEN 'resolvido'
        ELSE 'conforme'
    END AS situacao,
    a.acao,
    a.responsavel,
    a.frequencia,
    a.verificacao,
    COALESCE(a.critico_sanitario, FALSE) AS critico_sanitario,
    COALESCE(a.natureza, 'rotina de turno') AS natureza
FROM item it
LEFT JOIN LATERAL (
    SELECT acao, responsavel, frequencia, verificacao, critico_sanitario, natureza
    FROM qualinut_acoes q
    WHERE it.item_chave ILIKE q.padrao
    LIMIT 1
) a ON TRUE
WHERE it.vezes_nc > 0
ORDER BY it.nc_na_ultima DESC, it.pontos_max DESC NULLS LAST, it.vezes_nc DESC;

GRANT SELECT ON kpi_qualinut_reincidencia TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_simulador — quanto sobe a nota resolvendo os itens abertos,
-- do maior peso para o menor. Responde "o que fazer primeiro".
-- ============================================================
CREATE OR REPLACE VIEW kpi_qualinut_simulador AS
WITH ultima AS (SELECT data, score, score_max, pct FROM auditoria_qualinut
                ORDER BY data DESC LIMIT 1),
abertos AS (
    SELECT i.item, i.categoria, i.pontos_max,
           ROW_NUMBER() OVER (ORDER BY i.pontos_max DESC, i.item) AS ordem
    FROM auditoria_qualinut_itens i, ultima u
    WHERE i.data = u.data AND i.resposta = 'NC' AND i.pontos_max > 0
)
SELECT
    a.ordem,
    a.item,
    a.categoria,
    a.pontos_max,
    SUM(a.pontos_max) OVER (ORDER BY a.ordem) AS pontos_acumulados,
    u.score AS score_atual,
    u.pct   AS pct_atual,
    u.score + SUM(a.pontos_max) OVER (ORDER BY a.ordem) AS score_projetado,
    ROUND(100.0 * (u.score + SUM(a.pontos_max) OVER (ORDER BY a.ordem))
          / u.score_max, 1) AS pct_projetado,
    (100.0 * (u.score + SUM(a.pontos_max) OVER (ORDER BY a.ordem))
          / u.score_max) >= 70 AS atinge_meta
FROM abertos a, ultima u
ORDER BY a.ordem;

GRANT SELECT ON kpi_qualinut_simulador TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_status — cabeçalho da aba: onde estamos e há quanto tempo
-- ============================================================
CREATE OR REPLACE VIEW kpi_qualinut_status AS
WITH u AS (SELECT * FROM auditoria_qualinut ORDER BY data DESC LIMIT 1),
p AS (SELECT * FROM auditoria_qualinut ORDER BY data DESC OFFSET 1 LIMIT 1),
primeira AS (SELECT * FROM auditoria_qualinut ORDER BY data LIMIT 1)
SELECT
    u.data          AS ultima_auditoria,
    u.pct           AS pct_atual,
    u.score, u.score_max,
    p.pct           AS pct_anterior,
    ROUND(u.pct - p.pct, 2)        AS var_pp,
    pr.pct          AS pct_inicial,
    pr.data         AS primeira_auditoria,
    ROUND(u.pct - pr.pct, 2)       AS evolucao_total_pp,
    (hoje_br() - u.data)           AS dias_desde_ultima,
    CEIL(u.score_max * 0.70 - u.score) AS pontos_para_meta,
    (SELECT COUNT(*) FROM kpi_qualinut_reincidencia WHERE situacao = 'cronico') AS itens_cronicos,
    (SELECT COUNT(*) FROM kpi_qualinut_reincidencia WHERE nc_na_ultima)         AS itens_abertos,
    CASE
        WHEN hoje_br() - u.data > 60 THEN 'auditoria_vencida'
        WHEN u.pct >= 70 THEN 'meta'
        ELSE 'abaixo_meta'
    END AS status
FROM u, p, primeira pr;

GRANT SELECT ON kpi_qualinut_status TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_movimento — o que mudou da penúltima para a última auditoria.
-- Material de reunião: o que a equipe fechou (reconhecer) e o que voltou
-- (cobrar). Os itens que trocaram de/para "não verificado" ficam aqui também,
-- em categoria própria: sem eles o placar da reunião não fecha (a nota caiu 8
-- pontos entre 22/07 e 03/08, mas os itens avaliados nas duas visitas explicam
-- só 3) e, pior, um item que reprovou e não foi reavaliado some do radar — foi
-- o que aconteceu com a documentação legal, reprovada em 22/07 com PGR, PCMSO
-- e ASO vencidos e não verificada em 03/08.
-- ============================================================
-- as três se encadeiam (resumo -> pauta -> movimento); dropar na ordem inversa
-- mantém o arquivo repetível sem precisar de CASCADE
DROP VIEW IF EXISTS kpi_qualinut_pauta_resumo;
DROP VIEW IF EXISTS kpi_qualinut_pauta;
DROP VIEW IF EXISTS kpi_qualinut_movimento;
CREATE VIEW kpi_qualinut_movimento AS
WITH d AS (
    SELECT data, ROW_NUMBER() OVER (ORDER BY data DESC) AS rn
    FROM auditoria_qualinut
),
ult AS (SELECT data FROM d WHERE rn = 1),
pen AS (SELECT data FROM d WHERE rn = 2)
SELECT
    u.item_chave,
    u.item,
    u.categoria,
    u.pontos_max,
    p.resposta AS resposta_anterior,
    u.resposta AS resposta_atual,
    CASE WHEN p.resposta = 'NC' AND u.resposta = 'C'  THEN 'fechado'
         WHEN p.resposta = 'C'  AND u.resposta = 'NC' THEN 'regrediu'
         WHEN p.resposta = 'NC' AND u.resposta = 'NC' THEN 'segue_aberto'
         -- reprovou e não foi reavaliado: continua aberto até prova em contrário
         WHEN p.resposta = 'NC' AND u.resposta = 'NA' THEN 'nao_reavaliado'
         WHEN p.resposta = 'NA' AND u.resposta = 'NC' THEN 'novo_nc'
         ELSE 'estavel' END AS movimento,
    CASE WHEN p.resposta = 'NC' AND u.resposta = 'C'  THEN  u.pontos_max
         WHEN p.resposta = 'C'  AND u.resposta = 'NC' THEN -u.pontos_max
         WHEN p.resposta = 'NA' AND u.resposta = 'NC' THEN -u.pontos_max
         ELSE 0 END AS delta_pontos
FROM auditoria_qualinut_itens u
JOIN ult ON u.data = ult.data
JOIN auditoria_qualinut_itens p ON p.item_chave = u.item_chave
JOIN pen ON p.data = pen.data
ORDER BY ABS(CASE WHEN p.resposta <> u.resposta THEN u.pontos_max ELSE 0 END) DESC,
         u.pontos_max DESC;

GRANT SELECT ON kpi_qualinut_movimento TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_pauta — a aba vira reunião.
-- Uma linha por item que precisa ser discutido, já na ordem em que deve ser
-- discutido. Entram os itens reprovados na última visita e os que reprovaram na
-- anterior e não foram reavaliados — estes últimos continuam abertos até prova
-- em contrário, e sem eles a documentação legal vencida sumia da pauta.
--
-- A régua tem duas camadas, porque nenhuma sozinha dá a ordem certa:
--   · risco sanitário — o que adoece cliente ou rende autuação no dia entra na
--     semana independente de nota. É a camada que o checklist não mede.
--   · pontos esperados — peso do item x frequência com que ele reprova, mais
--     metade do peso se regrediu desde a última visita. É o que a loja deve
--     perder de novo se nada mudar, com prioridade para o sinal fresco.
-- Ordenar só por cronicidade jogava "produtos vencidos" (12 pts, o mais pesado
-- do checklist) para o fim da fila por ter passado numa das doze visitas; só por
-- pontos, "peça de suíno descongelando sobre a bancada" ficava em décimo.
-- Cada linha carrega o dono, a frequência e a verificação, para a reunião sair
-- com combinado e não com intenção. Foco separa o que se cobra nesta semana do
-- que fica no radar — pauta de doze itens não é pauta, é lista.
-- ============================================================
DROP VIEW IF EXISTS kpi_qualinut_pauta;
CREATE VIEW kpi_qualinut_pauta AS
WITH u AS (SELECT data, score, score_max FROM auditoria_qualinut ORDER BY data DESC LIMIT 1),
base AS (
    SELECT
        r.item_chave, r.item, r.categoria, r.pontos_max,
        r.vezes_nc, r.auditorias_avaliado, r.taxa_nc_pct,
        r.acao, r.responsavel, r.frequencia, r.verificacao,
        r.critico_sanitario, r.natureza,
        COALESCE(m.movimento, 'novo') AS movimento,
        CASE WHEN COALESCE(m.movimento, '') = 'nao_reavaliado'
             THEN 'nao_reavaliado' ELSE r.situacao END AS situacao,
        ROUND(r.pontos_max * COALESCE(r.taxa_nc_pct, 100) / 100.0, 1) AS pontos_esperados,
        ROUND(r.pontos_max * COALESCE(r.taxa_nc_pct, 100) / 100.0
              + CASE WHEN COALESCE(m.movimento, '') = 'regrediu'
                     THEN r.pontos_max / 2.0 ELSE 0 END, 1) AS prioridade
    FROM kpi_qualinut_reincidencia r
    LEFT JOIN kpi_qualinut_movimento m ON m.item_chave = r.item_chave
    WHERE r.nc_na_ultima OR COALESCE(m.movimento, '') = 'nao_reavaliado'
),
-- risco sanitário entra na semana sempre; dos demais, sobem os dois de maior
-- prioridade, para o item crônico de mais peso não ficar fora por não ser agudo
ranqueado AS (
    SELECT b.*,
           ROW_NUMBER() OVER (ORDER BY prioridade DESC, pontos_max DESC) AS rank_geral
    FROM base b
),
focado AS (
    SELECT r.*,
           (r.critico_sanitario OR r.rank_geral <= 2) AS esta_semana
    FROM ranqueado r
)
SELECT
    ROW_NUMBER() OVER (ORDER BY f.esta_semana DESC, f.prioridade DESC,
                                f.pontos_max DESC) AS ordem,
    f.item,
    f.categoria,
    f.pontos_max,
    f.situacao,
    f.movimento,
    f.critico_sanitario,
    COALESCE(f.natureza, 'rotina de turno') AS natureza,
    f.pontos_esperados,
    f.prioridade,
    f.vezes_nc,
    f.auditorias_avaliado,
    f.taxa_nc_pct,
    -- quanto a nota da loja sobe fechando só este item
    ROUND(100.0 * (u.score + f.pontos_max) / u.score_max, 1) AS pct_se_fechar,
    ROUND(100.0 * f.pontos_max / u.score_max, 1) AS ganho_pp,
    CASE WHEN f.esta_semana THEN 'esta semana' ELSE 'no radar' END AS foco,
    COALESCE(f.acao, 'Sem ação cadastrada — definir dono e prazo na reunião.') AS acao,
    COALESCE(f.responsavel, 'a definir') AS responsavel,
    COALESCE(f.frequencia, 'a definir')  AS frequencia,
    f.verificacao,
    u.data AS auditoria_ref
FROM focado f, u
ORDER BY ordem;

GRANT SELECT ON kpi_qualinut_pauta TO anon, authenticated;

-- ============================================================
-- kpi_qualinut_pauta_resumo — o cabeçalho da pauta: onde estamos, o que
-- fechamos, o que voltou e quanto está em jogo.
-- ============================================================
DROP VIEW IF EXISTS kpi_qualinut_pauta_resumo;
CREATE VIEW kpi_qualinut_pauta_resumo AS
WITH u AS (SELECT * FROM auditoria_qualinut ORDER BY data DESC LIMIT 1),
p AS (SELECT * FROM auditoria_qualinut ORDER BY data DESC OFFSET 1 LIMIT 1)
SELECT
    u.data  AS auditoria_ref,
    p.data  AS auditoria_anterior,
    u.pct, p.pct AS pct_anterior,
    ROUND(u.pct - p.pct, 2) AS var_pp,
    (hoje_br() - u.data) AS dias_desde_ultima,
    (SELECT COUNT(*) FROM kpi_qualinut_pauta) AS itens_pauta,
    (SELECT COUNT(*) FROM kpi_qualinut_pauta WHERE foco = 'esta semana') AS itens_semana,
    (SELECT COALESCE(SUM(pontos_max), 0) FROM kpi_qualinut_pauta) AS pontos_em_jogo,
    (SELECT COALESCE(SUM(pontos_max), 0) FROM kpi_qualinut_pauta WHERE foco = 'esta semana')
        AS pontos_semana,
    (SELECT COUNT(*) FROM kpi_qualinut_movimento WHERE movimento = 'fechado')  AS itens_fechados,
    (SELECT COUNT(*) FROM kpi_qualinut_movimento WHERE movimento = 'regrediu') AS itens_regrediram,
    (SELECT COUNT(*) FROM kpi_qualinut_movimento WHERE movimento = 'nao_reavaliado')
        AS itens_nao_reavaliados,
    (SELECT COUNT(*) FROM kpi_qualinut_pauta WHERE critico_sanitario) AS itens_criticos,
    CEIL(u.score_max * 0.70 - u.score) AS pontos_para_meta
FROM u, p;

GRANT SELECT ON kpi_qualinut_pauta_resumo TO anon, authenticated;
