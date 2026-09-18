"""
importar_btg_gsheet.py — Importa histórico do Google Sheet "Movimentações BTG" → Supabase
Lê o arquivo CSV exportado do Drive (já baixado pelo MCP).
Idempotente via upsert em id_externo.
"""

import os
import json
import base64
import csv
import io
import logging
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]
BATCH_SIZE   = 500

# Arquivo exportado pelo MCP — ajustar caminho se necessário
BTG_FILE = r"C:\Users\Usuario\.claude\projects\c--Users-Usuario-OneDrive-GiRafa-Code-Greenjoy\26b90887-c1a8-436b-89e3-8ddb67a3cc6e\tool-results\mcp-claude_ai_Google_Drive-download_file_content-1779143052568.txt"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def parse_date(s):
    s = s.strip()
    for fmt in ("%d/%m/%Y", "%d/%m/%y"):
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            pass
    return None


def parse_valor(s):
    s = s.strip().replace(".", "").replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def load_csv(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    raw = base64.b64decode(data["content"]).decode("utf-8", errors="replace")
    reader = csv.reader(io.StringIO(raw))
    rows = []
    header = None
    for row in reader:
        if not any(row):
            continue
        # Detectar linha de header
        if row[0].strip() == "Data" and "Valor" in row:
            header = [c.strip() for c in row]
            continue
        if header is None:
            continue
        if not row[0].strip() or not row[0][0].isdigit():
            continue
        rows.append(dict(zip(header, [c.strip() for c in row])))
    return rows


def to_supabase_row(r):
    return {
        "id_externo":             int(r.get("Identificador", 0)) if r.get("Identificador", "").isdigit() else None,
        "data_movimentacao":      parse_date(r.get("Data", "")),
        "tipo":                   r.get("Crédito/Débito") or r.get("Cr�ito/D�bito"),
        "valor":                  parse_valor(r.get("Valor", "")),
        "descricao":              r.get("Descrição") or r.get("Descri�￭o"),
        "mensagem":               r.get("Mensagem") or None,
        "doc_pagador_recebedor":  r.get("Documento Pagador/Recebedor") or None,
        "nome_pagador_recebedor": r.get("Nome Pagador/Recebedor") or None,
        "banco_codigo":           r.get("Banco Pagador/Recebedor") or None,
        "agencia":                r.get("Agência Pagador/Recebedor") or r.get("Ag￺ncia Pagador/Recebedor") or None,
        "conta":                  r.get("Conta Pagador/Recebedor") or None,
    }


def upsert_em_lotes(sb, rows):
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        sb.table("btg_movimentacoes").upsert(
            rows[i : i + BATCH_SIZE], on_conflict="id_externo"
        ).execute()
        total += len(rows[i : i + BATCH_SIZE])
    return total


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)

    log.info("Lendo arquivo BTG...")
    raw_rows = load_csv(BTG_FILE)
    log.info(f"{len(raw_rows)} transações encontradas")

    rows = [to_supabase_row(r) for r in raw_rows]
    rows = [r for r in rows if r["id_externo"] is not None and r["data_movimentacao"] is not None]
    # Deduplicar por id_externo (manter último)
    dedup = {r["id_externo"]: r for r in rows}
    rows = list(dedup.values())
    log.info(f"{len(rows)} linhas válidas para inserção (após dedup)")

    if rows:
        log.info(f"Exemplo: {rows[0]}")
        n = upsert_em_lotes(sb, rows)
        log.info(f"{n} registros upsertados em btg_movimentacoes")

    log.info("Importação BTG concluída.")


if __name__ == "__main__":
    main()
