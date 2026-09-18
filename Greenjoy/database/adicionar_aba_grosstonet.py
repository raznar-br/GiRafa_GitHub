"""
adicionar_aba_grosstonet.py — Adiciona aba "8. CMV Gross-to-Net" ao Excel de auditoria.
Mostra exatamente o que compõe o CMV de Abril/2026 como aparece no dashboard.
"""
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

ARQUIVO = r"C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\Auditoria_KPIs_Dashboard.xlsx"

VERDE_ESCURO   = "1a6b3c"
VERDE_CLARO    = "dcfce7"
AMARELO        = "fef9c3"
AMARELO_ESCURO = "ca8a04"
VERMELHO       = "fee2e2"
VERMELHO_ESCURO= "dc2626"
CINZA          = "f1f5f9"
CINZA_BORDA    = "cbd5e1"
BRANCO         = "ffffff"
PRETO          = "0f172a"
AZUL_CLARO     = "eff6ff"
AZUL_ESCURO    = "1d4ed8"
LARANJA        = "fff7ed"
LARANJA_ESCURO = "c2410c"

BRL = '#,##0.00'
PCT = '0.0%'
PCT1 = '0.00%'

def borda():
    s = Side(style="thin", color=CINZA_BORDA)
    return Border(left=s, right=s, top=s, bottom=s)

def hdr(ws, row, col, value, fg=BRANCO, bg=VERDE_ESCURO, bold=True, sz=10, align="center"):
    c = ws.cell(row=row, column=col, value=value)
    c.font = Font(name="Calibri", bold=bold, size=sz, color=fg)
    c.fill = PatternFill("solid", fgColor=bg)
    c.alignment = Alignment(horizontal=align, vertical="center", wrap_text=True)
    c.border = borda()
    return c

def cel(ws, row, col, value, bold=False, color=PRETO, bg=BRANCO, align="left", fmt=None, sz=10):
    c = ws.cell(row=row, column=col, value=value)
    c.font = Font(name="Calibri", bold=bold, size=sz, color=color)
    c.fill = PatternFill("solid", fgColor=bg)
    c.alignment = Alignment(horizontal=align, vertical="center", wrap_text=False)
    c.border = borda()
    if fmt:
        c.number_format = fmt
    return c

def secao(ws, row, texto, ncols=8, bg=AZUL_ESCURO):
    ws.merge_cells(f"A{row}:{get_column_letter(ncols)}{row}")
    c = ws[f"A{row}"]
    c.value = texto
    c.font = Font(name="Calibri", bold=True, size=11, color=BRANCO)
    c.fill = PatternFill("solid", fgColor=bg)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[row].height = 20

# ── DADOS ABRIL 2026 ────────────────────────────────────────────────────────

FAT_BRUTO    = 541736.47   # ecletica_pagamentos, flag_canc <> 'C'
DESCONTOS    = 22186.85    # iFood e outros descontos
SERVICOS     =   892.46    # taxa de serviço
FAT_LIQUIDO  = 520442.08   # = bruto + serviços - descontos  (matches kpi_cmv_mensal)
CMV_TOTAL    = 216703.58   # total_compras em kpi_cmv_mensal 2026-04

# CMV por categoria (lógica DISTINCT ON idêntica à view kpi_cmv_mensal)
categorias = [
    # (categoria, total, classificacao, nota)
    ("Molhos Cozinha Central", 54948.05, "Disputável",
     "GREENJOY FRANQUEADORA (R$35.847) são royalties, não alimento. "
     "Só R$19.101 (GREENJOY COMERCIO) são insumo legítimo de cozinha central."),
    ("Hortaliças",             42881.86, "Alimento", ""),
    ("Queijos",                39805.37, "Disputável",
     "CAYENA TECNOLOGIA (R$19.431) é o sistema PDV Eclética — não é alimento. "
     "Queijos reais: R$20.375 (NOVA MEGA, LEVITARE, TIROLEZ)."),
    ("Embalagens",             22848.09, "Não-alimento",
     "Embalagens, rótulos, descartáveis — insumo operacional, não CMV de alimento."),
    ("Estoque Seco",           21267.32, "Alimento", ""),
    ("Sobremesas e Smoothies", 13212.26, "Alimento", ""),
    ("Proteínas",              11058.53, "Alimento", ""),
    ("Tortas",                  7271.10, "Alimento", ""),
    ("Bebidas",                 2628.56, "Alimento", ""),
    ("bebidas (typo)",           782.44, "Alimento",
     "Mesmo fornecedor de Bebidas — erro de capitalização no de-para."),
]

# Fornecedores por categoria (top contributors)
fornecedores = {
    "Molhos Cozinha Central": [
        ("GREENJOY FRANQUEADORA S.A. (2 pagamentos + 1 pagamento)", 35847.05, "ALERTA — royalties, não alimento"),
        ("GREENJOY COMERCIO DE ALIMENTOS LTDA", 19101.00, "Cozinha central — legítimo"),
    ],
    "Hortaliças": [
        ("CMC DISTRIBUIDORA DE HORTIFRU", 24254.04, ""),
        ("VERDUREIRA AGROINDUSTRIA S.A", 11300.50, ""),
        ("PREFERE DO CAMPO A MESA", 3614.76, ""),
        ("Vinicius C Da Silva", 1741.00, ""),
        ("Outros (4 fornecedores)", 1971.56, ""),
    ],
    "Queijos": [
        ("CAYENA TECNOLOGIA LTDA", 19430.65, "ALERTA — sistema PDV Eclética, não queijo"),
        ("NOVA MEGA G A ALIMENTOS S A", 13695.60, ""),
        ("LEVITARE", 4547.87, ""),
        ("LATICINIOS TIROLEZ", 2131.25, ""),
    ],
    "Embalagens": [
        ("FNS COMERCIO E IMPORTACAO LTDA", 11210.04, ""),
        ("UNIPEL IMPORTACAO E I E LTDA", 4435.66, ""),
        ("TUICIAL INDUSTRIA GRAFICA E EDITORA", 3102.85, ""),
        ("DM7 BRASIL (embalagens)", 1126.00, ""),
        ("Outros (4 fornecedores)", 2973.54, ""),
    ],
    "Estoque Seco": [
        ("MEX COMPANY FOODS LTDA", 7702.80, ""),
        ("MERCANTIL SANTA PAULA LTDA", 6001.88, ""),
        ("MADA FOODS", 2037.60, ""),
        ("DISTRIBUIDORA IRMAOS AVELI", 2031.60, ""),
        ("Outros (4 fornecedores)", 3493.44, ""),
    ],
    "Sobremesas e Smoothies": [
        ("NUTRILATINO IND COM EXP", 4009.36, ""),
        ("DISTRIBUIDOR DE MORANGOS LTDA", 3634.00, ""),
        ("SORVETERIA AL DUOMO LTDA", 2366.06, ""),
        ("Rfc Comercio De Miudezas Ltda", 1085.84, ""),
        ("Outros (4 fornecedores)", 2117.00, ""),
    ],
    "Proteínas": [
        ("ZANCHETTA ALIMENTOS LTDA", 8840.00, ""),
        ("FT SOLUCOES EM PESCADOS", 2218.53, ""),
    ],
    "Tortas": [
        ("BAKED ALIMENTOS LTDA", 7271.10, ""),
    ],
    "Bebidas": [
        ("SPAL IND BRAS BEBID", 2209.30, ""),
        ("WEWISH BEBIDAS SAUDAVEIS S.A.", 419.26, ""),
    ],
    "bebidas (typo)": [
        ("PIRAMIDES DISTRIBUIDORA LTDA", 782.44, "Mesma empresa de Bebidas — typo no de-para"),
    ],
}

# Reclassificações sugeridas
CAYENA_VAL    = 19430.65
GREENJOY_FR   = 35847.05
EMBALAGENS    = 22848.09
CMV_AJUSTADO  = CMV_TOTAL - CAYENA_VAL - GREENJOY_FR - EMBALAGENS


def main():
    wb = openpyxl.load_workbook(ARQUIVO)

    aba = "8. CMV Gross-to-Net"
    if aba in wb.sheetnames:
        del wb[aba]
    ws = wb.create_sheet(aba)

    # Larguras
    ws.column_dimensions["A"].width = 32
    ws.column_dimensions["B"].width = 20
    ws.column_dimensions["C"].width = 14
    ws.column_dimensions["D"].width = 14
    ws.column_dimensions["E"].width = 14
    ws.column_dimensions["F"].width = 14
    ws.column_dimensions["G"].width = 55

    # ── Título
    ws.merge_cells("A1:G1")
    c = ws["A1"]
    c.value = "CMV Gross-to-Net — Abril / 2026"
    c.font = Font(name="Calibri", bold=True, size=14, color=BRANCO)
    c.fill = PatternFill("solid", fgColor=VERDE_ESCURO)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[1].height = 30

    ws.merge_cells("A2:G2")
    c2 = ws["A2"]
    c2.value = ("Lógica idêntica à view kpi_cmv_mensal: btg_movimentacoes × jafeb_despesas_mapping "
                "WHERE natureza='Custo', JOIN UPPER(TRIM(nome_pagador_recebedor)) = UPPER(TRIM(descricao)), "
                "DISTINCT ON para evitar duplicatas. Mês: 2026-04.")
    c2.font = Font(name="Calibri", italic=True, size=9, color=PRETO)
    c2.fill = PatternFill("solid", fgColor=CINZA)
    c2.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[2].height = 14

    # ── SEÇÃO 1: Waterfall Faturamento
    secao(ws, 4, "FATURAMENTO LÍQUIDO — como chega ao denominador do CMV%", bg=VERDE_ESCURO)

    hdr(ws, 5, 1, "Componente",       align="left",   bg=VERDE_ESCURO)
    hdr(ws, 5, 2, "Valor R$",         align="right",  bg=VERDE_ESCURO)
    hdr(ws, 5, 3, "% do Bruto",       align="right",  bg=VERDE_ESCURO)
    hdr(ws, 5, 4, "Tickets / Obs.",   align="left",   bg=VERDE_ESCURO)
    ws.merge_cells("D5:G5")

    fat_rows = [
        ("(+) Faturamento Bruto",    FAT_BRUTO,   1.0,          "6.289 tickets — vlr_total (não cancelados)"),
        ("(+) Taxa de Serviço",      SERVICOS,    SERVICOS/FAT_BRUTO,  "vlr_serv — couvert / serviço"),
        ("(−) Descontos",           -DESCONTOS,  -DESCONTOS/FAT_BRUTO, "vlr_desc_tot — iFood e outros descontos"),
        ("= Faturamento Líquido",    FAT_LIQUIDO, FAT_LIQUIDO/FAT_BRUTO, "Denominador do CMV% no dashboard"),
    ]

    for i, (nome, val, pct, obs) in enumerate(fat_rows, 6):
        is_total = nome.startswith("=")
        bg = VERDE_CLARO if is_total else BRANCO
        bold = is_total
        sz = 11 if is_total else 10
        cel(ws, i, 1, nome,  bold=bold, bg=bg, sz=sz)
        cel(ws, i, 2, val,   bold=bold, bg=bg, align="right", fmt=BRL, sz=sz)
        cel(ws, i, 3, pct,   bold=bold, bg=bg, align="right", fmt=PCT1, sz=sz)
        ws.merge_cells(f"D{i}:G{i}")
        cel(ws, i, 4, obs,   bg=bg, sz=9, color="555555" if not is_total else PRETO)
        ws.row_dimensions[i].height = 16

    # ── SEÇÃO 2: CMV detalhado por categoria
    r = 11
    secao(ws, r, "CMV POR CATEGORIA — exatamente o que aparece no dashboard (kpi_cmv_mensal)", bg=AZUL_ESCURO)

    r += 1
    hdrs = ["Categoria (de-para)", "Total R$", "% do CMV", "% do Fat.", "Classificação", "Fornecedores / Alertas"]
    widths_used = [1, 2, 3, 4, 5, 6]
    for col, h in zip(widths_used, hdrs):
        hdr(ws, r, col, h, align="left" if col in [1,5,6] else "right", bg=AZUL_ESCURO)
    ws.merge_cells(f"F{r}:G{r}")
    ws.row_dimensions[r].height = 16

    r += 1
    for cat, total, classif, nota in categorias:
        pct_cmv = total / CMV_TOTAL
        pct_fat = total / FAT_LIQUIDO

        if classif == "Alimento":
            bg = BRANCO
            col_classif = "1a6b3c"
        elif classif == "Não-alimento":
            bg = AMARELO
            col_classif = AMARELO_ESCURO
        else:  # Disputável
            bg = VERMELHO
            col_classif = VERMELHO_ESCURO

        cel(ws, r, 1, cat,     bold=True, bg=bg)
        cel(ws, r, 2, total,   bold=True, bg=bg, align="right", fmt=BRL)
        cel(ws, r, 3, pct_cmv, bg=bg, align="right", fmt=PCT)
        cel(ws, r, 4, pct_fat, bg=bg, align="right", fmt=PCT)
        cel(ws, r, 5, classif, bg=bg, bold=True, color=col_classif)
        ws.merge_cells(f"F{r}:G{r}")
        cel(ws, r, 6, nota,    bg=bg, sz=9, color=VERMELHO_ESCURO if "ALERTA" in nota else AMARELO_ESCURO if nota else PRETO)
        ws.row_dimensions[r].height = 16
        r += 1

        # Fornecedores da categoria
        if cat in fornecedores:
            for forn, fval, fnota in fornecedores[cat]:
                is_alert = fnota.startswith("ALERTA")
                fbg = VERMELHO if is_alert else CINZA
                cel(ws, r, 1, f"   ↳ {forn}", sz=9, bg=fbg, color=VERMELHO_ESCURO if is_alert else "555555")
                cel(ws, r, 2, fval, sz=9, bg=fbg, align="right", fmt=BRL, bold=is_alert,
                    color=VERMELHO_ESCURO if is_alert else PRETO)
                cel(ws, r, 3, fval/CMV_TOTAL, sz=9, bg=fbg, align="right", fmt=PCT,
                    color=VERMELHO_ESCURO if is_alert else "555555")
                cel(ws, r, 4, "", bg=fbg)
                cel(ws, r, 5, "", bg=fbg)
                ws.merge_cells(f"F{r}:G{r}")
                cel(ws, r, 6, fnota, sz=9, bg=fbg,
                    color=VERMELHO_ESCURO if is_alert else AMARELO_ESCURO if fnota else "555555",
                    bold=is_alert)
                ws.row_dimensions[r].height = 14
                r += 1

    # Linha total CMV
    cel(ws, r, 1, "= CMV Total (dashboard)", bold=True, bg=AZUL_CLARO, sz=12)
    cel(ws, r, 2, CMV_TOTAL, bold=True, bg=AZUL_CLARO, align="right", fmt=BRL, sz=12)
    cel(ws, r, 3, 1.0,       bold=True, bg=AZUL_CLARO, align="right", fmt=PCT, sz=12)
    cel(ws, r, 4, CMV_TOTAL/FAT_LIQUIDO, bold=True, bg=AZUL_CLARO, align="right", fmt=PCT, sz=12)
    cel(ws, r, 5, "41.6% do Fat.", bold=True, bg=AZUL_CLARO, sz=12)
    ws.merge_cells(f"F{r}:G{r}")
    cel(ws, r, 6, "Este é o número que aparece em /compras e /socios", bold=True, bg=AZUL_CLARO)
    ws.row_dimensions[r].height = 20
    r += 1

    # ── SEÇÃO 3: Análise de reclassificação
    r += 1
    secao(ws, r, "ANÁLISE DE RECLASSIFICAÇÃO — o que deveria sair do CMV", bg=LARANJA_ESCURO)
    r += 1

    hdr(ws, r, 1, "Ajuste",              align="left", bg=LARANJA_ESCURO)
    hdr(ws, r, 2, "Valor R$",            align="right", bg=LARANJA_ESCURO)
    hdr(ws, r, 3, "Impacto CMV%",        align="right", bg=LARANJA_ESCURO)
    hdr(ws, r, 4, "Reclassificar para",  align="left",  bg=LARANJA_ESCURO)
    ws.merge_cells(f"D{r}:G{r}")
    ws.row_dimensions[r].height = 16
    r += 1

    ajustes = [
        ("CMV reportado (atual)",   CMV_TOTAL,    CMV_TOTAL/FAT_LIQUIDO,  ""),
        ("(−) Embalagens",         -EMBALAGENS,  -EMBALAGENS/FAT_LIQUIDO, "Despesa Operacional / Custo indireto"),
        ("(−) CAYENA TECNOLOGIA",  -CAYENA_VAL,  -CAYENA_VAL/FAT_LIQUIDO, "Despesa Operacional (sistema PDV)"),
        ("(−) GREENJOY FRANQUEADORA", -GREENJOY_FR, -GREENJOY_FR/FAT_LIQUIDO, "Royalties / Despesa de franquia"),
        ("= CMV Alimento Real",     CMV_AJUSTADO,  CMV_AJUSTADO/FAT_LIQUIDO, "Redução de 41.6% → 26.6%"),
    ]

    for nome, val, pct, reclass in ajustes:
        is_total = nome.startswith("=")
        is_start = nome.startswith("CMV reportado")
        bg = VERDE_CLARO if is_total else LARANJA if not (is_total or is_start) else BRANCO
        bold = is_total or is_start
        sz = 11 if is_total else 10

        cel(ws, r, 1, nome,    bold=bold, bg=bg, sz=sz)
        cel(ws, r, 2, val,     bold=bold, bg=bg, align="right", fmt=BRL, sz=sz,
            color=VERMELHO_ESCURO if val < 0 else PRETO)
        cel(ws, r, 3, pct,     bold=bold, bg=bg, align="right", fmt=PCT, sz=sz,
            color=VERMELHO_ESCURO if val < 0 else PRETO)
        ws.merge_cells(f"D{r}:G{r}")
        cel(ws, r, 4, reclass, bg=bg, sz=9 if not is_total else 10, bold=is_total,
            color="1a6b3c" if is_total else "555555")
        ws.row_dimensions[r].height = 18
        r += 1

    # Nota final
    r += 1
    ws.merge_cells(f"A{r}:G{r}")
    cn = ws[f"A{r}"]
    cn.value = ("Nota: reclassificações exigem alterar natureza em jafeb_despesas_mapping. "
                "Enquanto não feitas, o CMV% do dashboard permanece em 41.6% (abr/26).")
    cn.font = Font(name="Calibri", italic=True, size=9, color=PRETO)
    cn.fill = PatternFill("solid", fgColor=CINZA)
    cn.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[r].height = 14

    ws.freeze_panes = "A3"

    wb.save(ARQUIVO)
    print(f"Aba '{aba}' adicionada. Arquivo salvo: {ARQUIVO}")


if __name__ == "__main__":
    main()
