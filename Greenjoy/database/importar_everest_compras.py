"""
importar_everest_compras.py — Importa XLSXs de Everest - compras/ → Supabase
Idempotente: apaga itens do mês antes de reinserir.
Rodar do diretório Greenjoy/database/
"""

import os
import glob
import logging
import pandas as pd
from datetime import date
from dateutil.relativedelta import relativedelta
from dotenv import load_dotenv

load_dotenv()
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]
LOJA         = "analia_franco"
BATCH_SIZE   = 500
PASTA        = os.path.join(os.path.dirname(__file__), "..", "Everest - compras")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def normalizar_decimal(serie):
    if serie.dtype == object:
        serie = serie.str.replace(".", "", regex=False).str.replace(",", ".", regex=False)
    return pd.to_numeric(serie, errors="coerce").fillna(0)


def insert_em_lotes(sb, tabela, rows):
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        sb.table(tabela).insert(rows[i : i + BATCH_SIZE]).execute()
        total += len(rows[i : i + BATCH_SIZE])
    return total


def upsert_em_lotes(sb, tabela, rows, on_conflict):
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        sb.table(tabela).upsert(rows[i : i + BATCH_SIZE], on_conflict=on_conflict).execute()
        total += len(rows[i : i + BATCH_SIZE])
    return total


def construir_data_lancamento(df):
    return pd.to_datetime(
        df["Ano Lançamento"].astype(str)
        + "-"
        + df["Mês Lançamento"].astype(str).str.zfill(2)
        + "-"
        + df["Dia Lançamento"].astype(str).str.zfill(2),
        errors="coerce",
    ).dt.date


def importar_arquivo(sb, xlsx_path):
    log.info(f"Lendo {xlsx_path}")
    df = pd.read_excel(xlsx_path)
    log.info(f"  {len(df)} linhas")

    df_cmv = df[df["Calcula CMV"] == "Sim"].copy()
    log.info(f"  {len(df_cmv)} itens com Calcula CMV=Sim")
    if df_cmv.empty:
        log.warning("  Nenhum item de CMV encontrado, pulando arquivo.")
        return

    df_cmv["_data_lanc"] = construir_data_lancamento(df_cmv)
    df_cmv = df_cmv.dropna(subset=["_data_lanc"])

    meses = sorted({(d.year, d.month) for d in df_cmv["_data_lanc"]})
    log.info(f"  Meses cobertos: {meses}")

    for year, month in meses:
        mes_inicio = date(year, month, 1)
        mes_fim    = mes_inicio + relativedelta(months=1)
        sb.table("nf_itens").delete()\
            .eq("loja", LOJA)\
            .gte("data_lancamento", mes_inicio.isoformat())\
            .lt("data_lancamento",  mes_fim.isoformat())\
            .execute()
        log.info(f"  Deletados itens existentes de {year}-{month:02d}")

    df_cmv["num_nf"]          = df_cmv["Nr. DANFE"].astype(str).str.strip()
    df_cmv["vlr_total"]       = normalizar_decimal(df_cmv["V. Custo Total"])
    df_cmv["vlr_unit"]        = normalizar_decimal(df_cmv["V. Convertido"])
    df_cmv["qtde"]            = normalizar_decimal(df_cmv["Q. Estoque"])
    df_cmv["data_lancamento"] = df_cmv["_data_lanc"].astype(str)

    cols_itens = {
        "num_nf":          "num_nf",
        "Descrição do Item":      "descr_produto",
        "Descrição C. Gerencial": "categoria",
        "qtde":            "qtde",
        "Unidade Medida":  "unidade",
        "vlr_unit":        "vlr_unit",
        "vlr_total":       "vlr_total",
        "data_lancamento": "data_lancamento",
        "Fantasia Fornecedor": "fornecedor",
    }
    df_itens = df_cmv[list(cols_itens.keys())].rename(columns=cols_itens).copy()
    df_itens["loja"] = LOJA
    df_itens = df_itens.dropna(subset=["num_nf"])
    rows_itens = [{k: (None if (isinstance(v, float) and pd.isna(v)) else v)
                   for k, v in r.items()}
                  for r in df_itens.to_dict("records")]

    n_itens = insert_em_lotes(sb, "nf_itens", rows_itens)
    log.info(f"  nf_itens: {n_itens} inseridos")

    # nf_recebimento — agrega por NF (uma linha por DANFE)
    df["_data_lanc"] = construir_data_lancamento(df)
    df_nf = df.sort_values("_data_lanc").drop_duplicates(subset=["Nr. DANFE"], keep="last").copy()
    df_nf["num_nf"]      = df_nf["Nr. DANFE"].astype(str).str.strip()
    df_nf["vlr_total"]   = normalizar_decimal(df_nf["V. Total DANFE"])
    df_nf["data_emissao"] = pd.to_datetime(df_nf["D. Emissão"], errors="coerce").dt.strftime("%Y-%m-%d")
    df_nf["data_entrada"] = df_nf["_data_lanc"].apply(
        lambda d: d.strftime("%Y-%m-%d") if pd.notna(d) else None
    )
    rows_nf = [
        {
            "num_nf":      r["num_nf"],
            "fornecedor":  r["Fantasia Fornecedor"],
            "data_emissao": r["data_emissao"],
            "data_entrada": r["data_entrada"],
            "vlr_total":   r["vlr_total"],
            "loja":        LOJA,
        }
        for _, r in df_nf.iterrows()
        if r["num_nf"]
    ]
    n_nf = upsert_em_lotes(sb, "nf_recebimento", rows_nf, on_conflict="num_nf,loja")
    log.info(f"  nf_recebimento: {n_nf} upserted")


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)
    arquivos = sorted(f for f in glob.glob(os.path.join(PASTA, "*.xlsx"))
                      if not os.path.basename(f).startswith("~$"))
    if not arquivos:
        log.error(f"Nenhum .xlsx em {PASTA}")
        return
    log.info(f"{len(arquivos)} arquivo(s) encontrado(s)")
    for arq in arquivos:
        importar_arquivo(sb, arq)
    log.info("Importação concluída.")


if __name__ == "__main__":
    main()
