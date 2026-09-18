"""Detecta views que existem no banco mas não têm definição em nenhum .sql, e as
dumpa para views_legado_dump.sql — para o schema ser realmente reproduzível.

Rodar depois de criar view nova fora dos arquivos versionados (idealmente, não faça
isso: crie no arquivo certo e rode aplicar_views.py).
"""

import glob
import os
import re

from sql import run

BASE = os.path.dirname(os.path.abspath(__file__))
DESTINO = os.path.join(BASE, "views_legado_dump.sql")
IGNORAR = {"views_legado_dump.sql"}


def versionadas():
    nomes = set()
    for f in glob.glob(os.path.join(BASE, "*.sql")):
        if os.path.basename(f) in IGNORAR:
            continue
        texto = open(f, encoding="utf-8").read()
        nomes |= set(re.findall(r"CREATE (?:OR REPLACE )?VIEW\s+(\w+)", texto))
        nomes |= set(re.findall(r"CREATE MATERIALIZED VIEW\s+(\w+)", texto))
    return nomes


def main():
    no_banco = {r["viewname"]: r["definition"] for r in run("""
        SELECT viewname, definition FROM pg_views
        WHERE schemaname = 'public' ORDER BY viewname
    """, silencioso=True)}

    faltantes = sorted(set(no_banco) - versionadas())
    if not faltantes:
        print("nenhuma view faltante — schema completo nos arquivos")
        if os.path.exists(DESTINO):
            os.remove(DESTINO)
        return

    partes = [
        "-- views_legado_dump.sql — GERADO AUTOMATICAMENTE por dump_views_faltantes.py\n"
        "-- Views que existem no banco e não foram reescritas na revisão de Ago/2026.\n"
        "-- Estão aqui para o schema ser reproduzível do zero. Ao mexer em alguma,\n"
        "-- mova a definição para o arquivo temático correspondente e rode o dump de novo.\n"
    ]
    for nome in faltantes:
        partes.append(f"\nCREATE OR REPLACE VIEW {nome} AS\n{no_banco[nome].strip()}\n"
                      f"GRANT SELECT ON {nome} TO anon, authenticated;\n")

    with open(DESTINO, "w", encoding="utf-8") as fh:
        fh.write("".join(partes))
    print(f"{len(faltantes)} views dumpadas -> {os.path.basename(DESTINO)}")
    for n in faltantes:
        print(f"  {n}")


if __name__ == "__main__":
    main()
