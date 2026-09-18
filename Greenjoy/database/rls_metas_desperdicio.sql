-- rls_metas_desperdicio.sql
-- Fecha a escrita anônima em `metas` sem quebrar as páginas standalone.
--
-- Contexto: /desperdicio, /bonus e /bonus-gerente rodam fora do AuthGate, com a
-- chave anon que vai no bundle do frontend. As duas tabelas estavam sem RLS e com
-- INSERT/UPDATE/DELETE liberados para anon — ou seja, qualquer pessoa com a chave
-- podia alterar a meta de faturamento que o painel dos sócios exibe.
--
-- `metas`: leitura pública, escrita só para quem está logado (/metas fica atrás do
--   AuthGate, então continua funcionando).
-- `registro_desperdicio`: o estoquista precisa inserir e corrigir pelo celular sem
--   login, então SELECT/INSERT/DELETE seguem abertos. RLS fica ligado para que
--   restringir depois seja só trocar a policy.

ALTER TABLE metas                ENABLE ROW LEVEL SECURITY;
ALTER TABLE registro_desperdicio ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS metas_read   ON metas;
DROP POLICY IF EXISTS metas_write  ON metas;
DROP POLICY IF EXISTS metas_update ON metas;

CREATE POLICY metas_read   ON metas FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY metas_write  ON metas FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY metas_update ON metas FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- TRUNCATE não é filtrado por RLS: precisa ser revogado no grant.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON metas FROM anon;
REVOKE TRUNCATE ON registro_desperdicio FROM anon;
GRANT SELECT ON metas TO anon, authenticated;
GRANT INSERT, UPDATE ON metas TO authenticated;

DROP POLICY IF EXISTS desp_read   ON registro_desperdicio;
DROP POLICY IF EXISTS desp_insert ON registro_desperdicio;
DROP POLICY IF EXISTS desp_delete ON registro_desperdicio;

CREATE POLICY desp_read   ON registro_desperdicio
    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY desp_insert ON registro_desperdicio
    FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY desp_delete ON registro_desperdicio
    FOR DELETE TO anon, authenticated USING (true);
