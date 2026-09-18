-- btg_classificacao.sql
-- Camada única de classificação do extrato BTG.
--
-- Problema que resolve: cada view de CMV/DRE repetia seu próprio JOIN com
-- jafeb_despesas_mapping, com regras divergentes (uma usava COALESCE(nome, descricao),
-- outra só nome), e nenhuma cobria impostos, folha por PF ou transferências internas.
-- Resultado: 49% dos débitos caíam em "Não mapeado" e a margem operacional aparecia
-- como 46% no dashboard dos sócios.
--
-- Precedência: btg_classificacao (manual) > jafeb_despesas_mapping > 'Não classificado'.
-- Naturezas padronizadas: Custo, Despesa, Folha, Imposto, CAPEX, Transferência.

CREATE TABLE IF NOT EXISTS btg_classificacao (
    chave       TEXT PRIMARY KEY,
    natureza    TEXT NOT NULL CHECK (natureza IN
                 ('Custo','Despesa','Folha','Imposto','CAPEX','Transferência')),
    categoria_1 TEXT,
    categoria_2 TEXT,
    origem      TEXT NOT NULL DEFAULT 'manual',
    observacao  TEXT,
    criado_em   TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE btg_classificacao IS
  'De-para do extrato BTG que complementa jafeb_despesas_mapping. origem=inferido '
  'marca linhas geradas por heurística (pessoa física -> Folha) que valem revisão.';

-- ============================================================
-- Transferências internas — não compõem DRE
-- ============================================================
INSERT INTO btg_classificacao (chave, natureza, categoria_1, categoria_2, observacao) VALUES
 ('DÉBITO NA CONTA CORRENTE',   'Transferência', 'Conta remunerada', 'Aplicação',  'Aplicação automática BTG'),
 ('RESGATE CONTA REMUNERADA',   'Transferência', 'Conta remunerada', 'Resgate',    'Resgate automático BTG'),
 ('BANCO INTER SA',             'Transferência', 'Conta própria',    'Transferência', 'Transferência entre contas da empresa'),
 ('BANCO DO BRASIL S.A. - SETOR PUBLICO RJ', 'Transferência', 'Conta própria', 'Transferência', NULL),
 ('JAFEB EMILIA MARENGO COMERCIO DE ALIMENTOS LTDA', 'Transferência', 'Intercompany', 'Matriz', 'Repasse para a holding')
ON CONFLICT (chave) DO UPDATE SET
  natureza = EXCLUDED.natureza, categoria_1 = EXCLUDED.categoria_1,
  categoria_2 = EXCLUDED.categoria_2, observacao = EXCLUDED.observacao;

-- ============================================================
-- Impostos e encargos
-- ============================================================
INSERT INTO btg_classificacao (chave, natureza, categoria_1, categoria_2, observacao) VALUES
 ('DARF/DARF-SIMPLES 0385',            'Imposto', 'Federal',   'Simples Nacional', NULL),
 ('SEFAZ/SP-AMBIENTEPAG',              'Imposto', 'Estadual',  'ICMS',             NULL),
 ('SECRETARIA DA FAZENDA E PLANEJAMENTO','Imposto','Estadual',  'ICMS',             NULL),
 ('PREF MUN SAO PAULO 02',             'Imposto', 'Municipal', 'ISS/Taxas',        NULL),
 ('CAIXA ECONOMICA FEDERAL',           'Imposto', 'Encargos',  'FGTS',             'Recolhimento FGTS')
ON CONFLICT (chave) DO UPDATE SET
  natureza = EXCLUDED.natureza, categoria_1 = EXCLUDED.categoria_1,
  categoria_2 = EXCLUDED.categoria_2, observacao = EXCLUDED.observacao;

-- ============================================================
-- Despesas operacionais PJ
-- ============================================================
INSERT INTO btg_classificacao (chave, natureza, categoria_1, categoria_2, observacao) VALUES
 ('COMPANHIA DE SANEAMENTO BASICO DO ESTADO DE SAO PAULO SABESP', 'Despesa', 'Utilities', 'Água', NULL),
 ('VR BENEFICIOS E SERVICOS DE PROCESSAMENTO S.A', 'Folha',   'Benefícios',  'Vale refeição/transporte', NULL),
 ('FATOR RH AGENCIA DE EMPREGOS LTDA',   'Folha',   'Terceiros',   'Agência de emprego', NULL),
 ('FATOR RH AGENCIA EMPREGOS LTDA',      'Folha',   'Terceiros',   'Agência de emprego', NULL),
 ('RB CODE COMERC SERVIÇOS PRODU SOLUCOES EM TI LTDA', 'Despesa', 'TI', 'Sistemas', NULL),
 ('ABUD, MARQUES E PIGA SOCIEDADE DE ADVOGADAS', 'Despesa', 'Jurídico', 'Advocacia', NULL),
 ('TUICIAL INDUSTRIA GRAFICA E EDITORA S A', 'Despesa', 'Marketing', 'Gráfica', NULL),
 ('CONTATO SEG P R EMPRESARIAIS',        'Despesa', 'Segurança',   'Vigilância', NULL),
 ('RNX FIDC MULTISSETORIAL LP',          'Despesa', 'Financeiro',  'Antecipação/factoring', NULL),
 ('SCHIPPER CONS INTERN COMERCI',        'Custo',   'SCHIPPER',    'Outros', 'Fornecedor — revisar categoria'),
 ('IVO TSI KOMANDO',                     'Despesa', 'TI',          'Sistemas', NULL)
ON CONFLICT (chave) DO UPDATE SET
  natureza = EXCLUDED.natureza, categoria_1 = EXCLUDED.categoria_1,
  categoria_2 = EXCLUDED.categoria_2, observacao = EXCLUDED.observacao;
