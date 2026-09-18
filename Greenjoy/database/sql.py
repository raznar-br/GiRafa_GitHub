"""Roda SQL no Supabase via Management API.

    python sql.py arquivo.sql
    python sql.py -c "select 1"
    from sql import run; run("select 1")
"""

import os
import sys
import json

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

REF = os.environ["SUPABASE_PROJECT_REF"]
PAT = os.environ["SUPABASE_PAT"]
URL = f"https://api.supabase.com/v1/projects/{REF}/database/query"


def run(query, silencioso=False):
    r = requests.post(URL, headers={"Authorization": f"Bearer {PAT}"},
                      json={"query": query}, timeout=180)
    if r.status_code >= 400:
        raise RuntimeError(f"{r.status_code}: {r.text[:600]}")
    dados = r.json()
    if not silencioso and dados:
        print(json.dumps(dados[:50], indent=1, ensure_ascii=False, default=str))
    return dados


if __name__ == "__main__":
    if sys.argv[1] == "-c":
        run(sys.argv[2])
    else:
        with open(sys.argv[1], encoding="utf-8") as fh:
            run(fh.read())
        print(f"OK: {sys.argv[1]}")
