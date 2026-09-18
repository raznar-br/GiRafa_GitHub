"""Regenera btg_classificacao_inferidos.sql a partir do banco.

Rodar depois de classificar chaves novas (as que aparecem em kpi_mapping_pendentes),
para o schema continuar reproduzível a partir do repositório.
"""

import os

from sql import run

DESTINO = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "btg_classificacao_inferidos.sql")

CABECALHO = """-- btg_classificacao_inferidos.sql
-- Pessoas físicas classificadas como Folha por heurística (nome sem sufixo
-- empresarial, 3-6 palavras) e revisadas com o Rafael em 15/08/2026.
-- Gerado a partir do banco para o schema ser reproduzível: sem este arquivo,
-- rodar btg_classificacao.sql num banco limpo perderia estas chaves e a folha
-- desabaria. Regenerar com database/dump_classificacao.py.

INSERT INTO btg_classificacao (chave, natureza, categoria_1, categoria_2, origem, observacao) VALUES
"""

RODAPE = """
ON CONFLICT (chave) DO UPDATE SET
  natureza = EXCLUDED.natureza, categoria_1 = EXCLUDED.categoria_1,
  categoria_2 = EXCLUDED.categoria_2, observacao = EXCLUDED.observacao;
"""


def esc(s):
    return (s or "").replace("'", "''")


def main():
    rows = run("""
        SELECT chave, natureza, categoria_1, categoria_2,
               COALESCE(observacao, '') AS obs
        FROM btg_classificacao WHERE origem = 'inferido' ORDER BY chave
    """, silencioso=True)

    linhas = [
        f"('{esc(r['chave'])}','{r['natureza']}','{esc(r['categoria_1'])}',"
        f"'{esc(r['categoria_2'])}','inferido','{esc(r['obs'])}')"
        for r in rows
    ]
    with open(DESTINO, "w", encoding="utf-8") as fh:
        fh.write(CABECALHO + ",\n".join(linhas) + RODAPE)
    print(f"{len(rows)} chaves -> {DESTINO}")


if __name__ == "__main__":
    main()
