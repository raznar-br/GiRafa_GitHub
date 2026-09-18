-- acesso_views.sql
-- Fecha as views de gestão para o papel `anon`.
--
-- Problema: a chave anon vai no bundle público do site, e as 60 views kpi_*
-- estavam com GRANT para anon. Qualquer pessoa com o endereço do dashboard
-- conseguia ler faturamento, DRE, margem e — pior — a folha com nome e valor
-- pago de 131 pessoas. O login de e-mail e senha protegia a tela, não os dados.
--
-- Views são SECURITY DEFINER por padrão no Postgres, então o RLS das tabelas
-- base (que está ligado e sem policy) não bloqueia leitura via view. Só o GRANT
-- resolve.
--
-- ATENÇÃO — três páginas rodam FORA do AuthGate (ver __root.tsx): /desperdicio,
-- /bonus e /bonus-gerente. Elas usam a chave anon e precisam continuar lendo o
-- que consomem, senão o estoquista e a equipe perdem acesso. A lista PUBLICAS
-- abaixo é exatamente o que essas telas usam — não reduzir sem checar o código.

DO $$
DECLARE
    -- consumidas pelas páginas sem login; manter abertas
    publicas TEXT[] := ARRAY[
        'ref_custo_produto', 'registro_desperdicio',
        'bonus_config', 'bonus_multiplicadores', 'bonus_gerente_mensal',
        'intranet_posts',
        'kpi_bonus_diario', 'kpi_bonus_mensal', 'kpi_bonus_semanal',
        'kpi_cmv_semanal', 'kpi_compras_mensal', 'kpi_desperdicio_mensal',
        'kpi_faturamento_diario', 'kpi_pedidos_por_hora', 'kpi_ticket_por_canal'
    ];
    v RECORD;
BEGIN
    FOR v IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('v', 'm')
          AND NOT (c.relname = ANY(publicas))
    LOOP
        EXECUTE format('REVOKE SELECT ON public.%I FROM anon', v.relname);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v.relname);
    END LOOP;
END $$;

-- as tabelas de auditoria também só interessam a quem está logado
REVOKE SELECT ON auditoria_qualinut, auditoria_qualinut_categoria,
                 auditoria_qualinut_itens, qualinut_acoes FROM anon;
GRANT SELECT ON auditoria_qualinut, auditoria_qualinut_categoria,
                auditoria_qualinut_itens, qualinut_acoes TO authenticated;

-- metas: leitura passa a exigir sessão (a página /metas está atrás do AuthGate)
REVOKE SELECT ON metas FROM anon;
GRANT SELECT ON metas TO authenticated;

DROP POLICY IF EXISTS metas_read ON metas;
CREATE POLICY metas_read ON metas FOR SELECT TO authenticated USING (true);
