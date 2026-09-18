"""
Compara Class Despesas JAFEB.csv (fonte) vs jafeb_despesas_mapping (Supabase).
Gera Validacao_Mapping.xlsx com divergências.
"""
import os, csv
import pandas as pd
from supabase import create_client
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
CSV_PATH = os.path.join(os.path.dirname(__file__), "..", "Class Despesas JAFEB.csv")
OUT_PATH = os.path.join(os.path.dirname(__file__), "..", "Validacao_Mapping.xlsx")

# ── 1. Ler CSV ──────────────────────────────────────────────────────────────
rows_csv = []
with open(CSV_PATH, encoding="utf-8-sig", newline="") as f:
    reader = csv.DictReader(f, delimiter=";")
    for row in reader:
        desc = row.get("Descrição", "").strip()
        if not desc:
            continue
        rows_csv.append({
            "descricao_csv": desc,
            "chave":         desc.upper().strip(),
            "natureza_csv":  row.get("Natureza", "").strip(),
            "cat1_csv":      row.get("Categoria 1", "").strip(),
            "cat2_csv":      row.get("Categoria 2", "").strip(),
        })

df_csv = pd.DataFrame(rows_csv)
print(f"CSV: {len(df_csv)} linhas")

# ── 2. Buscar Supabase (paginado) ────────────────────────────────────────────
sb = create_client(SUPABASE_URL, SUPABASE_KEY)
rows_sb = []
offset = 0
while True:
    res = sb.table("jafeb_despesas_mapping").select(
        "id,descricao,natureza,categoria_1,categoria_2"
    ).range(offset, offset + 999).execute()
    batch = res.data
    rows_sb.extend(batch)
    if len(batch) < 1000:
        break
    offset += 1000

df_sb = pd.DataFrame(rows_sb)
df_sb["chave"] = df_sb["descricao"].str.upper().str.strip()
print(f"Supabase: {len(df_sb)} linhas")

# ── 3. Merge para comparar ───────────────────────────────────────────────────
# chave = UPPER(TRIM(descricao)) — base do JOIN real no Supabase
merged = pd.merge(df_csv, df_sb, on="chave", how="outer", indicator=True)

csv_only  = merged[merged["_merge"] == "left_only"].copy()
supa_only = merged[merged["_merge"] == "right_only"].copy()
both      = merged[merged["_merge"] == "both"].copy()

# Divergências de natureza ou categoria em entradas presentes nos dois
def norm(s):
    return str(s).strip().lower() if pd.notna(s) else ""

both["diff_natureza"] = both.apply(lambda r: norm(r["natureza_csv"]) != norm(r["natureza"]), axis=1)
both["diff_cat1"]     = both.apply(lambda r: norm(r["cat1_csv"])     != norm(r["categoria_1"]), axis=1)
both["diff_cat2"]     = both.apply(lambda r: norm(r["cat2_csv"])     != norm(r["categoria_2"]), axis=1)
divergentes = both[both["diff_natureza"] | both["diff_cat1"] | both["diff_cat2"]].copy()

print(f"\nSó no CSV (faltando no Supabase): {len(csv_only)}")
print(f"Só no Supabase (não no CSV):      {len(supa_only)}")
print(f"Em ambos com divergência:          {len(divergentes)}")
print(f"Em ambos sem divergência:          {len(both) - len(divergentes)}")

# ── 4. Gerar Excel ───────────────────────────────────────────────────────────
with pd.ExcelWriter(OUT_PATH, engine="openpyxl") as xw:
    # Sumário
    sumario = pd.DataFrame({
        "Item": [
            "Linhas no CSV",
            "Linhas no Supabase",
            "Presentes nos dois (OK)",
            "Presentes nos dois com divergência de classificação",
            "Só no CSV — FALTANDO no Supabase",
            "Só no Supabase — não estão no CSV",
        ],
        "Qtd": [
            len(df_csv),
            len(df_sb),
            len(both) - len(divergentes),
            len(divergentes),
            len(csv_only),
            len(supa_only),
        ]
    })
    sumario.to_excel(xw, sheet_name="1.Sumário", index=False)

    # CSV faltando no Supabase
    cols_missing = ["descricao_csv", "natureza_csv", "cat1_csv", "cat2_csv"]
    csv_only[cols_missing].rename(columns={
        "descricao_csv": "Descrição",
        "natureza_csv": "Natureza",
        "cat1_csv": "Categoria 1",
        "cat2_csv": "Categoria 2",
    }).sort_values("Descrição").to_excel(xw, sheet_name="2.Faltando no Supabase", index=False)

    # Supabase não no CSV
    cols_extra = ["descricao", "natureza", "categoria_1", "categoria_2", "id"]
    supa_only[cols_extra].rename(columns={
        "descricao": "Descrição",
        "natureza": "Natureza",
        "categoria_1": "Categoria 1",
        "categoria_2": "Categoria 2",
    }).sort_values("Descrição").to_excel(xw, sheet_name="3.Extra no Supabase", index=False)

    # Divergências de classificação
    div_cols = ["descricao_csv", "natureza_csv", "cat1_csv", "cat2_csv",
                "natureza", "categoria_1", "categoria_2"]
    divergentes[div_cols].rename(columns={
        "descricao_csv": "Descrição",
        "natureza_csv": "Natureza CSV",
        "cat1_csv": "Cat1 CSV",
        "cat2_csv": "Cat2 CSV",
        "natureza": "Natureza Supa",
        "categoria_1": "Cat1 Supa",
        "categoria_2": "Cat2 Supa",
    }).sort_values("Descrição").to_excel(xw, sheet_name="4.Divergências", index=False)

print(f"\nGerado: {OUT_PATH}")
