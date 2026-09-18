"""Aplica todo o schema de views na ordem de dependência.

Cada view tem UMA definição, num único arquivo. Rodar este script é sempre seguro
e reproduz o schema do zero (os dados vêm dos scripts de sync e import).

    python aplicar_views.py            # tudo
    python aplicar_views.py a.sql b.sql # só alguns

views_legado_dump.sql traz as views que não foram reescritas na revisão de Ago/2026;
é gerado por dump_views_faltantes.py, que também acusa se alguém criar view fora
dos arquivos versionados.
"""

import os
import sys
import time

from sql import run

BASE = os.path.dirname(os.path.abspath(__file__))

# a ordem importa: funções → tabelas → camada de classificação → views que a consomem
ARQUIVOS = [
    "funcoes.sql",                      # hoje_br(), brl()
    "schema_auditoria.sql",             # tabelas do Qualinut
    "btg_classificacao.sql",            # de-para manual do extrato
    "btg_classificacao_inferidos.sql",  # 131 pessoas físicas → Folha
    "btg_classificado.sql",             # camada única + cobertura
    "mv_produto_dia.sql",               # agregado dia x produto x canal
    "views_dashboard.sql",              # faturamento diário, ticket por canal, CMV proxy
    "views_financeiro_btg.sql",         # faturamento, CMV, prime cost, DRE
    "views_cmv_acionavel.sql",          # rolling, desvios, ações
    "views_socios_v2.sql",              # painel, ponte, canal, dias suspeitos
    "views_cmv_acompanhamento.sql",     # orcamento de compras semana/mes, historico, alertas
    "views_fechamento.sql",             # vendido no dia x fechado no dia, por canal
    "views_produtos.sql",               # curva ABC, top produtos
    "views_qualinut.sql",               # auditoria de qualidade
    "views_premio.sql",                 # premiação Q4/2026: placar, custo e previsão
    "views_legado_dump.sql",            # views ainda não reescritas (gerado)
    "rls_metas_desperdicio.sql",        # fecha escrita anônima em metas
]


def main():
    alvo = sys.argv[1:] or ARQUIVOS
    for nome in alvo:
        caminho = os.path.join(BASE, nome)
        if not os.path.exists(caminho):
            print(f"  {nome}: NAO ENCONTRADO")
            continue
        with open(caminho, encoding="utf-8") as fh:
            sql = fh.read()
        t = time.time()
        run("SET statement_timeout='600s';\n" + sql, silencioso=True)
        print(f"  {nome}: ok ({time.time() - t:.1f}s)")
    print("schema aplicado")


if __name__ == "__main__":
    main()
