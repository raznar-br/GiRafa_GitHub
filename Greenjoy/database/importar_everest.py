"""
importar_everest.py — Importa XLSXs do Everest -> Supabase
Operação única (ou re-import idempotente)
Rodar do diretório Greenjoy/database/
"""

import os
import sys
import logging
import pandas as pd
from dotenv import load_dotenv

load_dotenv()

from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]
LOJA         = "analia_franco"
BATCH_SIZE   = 500

XLSX_COMPRAS = os.path.join(os.path.dirname(__file__), "..", "dados", "Everest Compras_Jan-11052026.xlsx")
XLSX_AUDIT   = os.path.join(os.path.dirname(__file__), "..", "dados", "Everest_Audti Comrpas_01042026_11052026.xlsx")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def normalizar_decimal(serie):
    if serie.dtype == object:
        serie = serie.str.replace(".", "", regex=False).str.replace(",", ".", regex=False)
    return pd.to_numeric(serie, errors="coerce").fillna(0)


def upsert_em_lotes(sb, tabela, rows, on_conflict=None):
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        lote = rows[i : i + BATCH_SIZE]
        if on_conflict:
            sb.table(tabela).upsert(lote, on_conflict=on_conflict).execute()
        else:
            sb.table(tabela).upsert(lote).execute()
        total += len(lote)
    return total


def importar_nf_recebimento(sb, df):
    col_map = {
        "Número":           "num_nf",
        "Fantasia Emitente":"fornecedor",
        "D. Emissão":       "data_emissao",
        "D. Lançamento":    "data_entrada",
        "V. Total":         "vlr_total",
    }
    df = df[list(col_map.keys())].rename(columns=col_map).copy()
    df["loja"]       = LOJA
    df["vlr_total"]  = normalizar_decimal(df["vlr_total"])
    df["data_emissao"] = pd.to_datetime(df["data_emissao"], dayfirst=True, errors="coerce").dt.strftime("%Y-%m-%d")
    df["data_entrada"] = pd.to_datetime(df["data_entrada"], dayfirst=True, errors="coerce").dt.strftime("%Y-%m-%d")
    df["num_nf"]     = df["num_nf"].astype(str).str.strip()
    df = df.dropna(subset=["num_nf"]).where(pd.notnull(df), None)

    rows = df.to_dict("records")
    n = upsert_em_lotes(sb, "nf_recebimento", rows, on_conflict="num_nf,loja")
    log.info(f"nf_recebimento: {n} upserted")


def importar_nf_itens(sb, df):
    col_map = {
        "Nr. DANFE":             "num_nf",
        "Descrição do Item":     "descr_produto",
        "Descrição C. Gerencial":"categoria",
        "Q. Estoque":            "qtde",
        "Unidade Medida":        "unidade",
        "V. Convertido":         "vlr_unit",
        "V. Custo Total":        "vlr_total",
    }
    df = df[list(col_map.keys())].rename(columns=col_map).copy()
    df["loja"]     = LOJA
    df["num_nf"]   = df["num_nf"].astype(str).str.strip()
    for col in ["qtde", "vlr_unit", "vlr_total"]:
        df[col] = normalizar_decimal(df[col])
    df = df.dropna(subset=["num_nf"]).where(pd.notnull(df), None)

    rows = df.to_dict("records")
    n = upsert_em_lotes(sb, "nf_itens", rows)
    log.info(f"nf_itens: {n} upserted")


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)

    log.info(f"Lendo {XLSX_COMPRAS}")
    df_compras = pd.read_excel(XLSX_COMPRAS)
    log.info(f"  {len(df_compras)} linhas | Colunas: {list(df_compras.columns)}")

    log.info(f"Lendo {XLSX_AUDIT}")
    df_audit = pd.read_excel(XLSX_AUDIT)
    log.info(f"  {len(df_audit)} linhas | Colunas: {list(df_audit.columns)}")

    importar_nf_recebimento(sb, df_compras)
    importar_nf_itens(sb, df_audit)
    log.info("Importacao concluida.")


if __name__ == "__main__":
    main()
