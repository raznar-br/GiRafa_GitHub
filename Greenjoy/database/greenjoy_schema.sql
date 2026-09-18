-- greenjoy_schema.sql
-- Rodar no SQL Editor do Supabase (projeto Greenjoy)

-- ============================================================
-- ECLÉTICA — espelhos do PDV MySQL (populados pelo sync diário)
-- ============================================================

CREATE TABLE IF NOT EXISTS ecletica_grupos (
    cod_grupo   TEXT PRIMARY KEY,
    descr_grupo TEXT,
    synced_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ecletica_produtos (
    cod_item    TEXT PRIMARY KEY,
    descr_item  TEXT,
    cod_grupo   TEXT REFERENCES ecletica_grupos(cod_grupo),
    cod_linha   TEXT,
    vlr_unit    NUMERIC(10,2),
    synced_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ecletica_pagamentos (
    id                BIGSERIAL PRIMARY KEY,
    num_ticket        TEXT        NOT NULL,
    data_hora_fecha   TIMESTAMPTZ,
    vlr_total         NUMERIC(10,2),
    flag_canc         TEXT,
    origem_venda      TEXT,
    num_pessoas       INTEGER,
    flag_dely         TEXT,
    vlr_desc_tot      NUMERIC(10,2) DEFAULT 0,   -- desconto total do pedido
    vlr_serv          NUMERIC(10,2) DEFAULT 0,   -- taxa de serviço
    outras_taxas      NUMERIC(10,2) DEFAULT 0,
    id_pedido_externo TEXT          DEFAULT '',   -- id iFood/delivery externo
    cod_ctrl          TEXT,                       -- chave única real na Eclética
    data_hora_abre    TIMESTAMPTZ,                -- hora da venda; data_hora_fecha é a do fechamento
    nome_cliente      TEXT,
    synced_at         TIMESTAMPTZ DEFAULT now(),
    UNIQUE(num_ticket)
);
-- Saldo líquido = vlr_total + vlr_serv - vlr_desc_tot (NÃO subtrair outras_taxas)

CREATE TABLE IF NOT EXISTS ecletica_vendas (
    id               BIGSERIAL PRIMARY KEY,
    cod_ctrl         TEXT,
    num_ticket       TEXT,
    cod_item         TEXT,
    vlr_unit         NUMERIC(10,2),
    qtde             NUMERIC(10,3),
    data_hora        TIMESTAMPTZ,
    ordem_lancamento TEXT,
    synced_at        TIMESTAMPTZ DEFAULT now(),
    UNIQUE(cod_ctrl, num_ticket, cod_item, ordem_lancamento)
);

-- ============================================================
-- EVEREST — notas fiscais de compras (import único)
-- ============================================================

CREATE TABLE IF NOT EXISTS nf_recebimento (
    id             BIGSERIAL PRIMARY KEY,
    num_nf         TEXT        NOT NULL,
    fornecedor     TEXT,
    data_emissao   DATE,
    data_entrada   DATE,
    vlr_total      NUMERIC(10,2),
    loja           TEXT        DEFAULT 'analia_franco',
    importado_em   TIMESTAMPTZ DEFAULT now(),
    UNIQUE(num_nf, loja)
);

CREATE TABLE IF NOT EXISTS nf_itens (
    id              BIGSERIAL PRIMARY KEY,
    num_nf          TEXT        NOT NULL,
    descr_produto   TEXT,
    categoria       TEXT,
    qtde            NUMERIC(10,3),
    unidade         TEXT,
    vlr_unit        NUMERIC(10,4),
    vlr_total       NUMERIC(10,2),
    loja            TEXT        DEFAULT 'analia_franco'
);

-- ============================================================
-- ÍNDICES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_pag_data     ON ecletica_pagamentos(data_hora_fecha);
CREATE INDEX IF NOT EXISTS idx_pag_canc     ON ecletica_pagamentos(flag_canc);
CREATE INDEX IF NOT EXISTS idx_pag_origem   ON ecletica_pagamentos(origem_venda);
CREATE INDEX IF NOT EXISTS idx_venda_ticket ON ecletica_vendas(num_ticket);
CREATE INDEX IF NOT EXISTS idx_venda_item   ON ecletica_vendas(cod_item);
CREATE INDEX IF NOT EXISTS idx_venda_data   ON ecletica_vendas(data_hora);
CREATE INDEX IF NOT EXISTS idx_nfi_nf       ON nf_itens(num_nf);
CREATE INDEX IF NOT EXISTS idx_nfi_cat      ON nf_itens(categoria);
CREATE INDEX IF NOT EXISTS idx_nfr_entrada  ON nf_recebimento(data_entrada);
