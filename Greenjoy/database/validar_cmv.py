"""
validar_cmv.py
Compara CMV Modelo Competência vs BTG (caixa) — Jan-Abr/2026

Lógica de conciliação:
  Modelo = competência (data de entrega/fatura)
  BTG    = caixa      (data de débito bancário)
  Timing: pagamentos ocorrem 15-30 dias após entrega → desvios mensais esperados

Saída: ../Validacao_CMV_JanAbr2026.xlsx
"""
import os
from collections import defaultdict
from dotenv import load_dotenv
from supabase import create_client
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter

load_dotenv()
sb = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SERVICE_KEY"))

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_FILE  = os.path.join(BASE, "Modelo Competencia_Validar CMV.xlsx")
OUTPUT_FILE = os.path.join(BASE, "Validacao_CMV_JanAbr2026.xlsx")

MESES  = ["2026-01", "2026-02", "2026-03", "2026-04"]
LABELS = {"2026-01": "Jan/26", "2026-02": "Fev/26", "2026-03": "Mar/26", "2026-04": "Abr/26"}

# Mapa: categoria do Modelo → categoria BTG (para agrupar categorias equivalentes)
CAT_MODELO = {
    "Hortifruti": "Hortaliças", "Cogumelos": "Hortaliças", "Avocado": "Hortaliças",
    "Palmito": "Hortaliças", "Tomate": "Hortaliças", "Folhas - alface e mix ": "Hortaliças",
    "Mussarela e outros": "Queijos", "Queijos": "Queijos", "Parmesão": "Queijos",
    "Tortas": "Tortas",
    "Molhos cozinha central": "Molhos Cozinha Central",
    "Carne": "Proteínas", "Frango": "Proteínas", "Peixe": "Proteínas",
    "Bacon": "Proteínas", "Bacon fatiado": "Proteínas", "Carne Moida": "Proteínas",
    "Estoque seco, arroz feijao ": "Estoque Seco", "azeite, amendoas ": "Estoque Seco",
    "Batata Chips": "Estoque Seco", "Saque": "Estoque Seco", "Cebola Crispy": "Estoque Seco",
    "Estoque seco, atum chocolante , farinha pako ": "Estoque Seco",
    "Estoque seco ": "Estoque Seco", "Tortilhas": "Estoque Seco",
    "Pimentas ": "Estoque Seco", "Estoque seco": "Estoque Seco",
    "Whey protein": "Estoque Seco", "Temperos secos": "Estoque Seco", "Azeite": "Estoque Seco",
    "Frozen": "Sobremesas e Smoothies", "Morangos": "Sobremesas e Smoothies",
    "Açaí": "Sobremesas e Smoothies", "Mel": "Sobremesas e Smoothies",
    "Chocolate": "Sobremesas e Smoothies", "Iogurte Grego": "Sobremesas e Smoothies",
    "Leite vegetal": "Sobremesas e Smoothies", "Granola": "Sobremesas e Smoothies",
    "Frutas congeladas ": "Sobremesas e Smoothies", "Sublyme": "Sobremesas e Smoothies",
    "Agua de coco": "Sobremesas e Smoothies", "Matcha": "Sobremesas e Smoothies",
    "Coca Cola": "Bebidas", "Agua prata ": "Bebidas", "Refrigerante ": "Bebidas",
    "Kombucha": "Bebidas", "Baer Mate": "Bebidas",
    "Caixa de wrap e caixa e torta ": "Embalagens", "Embalagens Delivery": "Embalagens",
    "Papel para wrap": "Embalagens", "Embalagens para salada": "Embalagens",
    "Copo": "Embalagens", "Potes molhos": "Embalagens",
    "Porta copos de papelão": "Embalagens", "Guardanapos com logo": "Embalagens",
    "Lacre para sacolas": "Embalagens", "Tampa para copos e potes": "Embalagens",
    "Canudos": "Embalagens", "Tampa copos": "Embalagens", "-": "Embalagens",
    "Tampa copobras": "Embalagens", "Hashi": "Embalagens",
    "Transporte Embalagens": "Embalagens", "?": "Embalagens", "Sacolas": "Embalagens",
    "Outros": "Outros", "ICMS Diferencial": "Outros",
}

# ─── Leitura do Modelo Excel ───────────────────────────────────────────────────
def read_model():
    wb = openpyxl.load_workbook(MODEL_FILE)
    ws = wb.active
    col_mes = {58: "2026-01", 59: "2026-02", 60: "2026-03", 61: "2026-04"}
    items = []
    for r in range(72, 300):
        if ws.cell(r, 5).value != "Custo":
            continue
        forn     = (ws.cell(r, 4).value or "").strip()
        cat_orig = (ws.cell(r, 6).value or "").strip()
        cat_btg  = CAT_MODELO.get(cat_orig, cat_orig)
        for col, mes in col_mes.items():
            v = float(ws.cell(r, col).value or 0)
            if v:
                items.append({"fornecedor": forn, "cat_modelo": cat_orig, "cat_btg": cat_btg,
                               "mes": mes, "valor": round(v, 2)})
    return items

# ─── Busca BTG via Supabase ────────────────────────────────────────────────────
def fetch_btg():
    # Mapa: UPPER(TRIM(descricao)) → categoria_2 (primeiro por id, tipo DISTINCT ON)
    m_rows = (sb.table("jafeb_despesas_mapping")
              .select("id,descricao,natureza,categoria_2")
              .eq("natureza", "Custo")
              .order("id")
              .execute().data)
    mapa = {}
    for row in m_rows:
        key = row["descricao"].upper().strip()
        if key not in mapa:
            cat = (row["categoria_2"] or "Outros")
            mapa[key] = "Bebidas" if cat.lower() == "bebidas" else cat

    # Busca BTG débitos Jan-Abr/26 com paginação
    all_rows = []
    offset = 0
    while True:
        batch = (sb.table("btg_movimentacoes")
                 .select("data_movimentacao,tipo,valor,descricao,nome_pagador_recebedor")
                 .eq("tipo", "Débito")
                 .gte("data_movimentacao", "2026-01-01")
                 .lt("data_movimentacao", "2026-05-01")
                 .range(offset, offset + 999)
                 .execute().data)
        all_rows.extend(batch)
        if len(batch) < 1000:
            break
        offset += 1000

    items = []
    unmapped = {}
    for row in all_rows:
        nome = (row["nome_pagador_recebedor"] or row["descricao"] or "").strip()
        key  = nome.upper().strip()
        if key not in mapa:
            unmapped[key] = unmapped.get(key, 0) + abs(float(row["valor"]))
            continue
        mes = row["data_movimentacao"][:7]
        if mes not in MESES:
            continue
        items.append({"fornecedor": nome, "categoria": mapa[key],
                      "mes": mes, "valor": round(abs(float(row["valor"])), 2)})

    if unmapped:
        print(f"\n[BTG] {len(unmapped)} fornecedores sem mapeamento (não incluídos no CMV):")
        for k, v in sorted(unmapped.items(), key=lambda x: -x[1])[:10]:
            print(f"  {k}: R${v:,.2f}")

    return items

# ─── Carregar dados ────────────────────────────────────────────────────────────
print("Lendo Modelo Excel...")
model_items = read_model()
print(f"  {len(model_items)} linhas de fornecedor-mês")

print("Buscando BTG no Supabase...")
btg_items = fetch_btg()
print(f"  {len(btg_items)} transações mapeadas")

# Totais por mês
m_total = defaultdict(float)
b_total = defaultdict(float)
for it in model_items: m_total[it["mes"]] += it["valor"]
for it in btg_items:   b_total[it["mes"]] += it["valor"]

# Por categoria
m_cat = defaultdict(lambda: defaultdict(float))
b_cat = defaultdict(lambda: defaultdict(float))
for it in model_items: m_cat[it["cat_btg"]][it["mes"]] += it["valor"]
for it in btg_items:   b_cat[it["categoria"]][it["mes"]] += it["valor"]

all_cats = sorted(set(list(m_cat.keys()) + list(b_cat.keys())))

# Por fornecedor (acumulado 4 meses)
m_forn = defaultdict(lambda: defaultdict(float))
b_forn = defaultdict(lambda: defaultdict(float))
for it in model_items: m_forn[(it["fornecedor"], it["cat_btg"])][it["mes"]] += it["valor"]
for it in btg_items:   b_forn[(it["fornecedor"], it["categoria"])][it["mes"]] += it["valor"]

# ─── Estilos ───────────────────────────────────────────────────────────────────
BLUE  = PatternFill(fgColor="2E75B6", fill_type="solid")
LBLUE = PatternFill(fgColor="BDD7EE", fill_type="solid")
GREEN = PatternFill(fgColor="C6EFCE", fill_type="solid")
RED   = PatternFill(fgColor="FFC7CE", fill_type="solid")
YELL  = PatternFill(fgColor="FFEB9C", fill_type="solid")
GRAY  = PatternFill(fgColor="D9D9D9", fill_type="solid")
FNT_W = Font(bold=True, color="FFFFFF")
BOLD  = Font(bold=True)
CTR   = Alignment(horizontal="center")
RGT   = Alignment(horizontal="right")
FMT_R = "#,##0.00"
FMT_P = "0.0%"

def style(c, fill=None, font=None, align=None, fmt=None):
    if fill:  c.fill  = fill
    if font:  c.font  = font
    if align: c.alignment = align
    if fmt:   c.number_format = fmt
    return c

# ─── Workbook ─────────────────────────────────────────────────────────────────
wb = openpyxl.Workbook()

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 1 — Sumário
# ═══════════════════════════════════════════════════════════════════════════════
ws1 = wb.active
ws1.title = "1. Sumário"

ws1.merge_cells("A1:G1")
style(ws1.cell(1, 1, "Validação CMV: Modelo Competência vs BTG (Caixa) — Jan-Abr/2026"),
      fill=BLUE, font=Font(bold=True, size=14, color="FFFFFF"), align=CTR)

ws1.merge_cells("A2:G2")
style(ws1.cell(2, 1, "Modelo = competência (data de entrega/fatura) | BTG = caixa (data de débito bancário) | Diferença de timing esperada: 15-30 dias"),
      font=Font(italic=True, size=10, color="595959"), align=CTR)

r = 4
ws1.cell(r, 1, "Métrica").font = BOLD; ws1.cell(r, 1).fill = LBLUE
for i, m in enumerate(MESES):
    style(ws1.cell(r, 2+i, LABELS[m]), fill=LBLUE, font=BOLD, align=CTR)
style(ws1.cell(r, 6, "Total Jan-Abr"), fill=LBLUE, font=BOLD, align=CTR)

rows_def = [
    ("Modelo — Competência (R$)", [m_total[m] for m in MESES], FMT_R, None),
    ("BTG — Caixa (R$)",          [b_total[m] for m in MESES], FMT_R, None),
    ("Diferença R$ (BTG − Modelo)", [b_total[m]-m_total[m] for m in MESES], FMT_R, True),
    ("Diferença % sobre Modelo",    [(b_total[m]-m_total[m])/m_total[m] if m_total[m] else 0
                                     for m in MESES], FMT_P, True),
]
for label, vals, fmt, colorize in rows_def:
    r += 1
    style(ws1.cell(r, 1, label), font=BOLD)
    for i, v in enumerate(vals):
        c = style(ws1.cell(r, 2+i, v), fmt=fmt, align=RGT)
        if colorize:
            c.fill = GREEN if v >= 0 else RED
    total = sum(vals)
    c = style(ws1.cell(r, 6, total), font=BOLD, fmt=fmt, align=RGT)
    if colorize:
        c.fill = GREEN if total >= 0 else RED

r += 2
ws1.merge_cells(f"A{r}:G{r}")
ws1.cell(r, 1,
    "LEGENDA DIFERENÇA: Verde = BTG ≥ Modelo (BTG capturou mais) | "
    "Vermelho = Modelo > BTG (itens do modelo fora do BTG ou efeito timing)").font = Font(italic=True, size=9)

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 2 — Por Categoria
# ═══════════════════════════════════════════════════════════════════════════════
ws2 = wb.create_sheet("2. Por Categoria")

ws2.merge_cells("A1:M1")
style(ws2.cell(1, 1, "CMV por Categoria — Modelo Competência vs BTG Caixa (Jan-Abr/2026)"),
      fill=BLUE, font=Font(bold=True, size=13, color="FFFFFF"), align=CTR)

# Cabeçalho duplo (linha 3: meses agrupados; linha 4: Modelo/BTG/Diff)
r = 3
style(ws2.cell(r, 1, "Categoria"), fill=LBLUE, font=BOLD)
col = 2
for m in MESES:
    ws2.merge_cells(start_row=r, start_column=col, end_row=r, end_column=col+2)
    style(ws2.cell(r, col, LABELS[m]), fill=LBLUE, font=BOLD, align=CTR)
    style(ws2.cell(r+1, col,   "Modelo R$"), fill=GRAY, font=BOLD, align=CTR)
    style(ws2.cell(r+1, col+1, "BTG R$"),    fill=GRAY, font=BOLD, align=CTR)
    style(ws2.cell(r+1, col+2, "Diff %"),    fill=GRAY, font=BOLD, align=CTR)
    col += 3
style(ws2.cell(r,   col, "Total Modelo"), fill=LBLUE, font=BOLD, align=CTR)
style(ws2.cell(r,   col+1, "Total BTG"),  fill=LBLUE, font=BOLD, align=CTR)
style(ws2.cell(r+1, col, "Jan-Abr R$"),  fill=GRAY, font=BOLD, align=CTR)
style(ws2.cell(r+1, col+1, "Jan-Abr R$"), fill=GRAY, font=BOLD, align=CTR)
r += 2

for cat in all_cats:
    style(ws2.cell(r, 1, cat), font=BOLD)
    col = 2
    sum_m = sum_b = 0.0
    for m in MESES:
        mv = m_cat[cat][m]
        bv = b_cat[cat][m]
        sum_m += mv; sum_b += bv
        style(ws2.cell(r, col,   mv or 0), fmt=FMT_R, align=RGT)
        style(ws2.cell(r, col+1, bv or 0), fmt=FMT_R, align=RGT)
        diff_p = (bv - mv) / mv if mv else None
        c = ws2.cell(r, col+2)
        if diff_p is not None:
            c.value = diff_p; c.number_format = FMT_P; c.alignment = RGT
            c.fill = GREEN if abs(diff_p) < 0.10 else (YELL if abs(diff_p) < 0.30 else RED)
        else:
            c.value = "s/modelo"; c.fill = LBLUE; c.alignment = CTR
        col += 3
    style(ws2.cell(r, col,   sum_m), fmt=FMT_R, align=RGT, font=BOLD)
    style(ws2.cell(r, col+1, sum_b), fmt=FMT_R, align=RGT, font=BOLD)
    r += 1

# Totais
style(ws2.cell(r, 1, "TOTAL"), fill=GRAY, font=BOLD)
col = 2
for m in MESES:
    style(ws2.cell(r, col,   m_total[m]), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
    style(ws2.cell(r, col+1, b_total[m]), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
    diff_p = (b_total[m]-m_total[m])/m_total[m] if m_total[m] else 0
    style(ws2.cell(r, col+2, diff_p), fill=GRAY, font=BOLD, fmt=FMT_P, align=RGT)
    col += 3
style(ws2.cell(r, col,   sum(m_total[m] for m in MESES)), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
style(ws2.cell(r, col+1, sum(b_total[m] for m in MESES)), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 3 — Fornecedores Modelo
# ═══════════════════════════════════════════════════════════════════════════════
ws3 = wb.create_sheet("3. Fornecedores Modelo")
ws3.merge_cells("A1:H1")
style(ws3.cell(1, 1, "Fornecedores Modelo — Competência (Jan-Abr/2026) · ordenado por total decrescente"),
      fill=BLUE, font=Font(bold=True, size=12, color="FFFFFF"), align=CTR)

r = 3
for ci, h in enumerate(["Fornecedor", "Categoria", "Jan/26", "Fev/26", "Mar/26", "Abr/26", "Total", "Cat. Modelo"], 1):
    style(ws3.cell(r, ci, h), fill=LBLUE, font=BOLD, align=CTR if ci > 2 else None)

r += 1
forn_totals_m = {k: sum(v.values()) for k, v in m_forn.items()}
for (forn, cat), total_v in sorted(forn_totals_m.items(), key=lambda x: -x[1]):
    mv = m_forn[(forn, cat)]
    # Recuperar cat_modelo original
    cat_m = next((it["cat_modelo"] for it in model_items if it["fornecedor"] == forn), "")
    ws3.cell(r, 1, forn)
    ws3.cell(r, 2, cat)
    for i, m in enumerate(MESES):
        style(ws3.cell(r, 3+i, mv.get(m) or 0), fmt=FMT_R, align=RGT)
    style(ws3.cell(r, 7, total_v), fmt=FMT_R, align=RGT, font=BOLD)
    ws3.cell(r, 8, cat_m)
    r += 1

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 4 — Fornecedores BTG
# ═══════════════════════════════════════════════════════════════════════════════
ws4 = wb.create_sheet("4. Fornecedores BTG")
ws4.merge_cells("A1:G1")
style(ws4.cell(1, 1, "Fornecedores BTG — Caixa (Jan-Abr/2026) · ordenado por total decrescente"),
      fill=BLUE, font=Font(bold=True, size=12, color="FFFFFF"), align=CTR)

r = 3
for ci, h in enumerate(["Fornecedor", "Categoria BTG", "Jan/26", "Fev/26", "Mar/26", "Abr/26", "Total"], 1):
    style(ws4.cell(r, ci, h), fill=LBLUE, font=BOLD, align=CTR if ci > 2 else None)

r += 1
forn_totals_b = {k: sum(v.values()) for k, v in b_forn.items()}
for (forn, cat), total_v in sorted(forn_totals_b.items(), key=lambda x: -x[1]):
    bv = b_forn[(forn, cat)]
    ws4.cell(r, 1, forn)
    ws4.cell(r, 2, cat)
    for i, m in enumerate(MESES):
        style(ws4.cell(r, 3+i, bv.get(m) or 0), fmt=FMT_R, align=RGT)
    style(ws4.cell(r, 7, total_v), fmt=FMT_R, align=RGT, font=BOLD)
    r += 1

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 5 — Conciliação
# ═══════════════════════════════════════════════════════════════════════════════
ws5 = wb.create_sheet("5. Conciliação")
ws5.merge_cells("A1:E1")
style(ws5.cell(1, 1, "Conciliação e Análise de Divergências"),
      fill=BLUE, font=Font(bold=True, size=13, color="FFFFFF"), align=CTR)

btg_forn_keys = {f.upper().strip() for (f, _) in b_forn.keys()}

# Fornecedores só no Modelo (não aparecem no BTG)
model_only = sorted(
    [{"forn": forn, "cat": cat, "total": sum(mv.values()),
      "jan": mv.get("2026-01", 0), "fev": mv.get("2026-02", 0),
      "mar": mv.get("2026-03", 0), "abr": mv.get("2026-04", 0)}
     for (forn, cat), mv in m_forn.items()
     if forn.upper().strip() not in btg_forn_keys and sum(mv.values()) > 100],
    key=lambda x: -x["total"]
)

r = 3
style(ws5.cell(r, 1, "DIFERENÇA TOTAL POR MÊS (BTG − Modelo)"), font=Font(bold=True, size=11))
r += 1
for ci, h in enumerate(["Mês", "Modelo R$", "BTG R$", "Diferença R$", "Diff %"], 1):
    style(ws5.cell(r, ci, h), fill=LBLUE, font=BOLD, align=CTR)
r += 1
for m in MESES:
    mv = m_total[m]; bv = b_total[m]; diff = bv - mv
    pct = diff / mv if mv else 0
    ws5.cell(r, 1, LABELS[m]).font = BOLD
    style(ws5.cell(r, 2, mv), fmt=FMT_R, align=RGT)
    style(ws5.cell(r, 3, bv), fmt=FMT_R, align=RGT)
    c = style(ws5.cell(r, 4, diff), fmt=FMT_R, align=RGT, font=BOLD)
    c.fill = GREEN if diff >= 0 else RED
    c2 = style(ws5.cell(r, 5, pct), fmt=FMT_P, align=RGT)
    c2.fill = GREEN if diff >= 0 else RED
    r += 1

# Totais
sum_m = sum(m_total[m] for m in MESES)
sum_b = sum(b_total[m] for m in MESES)
sum_d = sum_b - sum_m
style(ws5.cell(r, 1, "TOTAL"), fill=GRAY, font=BOLD)
style(ws5.cell(r, 2, sum_m), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
style(ws5.cell(r, 3, sum_b), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
c = style(ws5.cell(r, 4, sum_d), fill=GRAY, font=BOLD, fmt=FMT_R, align=RGT)
c.fill = GREEN if sum_d >= 0 else RED
style(ws5.cell(r, 5, sum_d/sum_m if sum_m else 0), fill=GRAY, font=BOLD, fmt=FMT_P, align=RGT)

r += 2
style(ws5.cell(r, 1, "CAUSAS PROVÁVEIS DA DIVERGÊNCIA"), font=Font(bold=True, size=11))
r += 1
causas = [
    ("1. Timing competência vs caixa",
     "Principal causa: fornecedores com prazo 30 dias → entrega em mês M, pagamento em M+1"),
    ("2. Itens exclusivos do Modelo",
     "Ex: 'Custo Cartão de Crédito' (taxa interna sem débito BTG), ICMS Diferencial"),
    ("3. Fornecedores no BTG sem correspondência no Modelo",
     "Ex: MADA FOODS, MEX COMPANY, BAKED ALIMENTOS, FT PESCADOS — estão no BTG mas não no Modelo"),
    ("4. Nome truncado no BTG",
     "Ex: 'CMC. DISTRIBUIDORA DE HORTIFRU' (BTG) ≠ 'CMC. DISTRIBUIDORA DE HORTIFRUTI LTDA -' (Modelo)"),
    ("5. Greenjoy Franqueadora no Modelo, não no BTG",
     "Reclassificado para Despesa/Royalties em Mai/26 — no Modelo ainda aparece em CMV como 'Molhos cozinha central'"),
]
for titulo, detalhe in causas:
    ws5.cell(r, 1, titulo).font = BOLD
    ws5.cell(r, 2, detalhe).font = Font(italic=True)
    r += 1

r += 1
style(ws5.cell(r, 1, f"FORNECEDORES EXCLUSIVOS DO MODELO (não encontrados no BTG · {len(model_only)} itens > R$100)"),
      font=Font(bold=True, size=11))
r += 1
for ci, h in enumerate(["Fornecedor", "Categoria", "Jan/26", "Fev/26", "Mar/26", "Abr/26", "Total"], 1):
    style(ws5.cell(r, ci, h), fill=LBLUE, font=BOLD)
r += 1
for it in model_only:
    ws5.cell(r, 1, it["forn"])
    ws5.cell(r, 2, it["cat"])
    for ci, m in enumerate(["jan", "fev", "mar", "abr"], 3):
        style(ws5.cell(r, ci, it[m] or 0), fmt=FMT_R, align=RGT)
    style(ws5.cell(r, 7, it["total"]), fmt=FMT_R, align=RGT, font=BOLD)
    r += 1

# ═══════════════════════════════════════════════════════════════════════════════
# ABA 6 — Faturamento
# ═══════════════════════════════════════════════════════════════════════════════
ws6 = wb.create_sheet("6. Faturamento")
ws6.merge_cells("A1:H1")
style(ws6.cell(1, 1, "Validação Faturamento: Modelo Competência vs Eclética (PDV) — Jan-Abr/2026"),
      fill=BLUE, font=Font(bold=True, size=13, color="FFFFFF"), align=CTR)
ws6.merge_cells("A2:H2")
style(ws6.cell(2, 1,
    "Modelo = lançado manualmente pelo gestor | Eclética = PDV Eclética (vlr_total + vlr_serv − vlr_desc_tot, cancelados excluídos)"),
      font=Font(italic=True, size=10, color="595959"), align=CTR)

# Dados modelo: Receita Bruta linha 16, cols 58-61
_wb_m = openpyxl.load_workbook(MODEL_FILE)
_ws_m = _wb_m.active
modelo_fat = {
    "2026-01": float(_ws_m.cell(16, 58).value or 0),
    "2026-02": float(_ws_m.cell(16, 59).value or 0),
    "2026-03": float(_ws_m.cell(16, 60).value or 0),
    "2026-04": float(_ws_m.cell(16, 61).value or 0),
}
_wb_m.close()

# Dados Eclética (bruto = vlr_total; líquido = + vlr_serv − vlr_desc_tot)
# Fonte: query Supabase em Mai/2026 — atualizar conforme necessário
ecletica_bruto = {"2026-01": 547331.38, "2026-02": 532069.51, "2026-03": 570847.30, "2026-04": 541736.47}
ecletica_liq   = {"2026-01": 532291.23, "2026-02": 517431.29, "2026-03": 549954.68, "2026-04": 520442.08}
ecletica_tick  = {"2026-01": 6303,      "2026-02": 6108,      "2026-03": 6678,      "2026-04": 6289}

r = 4
# Cabeçalho
for ci, h in enumerate(["Métrica", "Jan/26", "Fev/26", "Mar/26", "Abr/26", "Total Jan-Abr"], 1):
    style(ws6.cell(r, ci, h), fill=LBLUE, font=BOLD, align=CTR if ci > 1 else None)

fat_rows = [
    ("Modelo — Receita Bruta (R$)", [modelo_fat[m] for m in MESES], FMT_R, False),
    ("Eclética — Fat. Bruto (R$)",  [ecletica_bruto[m] for m in MESES], FMT_R, False),
    ("Eclética — Fat. Líquido (R$)", [ecletica_liq[m] for m in MESES], FMT_R, False),
    ("Diff Modelo vs E. Bruto R$",  [ecletica_bruto[m]-modelo_fat[m] for m in MESES], FMT_R, True),
    ("Diff Modelo vs E. Bruto %",   [(ecletica_bruto[m]-modelo_fat[m])/modelo_fat[m] if modelo_fat[m] else 0
                                     for m in MESES], FMT_P, True),
    ("Diff Modelo vs E. Líq. R$",   [ecletica_liq[m]-modelo_fat[m] for m in MESES], FMT_R, True),
    ("Diff Modelo vs E. Líq. %",    [(ecletica_liq[m]-modelo_fat[m])/modelo_fat[m] if modelo_fat[m] else 0
                                     for m in MESES], FMT_P, True),
    ("Tickets Eclética",            [ecletica_tick[m] for m in MESES], "#,##0", False),
    ("Ticket Médio Eclética (R$)",  [ecletica_liq[m]/ecletica_tick[m] for m in MESES], FMT_R, False),
]
for label, vals, fmt, colorize in fat_rows:
    r += 1
    style(ws6.cell(r, 1, label), font=BOLD)
    for i, v in enumerate(vals):
        c = style(ws6.cell(r, 2+i, v), fmt=fmt, align=RGT)
        if colorize:
            c.fill = GREEN if v >= 0 else RED
    total = sum(vals) if fmt != FMT_P else vals[-1]  # % não soma
    if fmt != FMT_P and "Ticket" not in label:
        c = style(ws6.cell(r, 6, total), font=BOLD, fmt=fmt, align=RGT)
        if colorize:
            c.fill = GREEN if total >= 0 else RED

r += 2
style(ws6.cell(r, 1, "ANÁLISE DAS DIVERGÊNCIAS DE FATURAMENTO"), font=Font(bold=True, size=11))
r += 1
fat_causas = [
    "Eclética > Modelo em todos os meses: o Modelo pode não capturar 100% das vendas Eclética",
    "Abril: gap de R$79k (14,6%) — maior divergência; verificar se todas as entradas iFood foram lançadas no Modelo",
    "iFood: Eclética registra bruto (pedido do cliente); o Modelo pode usar valor líquido de repasse",
    "Diferença consistente de ~6%/mês em Jan-Mar sugere um componente estrutural (ex: taxa de serviço não incluída no Modelo)",
    "Comparar com linha 'Receita Líquida de descontos' do Modelo (linha 49) para melhor alinhamento",
]
for causa in fat_causas:
    ws6.cell(r, 1, f"  • {causa}").font = Font(italic=True, size=10)
    r += 1

# ─── Auto-largura colunas ─────────────────────────────────────────────────────
for ws in [ws1, ws2, ws3, ws4, ws5, ws6]:
    for col_cells in ws.columns:
        max_len = 0
        col_letter = get_column_letter(col_cells[0].column)
        for cell in col_cells:
            try:
                val = cell.value
                if val is not None:
                    max_len = max(max_len, len(str(val)))
            except Exception:
                pass
        ws.column_dimensions[col_letter].width = min(max_len + 2, 55)

# ─── Salvar ───────────────────────────────────────────────────────────────────
wb.save(OUTPUT_FILE)
print(f"\nSalvo: {OUTPUT_FILE}")
print("\n=== RESUMO ===")
for m in MESES:
    d = b_total[m] - m_total[m]
    print(f"  {LABELS[m]}: Modelo={m_total[m]:>12,.2f} | BTG={b_total[m]:>12,.2f} | Diff={d:>+12,.2f} ({d/m_total[m]:+.1%})")
total_d = sum_b - sum_m
print(f"  {'Jan-Abr':7s}: Modelo={sum_m:>12,.2f} | BTG={sum_b:>12,.2f} | Diff={total_d:>+12,.2f} ({total_d/sum_m:+.1%})")
