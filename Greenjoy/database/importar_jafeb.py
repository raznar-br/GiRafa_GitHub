"""
importar_jafeb.py — Importa Modelo JAFEB.xlsx → Supabase
Tabelas: jafeb_despesas_mapping, dre_competencia, dre_caixa
Idempotente: re-import seguro a qualquer momento.
Rodar do diretório Greenjoy/database/
"""

import os
import logging
from datetime import date

import pandas as pd
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]
BATCH_SIZE   = 500

XLSX_PATH = os.path.join(os.path.dirname(__file__), "..", "docs", "Modelo JAFEB.xlsx")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def normalizar_periodo(raw) -> date | None:
    """Converte 202111 ou 20221 (formato inconsistente da planilha) para date."""
    try:
        s = str(int(float(raw)))
        if len(s) == 5:   # ex: 20221 → 2022-01
            return date(int(s[:4]), int(s[4:]), 1)
        if len(s) == 6:   # ex: 202111 → 2021-11
            return date(int(s[:4]), int(s[4:]), 1)
    except Exception:
        pass
    return None


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


def importar_mapping(sb, xl):
    """Aba 'Modelo JAFEB': de-para descricao → natureza → categoria_1 → categoria_2."""
    df = xl.parse("Modelo JAFEB", header=0, usecols="B:E")
    df.columns = ["descricao", "natureza", "categoria_1", "categoria_2"]
    df = df.dropna(subset=["descricao"])
    df["descricao"] = df["descricao"].astype(str).str.strip()
    df = df.where(pd.notnull(df), None)

    # Mapping é dado de referência: limpa e reimporta
    sb.table("jafeb_despesas_mapping").delete().gte("id", 1).execute()
    rows = df.to_dict("records")
    n = upsert_em_lotes(sb, "jafeb_despesas_mapping", rows)
    log.info(f"jafeb_despesas_mapping: {n} inseridos")


def importar_dre(sb, xl, aba, tabela):
    """
    Abas DRE (wide → long).
    Estrutura da planilha:
      Linha 2 (idx 1): códigos de período (202111, 20221, ...)
      Linhas 1-5 (idx 0-4): cabeçalhos
      Linha 7+ (idx 6+): dados — col D (idx 3) = linha_dre, col E (idx 4) = categoria
      Cols a partir do idx 7: valores por período
    """
    df_raw = xl.parse(aba, header=None)

    # Mapa col_index → date a partir da linha de períodos (idx 1)
    periodo_row = df_raw.iloc[1]
    period_cols: dict[int, date] = {}
    for col_idx in range(7, len(periodo_row)):
        d = normalizar_periodo(periodo_row.iloc[col_idx])
        if d:
            period_cols[col_idx] = d

    log.info(f"{aba}: {len(period_cols)} períodos encontrados "
             f"({min(period_cols.values())} → {max(period_cols.values())})")

    data_df = df_raw.iloc[6:].reset_index(drop=True)

    rows = []
    for _, row in data_df.iterrows():
        linha = row.iloc[3]
        if pd.isna(linha) or str(linha).strip() == "":
            continue
        linha = str(linha).strip()
        cat_raw = row.iloc[4]
        cat = str(cat_raw).strip() if pd.notna(cat_raw) else ""

        for col_idx, periodo in period_cols.items():
            valor = row.iloc[col_idx]
            if pd.isna(valor):
                continue
            try:
                valor = round(float(valor), 2)
            except (ValueError, TypeError):
                continue
            rows.append({
                "periodo":   periodo.isoformat(),
                "linha_dre": linha,
                "categoria": cat,
                "valor":     valor,
            })

    # Deduplica por chave única antes de enviar
    seen = {}
    for r in rows:
        key = (r["periodo"], r["linha_dre"], r["categoria"])
        seen[key] = r
    rows_dedup = list(seen.values())
    log.info(f"{tabela}: {len(rows)} registros → {len(rows_dedup)} após deduplicação")

    n = upsert_em_lotes(sb, tabela, rows_dedup, on_conflict="periodo,linha_dre,categoria")
    log.info(f"{tabela}: {n} upserted")


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)
    log.info(f"Lendo {XLSX_PATH}")

    xl = pd.ExcelFile(XLSX_PATH, engine="openpyxl")
    log.info(f"Abas encontradas: {xl.sheet_names}")

    importar_mapping(sb, xl)
    importar_dre(sb, xl, "DRE Mensal - Competência", "dre_competencia")
    importar_dre(sb, xl, "DRE Mensal - Caixa", "dre_caixa")

    log.info("Importação JAFEB concluída.")


if __name__ == "__main__":
    main()
