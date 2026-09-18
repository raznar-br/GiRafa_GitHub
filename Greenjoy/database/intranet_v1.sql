-- Intranet do time (/bonus) — schema vigente
-- Aplicado via MCP: migrations intranet_v1 + intranet_v2_mural_only (só mural)

CREATE TABLE IF NOT EXISTS intranet_posts (
    id           serial PRIMARY KEY,
    titulo       text NOT NULL,
    corpo        text NOT NULL,
    fixado       boolean NOT NULL DEFAULT false,
    ativo        boolean NOT NULL DEFAULT true,
    autor        text,
    publicado_em timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE intranet_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY intranet_posts_select ON intranet_posts
    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY intranet_posts_write ON intranet_posts
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT ON intranet_posts TO anon;
GRANT ALL ON intranet_posts TO authenticated;
GRANT USAGE ON SEQUENCE intranet_posts_id_seq TO authenticated;

INSERT INTO intranet_posts (titulo, corpo, fixado, autor) VALUES
('Bem-vindos à intranet Greenjoy!',
 'Este é o nosso novo canal oficial. Aqui você acompanha o cofrinho do bônus e os avisos da gestão. Salve na tela inicial do celular!',
 true, 'Gestão');
