"""
Gera Comparativo_Precos_CurvaA.xlsx
Greenjoy (Everest 2026) vs mercado (Atacadão/CEAGESP/Codeagro mai/2026).
"""
import pandas as pd
from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
from openpyxl.utils import get_column_letter

OUT = r"C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\Comparativo_Precos_CurvaA.xlsx"

# ── Dados Greenjoy (Everest Extraçao_18052026, preço médio ponderado jan-abr 2026) ──
# ── Referência mercado: Codeagro fev-abr/26, atacarejo mai/26, CEPEA abr/26 ─────────
data = [
    # Categoria, Item, Fornecedor GJ, KG/mês (média), R$/kg GJ, R$/kg Mercado, Fonte Ref, Obs
    # ── Proteínas ───────────────────────────────────────────────────────────────────
    ("Proteínas", "Filé Mignon",   "Nova União (CAYENA)", 27.4,  76.54, 85.00, "Atacadão/varejo mai/26",   "Premium — comparação difícil no atacado"),
    ("Proteínas", "Lagarto",       "Nova União (CAYENA)", 19.1,  35.21, 42.00, "Varejo SP mai/26",         "Atacado B2B costuma ser 15-20% abaixo varejo"),
    ("Proteínas", "Frango (peito)","Zanchetta",           None,  None,  15.99, "Atacarejo mai/26",         "Sem dado de preço/kg no Everest"),

    # ── Hortaliças ──────────────────────────────────────────────────────────────────
    ("Hortaliças", "Alface Higienizado",  "Verdureira",  79.1,  25.00, 14.00, "CEAGESP atacado + serviço de higienização estimado", "Inclui lavagem/sanificação — não é produto bruto"),
    ("Hortaliças", "Alface Roxa Higien.", "Verdureira",  15.1,  27.00, 16.00, "CEAGESP atacado + serviço higienização",    "Variedade premium"),
    ("Hortaliças", "Tomate Carmem",       "CMC",         83.3,  12.25, 11.89, "Atacarejo mai/26",          "Em linha com mercado"),
    ("Hortaliças", "Brócolis",            "CMC",         36.8,  14.20, 12.50, "Codeagro abr/26 (PNAE)",   "Levemente acima — pode ser sazonalidade"),
    ("Hortaliças", "Cenoura",             "CMC",         24.0,   7.18,  5.40, "Codeagro abr/26 (média)",  "Acima do mercado gov — B2B direto costuma ser similar"),
    ("Hortaliças", "Laranja",             "CMC",        180.0,   3.00,  4.50, "Codeagro abr/26",          "Abaixo do mercado — ótimo preço"),
    ("Hortaliças", "Morango",             "CMC",         18.3,  36.52, 40.00, "Estimativa atacado SP",    "Em linha com mercado"),
    ("Hortaliças", "Manga",               "CMC",         22.8,   6.79,  7.00, "Estimativa atacado SP",    "Em linha com mercado"),

    # ── Queijos ─────────────────────────────────────────────────────────────────────
    ("Queijos", "Mussarela de Búfala (peça)",  "Levitare",        11.3,  49.08, 55.00, "Bufalíssima Atacadão ~R$55/kg",  "Greenjoy paga abaixo do Atacadão — bom"),
    ("Queijos", "Queijo Búfala (bolinha)",      "Levitare",         2.0,  56.98, 65.00, "Formato premium — referência estimada",  "Formato diferente do varejo"),
    ("Queijos", "Parmesão Montanhês",           "Laticinios Tirolez", 14.2, 74.27, 80.00, "Tirolez montanhês varejo SP",  "Queijo maturado especial — em linha"),

    # ── Estoque Seco ─────────────────────────────────────────────────────────────────
    ("Estoque Seco", "Farinha de Trigo",    "Mercantil Santa Paula",  6.8,  7.51,  3.95, "Atacarejo mai/26 (25kg)",  "90% acima do atacarejo — checar embalagem/especificação"),
    ("Estoque Seco", "Farinha Panko",       "Mercantil Santa Paula", 10.0, 15.03, 10.00, "Estimativa importado atacado", "Panko importado — premium esperado"),
    ("Estoque Seco", "Açúcar Refinado",     "Mercantil Santa Paula",  3.0,  4.71,  3.25, "Atacarejo mai/26",         "45% acima do mercado — renegociar ou trocar fornecedor"),
    ("Estoque Seco", "Arroz Integral",      "Mercantil Santa Paula",  2.3,  6.60,  5.50, "Estimativa atacado SP",    "Em linha"),
    ("Estoque Seco", "Quinoa Branca",       "Mercantil Santa Paula",  3.8, 24.56, 28.00, "Estimativa atacado SP",    "Abaixo do varejo — ok"),
    ("Estoque Seco", "Azeitona Preta",      "Mercantil Santa Paula",  4.5, 44.48, 38.00, "Estimativa atacado SP",    "Acima do mercado — avaliar"),
    ("Estoque Seco", "Nozes",               "Mercantil Santa Paula",  1.3, 57.08, 65.00, "Estimativa atacado SP",    "Abaixo do mercado — bom"),
]

# Ajusta tuplas com None (frango sem dado GJ)
rows = []
for r in data:
    cat, item, forn, kg_mes, preco_gj, preco_ref, fonte, obs = r
    if preco_gj is not None and preco_ref is not None:
        diff_abs = preco_gj - preco_ref
        diff_pct = diff_abs / preco_ref
        impacto_mensal = diff_abs * (kg_mes or 0)
    else:
        diff_abs = diff_pct = impacto_mensal = None
    rows.append({
        "Categoria":        cat,
        "Item":             item,
        "Fornecedor":       forn,
        "Kg/mês (média)":   kg_mes,
        "R$/kg Greenjoy":   preco_gj,
        "R$/kg Mercado":    preco_ref,
        "Dif. R$/kg":       diff_abs,
        "Dif. %":           diff_pct,
        "Impacto R$/mês":   impacto_mensal,
        "Fonte referência": fonte,
        "Observação":       obs,
    })

df = pd.DataFrame(rows)

with pd.ExcelWriter(OUT, engine="openpyxl") as xw:
    df.to_excel(xw, sheet_name="Comparativo Preços", index=False)

    ws = xw.sheets["Comparativo Preços"]

    HEADER  = PatternFill("solid", fgColor="1F3864")
    VERDE   = PatternFill("solid", fgColor="C6EFCE")
    AMARELO = PatternFill("solid", fgColor="FFEB9C")
    VERMELHO= PatternFill("solid", fgColor="FFC7CE")
    NEUTRO  = PatternFill("solid", fgColor="F2F2F2")
    thin = Border(
        left=Side(style="thin"), right=Side(style="thin"),
        top=Side(style="thin"),  bottom=Side(style="thin")
    )

    for cell in ws[1]:
        cell.fill = HEADER
        cell.font = Font(bold=True, color="FFFFFF")
        cell.alignment = Alignment(horizontal="center", wrap_text=True)

    for row_idx in range(2, len(df) + 2):
        pct_val = ws.cell(row=row_idx, column=8).value  # Dif. %
        if pct_val is not None and isinstance(pct_val, (int, float)):
            fill = VERDE if pct_val <= -0.05 else (NEUTRO if pct_val <= 0.10 else (AMARELO if pct_val <= 0.30 else VERMELHO))
        else:
            fill = NEUTRO

        for col_idx in range(1, len(df.columns) + 1):
            cell = ws.cell(row=row_idx, column=col_idx)
            cell.border = thin
            cell.fill = fill
            if col_idx in (5, 6, 7, 9):  # preços e impacto
                cell.number_format = 'R$ #,##0.00'
            elif col_idx == 8:  # %
                cell.number_format = '+0.0%;-0.0%;0.0%'
            elif col_idx == 4:  # kg
                cell.number_format = '#,##0.0'

    widths = [16, 28, 26, 14, 16, 16, 13, 10, 16, 35, 45]
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w

    # Legenda
    ws.cell(row=len(df)+3, column=1, value="Legenda:").font = Font(bold=True)
    legenda = [
        (VERDE,    "Verde = Greenjoy paga abaixo do mercado (≤-5%)"),
        (NEUTRO,   "Cinza = Em linha com mercado (±10%)"),
        (AMARELO,  "Amarelo = Acima do mercado (+10% a +30%)"),
        (VERMELHO, "Vermelho = Significativamente acima do mercado (>+30%)"),
    ]
    for i, (fill, texto) in enumerate(legenda, len(df)+4):
        ws.cell(row=i, column=1).fill = fill
        ws.cell(row=i, column=1).border = thin
        ws.cell(row=i, column=2, value=texto)

    ws.cell(row=len(df)+9, column=1, value="Fonte mercado:").font = Font(bold=True)
    ws.cell(row=len(df)+10, column=1, value="Codeagro SP fev-abr/2026, Atacarejo mai/2026 (CPG), CEPEA abr/2026. Preços B2B tipicamente 15-25% abaixo do varejo referenciado.")

print(f"Gerado: {OUT}")
