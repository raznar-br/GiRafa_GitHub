"""
sync_ecletica.py — Sync incremental Eclética MySQL -> Supabase
Rodar diariamente via Agendador de Tarefas Windows
"""

import os
import sys
import logging
from datetime import datetime, timedelta
from dotenv import load_dotenv

load_dotenv()

import mysql.connector
from supabase import create_client

MYSQL_HOST     = os.environ["ECLETICA_HOST"]
MYSQL_PORT     = int(os.environ.get("ECLETICA_PORT", 3306))
MYSQL_USER     = os.environ["ECLETICA_USER"]
MYSQL_PASSWORD = os.environ["ECLETICA_PASSWORD"]
MYSQL_DB       = os.environ["ECLETICA_DB"]

SUPABASE_URL   = os.environ["SUPABASE_URL"]
SUPABASE_KEY   = os.environ["SUPABASE_SERVICE_KEY"]

LOOKBACK_DAYS  = int(os.environ.get("SYNC_LOOKBACK_DAYS", 2))
BATCH_SIZE     = 1000

log_file = os.path.join(os.path.dirname(__file__), "sync_ecletica.log")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(log_file, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger(__name__)


def conectar_mysql():
    return mysql.connector.connect(
        host=MYSQL_HOST, port=MYSQL_PORT,
        user=MYSQL_USER, password=MYSQL_PASSWORD,
        database=MYSQL_DB, charset="utf8mb4",
        connection_timeout=10,
    )


def upsert_em_lotes(sb, tabela, rows, on_conflict):
    chaves = on_conflict.split(",")
    unicos = {tuple(r[c] for c in chaves): r for r in rows}
    if len(unicos) < len(rows):
        log.warning(f"{tabela}: {len(rows) - len(unicos)} chave(s) duplicada(s) na origem, mantida a ultima")
    rows = list(unicos.values())
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        lote = rows[i : i + BATCH_SIZE]
        sb.table(tabela).upsert(lote, on_conflict=on_conflict).execute()
        total += len(lote)
    return total


def to_iso(val):
    return val.isoformat() if hasattr(val, "isoformat") else val


def sync_grupos(cur, sb):
    cur.execute("SELECT CAST(cod_grupo AS CHAR) AS cod_grupo, descr_grupo FROM grupos")
    rows = [{"cod_grupo": r[0], "descr_grupo": r[1]} for r in cur.fetchall()]
    if rows:
        n = upsert_em_lotes(sb, "ecletica_grupos", rows, "cod_grupo")
        log.info(f"grupos: {n} upserted")


def sync_produtos(cur, sb):
    cur.execute("""
        SELECT CAST(cod_item AS CHAR), descr_item,
               CAST(cod_grupo AS CHAR), CAST(cod_linha AS CHAR),
               vlr_unit
        FROM produtos
    """)
    rows = [
        {"cod_item": r[0], "descr_item": r[1], "cod_grupo": r[2],
         "cod_linha": r[3], "vlr_unit": float(r[4]) if r[4] else None}
        for r in cur.fetchall()
    ]
    if rows:
        n = upsert_em_lotes(sb, "ecletica_produtos", rows, "cod_item")
        log.info(f"produtos: {n} upserted")


def sync_pagamentos(cur, sb, desde):
    cur.execute("""
        SELECT CAST(num_ticket AS CHAR), data_hora_fecha,
               vlr_total, flag_canc, origem_venda,
               num_pessoas, flag_dely,
               vlr_desc_tot, vlr_serv, outras_taxas,
               id_pedido_externo,
               CAST(cod_ctrl AS CHAR), data_hora_abre, nome_cliente
        FROM pagamentos
        WHERE data_hora_fecha >= %s
        ORDER BY data_hora_fecha
    """, (desde,))
    rows = [
        {
            "num_ticket":         r[0],
            "data_hora_fecha":    to_iso(r[1]),
            "vlr_total":          float(r[2]) if r[2] is not None else None,
            "flag_canc":          r[3],
            "origem_venda":       r[4],
            "num_pessoas":        r[5],
            "flag_dely":          r[6],
            "vlr_desc_tot":       float(r[7]) if r[7] is not None else 0.0,
            "vlr_serv":           float(r[8]) if r[8] is not None else 0.0,
            "outras_taxas":       float(r[9]) if r[9] is not None else 0.0,
            "id_pedido_externo":  r[10] or "",
            "cod_ctrl":           r[11],
            "data_hora_abre":     to_iso(r[12]),
            "nome_cliente":       (r[13] or "").strip(),
        }
        for r in cur.fetchall()
    ]
    if rows:
        n = upsert_em_lotes(sb, "ecletica_pagamentos", rows, "num_ticket")
        log.info(f"pagamentos: {n} upserted desde {desde.date()}")
    else:
        log.info(f"pagamentos: nenhum registro desde {desde.date()}")


def sync_vendas(cur, sb, desde):
    cur.execute("""
        SELECT CAST(cod_ctrl AS CHAR), CAST(num_ticket AS CHAR),
               CAST(cod_item AS CHAR), vlr_unit, qtde, data_hora,
               CAST(ordem_lancamento AS CHAR)
        FROM vendas
        WHERE data_hora >= %s
    """, (desde,))
    rows = [
        {
            "cod_ctrl":         r[0],
            "num_ticket":       r[1],
            "cod_item":         r[2],
            "vlr_unit":         float(r[3]) if r[3] is not None else None,
            "qtde":             float(r[4]) if r[4] is not None else None,
            "data_hora":        to_iso(r[5]),
            "ordem_lancamento": r[6],
        }
        for r in cur.fetchall()
    ]
    if rows:
        n = upsert_em_lotes(sb, "ecletica_vendas", rows, "cod_ctrl,num_ticket,cod_item,ordem_lancamento")
        log.info(f"vendas: {n} upserted desde {desde.date()}")
    else:
        log.info(f"vendas: nenhum registro desde {desde.date()}")


def refresh_agregados():
    """Atualiza mv_produto_dia — as views de curva ABC e top produtos leem dela."""
    try:
        from sql import run
        run("SET statement_timeout='600s'; REFRESH MATERIALIZED VIEW CONCURRENTLY mv_produto_dia;",
            silencioso=True)
        log.info("mv_produto_dia atualizada")
    except Exception as e:
        log.error(f"falha ao atualizar mv_produto_dia: {e}")


def main():
    log.info("=== Inicio sync Ecletica -> Supabase ===")
    desde = datetime.now() - timedelta(days=LOOKBACK_DAYS)

    try:
        conn  = conectar_mysql()
        sb    = create_client(SUPABASE_URL, SUPABASE_KEY)
        log.info("Conexoes OK")
    except Exception as e:
        log.error(f"FALHA NA CONEXAO: {e}")
        sys.exit(1)

    try:
        cur = conn.cursor()
        sync_grupos(cur, sb)
        sync_produtos(cur, sb)
        sync_pagamentos(cur, sb, desde)
        sync_vendas(cur, sb, desde)
        refresh_agregados()
        log.info("=== Sync concluido com sucesso ===")
    except Exception as e:
        log.error(f"ERRO DURANTE SYNC: {e}", exc_info=True)
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
