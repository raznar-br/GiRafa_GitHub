"""
sync_btg.py — Refresh token BTG → extrato → Supabase btg_movimentacoes
Idempotente via upsert em id_externo.
Rodar do diretório Greenjoy/database/
Pré-requisito: rodar setup_btg_auth.py uma vez para gerar o refresh token.
"""

import os
import requests
import logging
from datetime import date, timedelta
from dotenv import load_dotenv

load_dotenv()
from supabase import create_client

SUPABASE_URL  = os.environ["SUPABASE_URL"]
SUPABASE_KEY  = os.environ["SUPABASE_SERVICE_KEY"]
BTG_CLIENT_ID     = os.environ["BTG_CLIENT_ID"]
BTG_CLIENT_SECRET = os.environ["BTG_CLIENT_SECRET"]

BTG_TOKEN_URL = "https://id.btgpactual.com/oauth2/token"
BTG_API_BASE  = "https://api.empresas.btgpactual.com"
REDIRECT_URI  = "https://xlpcnkjqitdimcpwnkcv.supabase.co/functions/v1/btg-callback"
LOOKBACK_DAYS = int(os.getenv("BTG_LOOKBACK_DAYS", "7"))
BATCH_SIZE    = 500

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def get_refresh_token(sb):
    res = sb.table("btg_config").select("value").eq("key", "btg_refresh_token").single().execute()
    if not res.data:
        raise RuntimeError("Refresh token não encontrado. Rode setup_btg_auth.py primeiro.")
    return res.data["value"]


def refresh_access_token(refresh_token):
    r = requests.post(BTG_TOKEN_URL, data={
        "grant_type":    "refresh_token",
        "refresh_token": refresh_token,
        "client_id":     BTG_CLIENT_ID,
        "client_secret": BTG_CLIENT_SECRET,
        "redirect_uri":  REDIRECT_URI,
    })
    r.raise_for_status()
    return r.json()


def save_tokens(sb, tokens):
    sb.table("btg_config").upsert([
        {"key": "btg_refresh_token", "value": tokens["refresh_token"]},
        {"key": "btg_access_token",  "value": tokens["access_token"]},
    ], on_conflict="key").execute()


def get_accounts(token):
    r = requests.get(
        f"{BTG_API_BASE}/v2/accounts",
        headers={"Authorization": f"Bearer {token}"},
    )
    r.raise_for_status()
    data = r.json()
    return data.get("accounts") or data.get("data") or data


def get_statement(token, account_id, start: date, end: date):
    r = requests.get(
        f"{BTG_API_BASE}/v2/accounts/{account_id}/statement",
        headers={"Authorization": f"Bearer {token}"},
        params={"startDate": start.isoformat(), "endDate": end.isoformat()},
    )
    r.raise_for_status()
    data = r.json()
    return data.get("transactions") or data.get("data") or data


def upsert_em_lotes(sb, rows):
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        sb.table("btg_movimentacoes").upsert(
            rows[i : i + BATCH_SIZE], on_conflict="id_externo"
        ).execute()
        total += len(rows[i : i + BATCH_SIZE])
    return total


def parse_row(t):
    return {
        "id_externo":             t.get("id") or t.get("identifier") or t.get("transactionId"),
        "data_movimentacao":      t.get("date") or t.get("transactionDate"),
        "tipo":                   t.get("type") or t.get("creditDebit"),
        "valor":                  t.get("amount") or t.get("value"),
        "descricao":              t.get("description"),
        "mensagem":               t.get("message"),
        "doc_pagador_recebedor":  t.get("counterpartDocument") or t.get("payerReceiverDocument"),
        "nome_pagador_recebedor": t.get("counterpartName") or t.get("payerReceiverName"),
        "banco_codigo":           t.get("counterpartBank") or t.get("payerReceiverBank"),
        "agencia":                t.get("counterpartBranch") or t.get("payerReceiverBranch"),
        "conta":                  t.get("counterpartAccount") or t.get("payerReceiverAccount"),
    }


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)

    refresh_token = get_refresh_token(sb)
    tokens = refresh_access_token(refresh_token)
    save_tokens(sb, tokens)
    access_token = tokens["access_token"]
    log.info("Token BTG renovado OK")

    accounts = get_accounts(access_token)
    log.info(f"{len(accounts)} conta(s) encontrada(s)")

    end   = date.today()
    start = end - timedelta(days=LOOKBACK_DAYS)
    log.info(f"Período: {start} → {end}")

    for acc in accounts:
        account_id = acc.get("id") or acc.get("accountId") or acc.get("account")
        log.info(f"Conta {account_id}")

        txs = get_statement(access_token, account_id, start, end)
        log.info(f"  {len(txs)} transações recebidas")

        if not txs:
            continue

        log.info(f"  Exemplo: {txs[0]}")

        rows = [parse_row(t) for t in txs]
        rows = [r for r in rows if r["id_externo"] is not None]
        n = upsert_em_lotes(sb, rows)
        log.info(f"  {n} registros upsertados")

    log.info("Sync BTG concluído.")


if __name__ == "__main__":
    main()
