-- schema_auditoria.sql
-- Tabelas das auditorias de qualidade Qualinut.
-- Populadas por Qualinut/importar_auditorias.py a partir dos PDFs.
--
-- Três níveis, todos extraídos do próprio relatório:
--   auditoria_qualinut           — score e % totais (cabeçalho do PDF)
--   auditoria_qualinut_categoria — subtotais por categoria (impressos no PDF)
--   auditoria_qualinut_itens     — resposta item a item (reincidência e simulador)

CREATE TABLE IF NOT EXISTS auditoria_qualinut (
    data             DATE PRIMARY KEY,
    versao_checklist TEXT,
    auditor          TEXT,
    score            INT,
    score_max        INT,
    pct              NUMERIC(5,2),
    arquivo          TEXT,
    criado_em        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS auditoria_qualinut_categoria (
    id        BIGSERIAL PRIMARY KEY,
    data      DATE NOT NULL REFERENCES auditoria_qualinut(data) ON DELETE CASCADE,
    categoria TEXT NOT NULL,
    obtido    INT,
    maximo    INT,
    pct       NUMERIC(5,2),
    UNIQUE (data, categoria)
);

CREATE TABLE IF NOT EXISTS auditoria_qualinut_itens (
    id             BIGSERIAL PRIMARY KEY,
    data           DATE NOT NULL REFERENCES auditoria_qualinut(data) ON DELETE CASCADE,
    categoria      TEXT NOT NULL,
    item           TEXT NOT NULL,
    item_chave     TEXT NOT NULL,
    resposta       TEXT NOT NULL CHECK (resposta IN ('C','NC','NA')),
    pontos_max     INT,
    pontos_obtidos INT
);

CREATE INDEX IF NOT EXISTS aq_itens_data  ON auditoria_qualinut_itens (data);
CREATE INDEX IF NOT EXISTS aq_itens_chave ON auditoria_qualinut_itens (item_chave);

-- leitura pública, escrita só pela service key do importador
ALTER TABLE auditoria_qualinut           ENABLE ROW LEVEL SECURITY;
ALTER TABLE auditoria_qualinut_categoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE auditoria_qualinut_itens     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aq_read  ON auditoria_qualinut;
DROP POLICY IF EXISTS aqc_read ON auditoria_qualinut_categoria;
DROP POLICY IF EXISTS aqi_read ON auditoria_qualinut_itens;

CREATE POLICY aq_read  ON auditoria_qualinut
    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY aqc_read ON auditoria_qualinut_categoria
    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY aqi_read ON auditoria_qualinut_itens
    FOR SELECT TO anon, authenticated USING (true);

GRANT SELECT ON auditoria_qualinut, auditoria_qualinut_categoria,
                auditoria_qualinut_itens TO anon, authenticated;
