"""
analise_sazonalidade_cmv.py
Análise compras × demanda + índices de sazonalidade (6 meses) → Excel gerencial.
Output: ../docs/analise_cmv_sazonalidade_6m.xlsx
Rodar de: Greenjoy/database/
"""

import os
import calendar
import requests
from datetime import date

import pandas as pd
from dotenv import load_dotenv
from supabase import create_client

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Border, Side, Alignment
from openpyxl.utils import get_column_letter

load_dotenv()

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]
OUTPUT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "docs", "analise_cmv_sazonalidade_6m.xlsx"
)

MESES = [
    date(2025, 12, 1), date(2026, 1, 1), date(2026, 2, 1),
    date(2026, 3, 1),  date(2026, 4, 1), date(2026, 5, 1),
]
MES_LABELS = ["Dez/25", "Jan/26", "Fev/26", "Mar/26", "Abr/26", "Mai/26*"]

# Dec/2025 não está na view kpi_cmv_mensal — valor apurado direto do BTG
CMV_DEC25 = 204421.57

FERIADOS = [
    (date(2025, 12, 25), "Natal",                         "Nacional"),
    (date(2025, 12, 31), "Réveillon (impacto tarde)",     "Cultural"),
    (date(2026,  1,  1), "Confraternização Universal",    "Nacional"),
    (date(2026,  1, 25), "Aniversário de São Paulo",      "Municipal"),
    (date(2026,  2, 16), "Segunda de Carnaval",           "Ponto facultativo"),
    (date(2026,  2, 17), "Terça de Carnaval",             "Ponto facultativo"),
    (date(2026,  2, 18), "Quarta de Cinzas",              "Meio período"),
    (date(2026,  4,  3), "Paixão de Cristo",              "Nacional"),
    (date(2026,  4,  5), "Páscoa",                        "Nacional"),
    (date(2026,  4, 21), "Tiradentes",                    "Nacional"),
    (date(2026,  5,  1), "Dia do Trabalho",               "Nacional"),
]

IMPACTOS = {
    "Natal":                        "Alta demanda família; cardápio festivo pode elevar ticket",
    "Réveillon (impacto tarde)":    "Queda no almoço; iFood tende a crescer à noite",
    "Confraternização Universal":   "Loja possivelmente sem equipe; prever volume reduzido",
    "Aniversário de São Paulo":     "Ponto facultativo; queda de movimento corporativo",
    "Segunda de Carnaval":          "Forte queda de movimento; revisar pedido de compras da semana",
    "Terça de Carnaval":            "Idem — proteínas e hortifruti podem sobrar",
    "Quarta de Cinzas":             "Retomada parcial; demanda de jantar cresce",
    "Paixão de Cristo":             "Cardápio sem carne vermelha muda mix de compras",
    "Páscoa":                       "Domingo de alta rotação; sobremesas e chocolates sobem",
    "Tiradentes":                   "Feriado nacional; prever queda de 15-20% vs dia normal",
    "Dia do Trabalho":              "Feriado nacional; antecipação de compras na quinta",
}


# ── Busca de dados ────────────────────────────────────────────────────────────

def prox_mes(mes: date) -> date:
    y, m = (mes.year + 1, 1) if mes.month == 12 else (mes.year, mes.month + 1)
    return date(y, m, 1)


def fetch_vendas(sb) -> pd.DataFrame:
    """
    Faturamento via kpi_cmv_mensal (Jan-Mai/26 — view já agrega o banco todo).
    Dez/25 e pedidos/ticket via resumo_mensal_historico.
    Evita o limite de 1000 linhas do PostgREST em ecletica_pagamentos.
    """
    # kpi_cmv_mensal: já tem faturamento_mes (líquido) para Jan-Mai/26
    resp_kpi = (
        sb.table("kpi_cmv_mensal")
        .select("mes, faturamento_mes, total_compras, cmv_pct")
        .gte("mes", "2026-01")
        .execute()
    )
    kpi_map = {
        date(int(r["mes"][:4]), int(r["mes"][5:7]), 1): r
        for r in resp_kpi.data
    }

    # resumo_mensal_historico: pedidos e ticket para Dez/25–Abr/26 (meses completos)
    resp_hist = (
        sb.table("resumo_mensal_historico")
        .select("mes, pedidos_total, faturamento_total, ticket_medio_geral")
        .gte("mes", "2025-12-01")
        .execute()
    )
    hist_map = {
        pd.Timestamp(r["mes"]).date().replace(day=1): r
        for r in resp_hist.data
    }

    rows = []
    for mes in MESES:
        kpi = kpi_map.get(mes)
        hist = hist_map.get(mes)

        if kpi:
            fat = float(kpi["faturamento_mes"]) if kpi.get("faturamento_mes") else None
        elif mes == date(2025, 12, 1):
            fat = 571169.54  # Dec/25 verificado via MCP (ecletica_pagamentos líquido)
        else:
            fat = float(hist["faturamento_total"]) if hist else None

        ped = int(hist["pedidos_total"]) if hist else None
        tick = float(hist["ticket_medio_geral"]) if hist else None

        rows.append({
            "mes": mes,
            "faturamento_liq": fat,
            "pedidos": ped,
            "ticket_medio": tick,
        })
    return pd.DataFrame(rows)


def fetch_cmv(sb) -> pd.DataFrame:
    """kpi_cmv_mensal cobre Jan–Mai/26. Dez/25 apurado direto do BTG via MCP."""
    resp = (
        sb.table("kpi_cmv_mensal")
        .select("mes, total_compras")
        .gte("mes", "2026-01")
        .execute()
    )
    rows = [
        {"mes": date(int(r["mes"][:4]), int(r["mes"][5:7]), 1),
         "cmv_total": float(r["total_compras"])}
        for r in resp.data
    ]
    rows.insert(0, {"mes": date(2025, 12, 1), "cmv_total": CMV_DEC25})
    return pd.DataFrame(rows)


def fetch_categorias(sb) -> pd.DataFrame:
    """nf_itens tem detalhe de categoria a partir de Abr/2026."""
    resp = (
        sb.table("nf_itens")
        .select("data_lancamento, categoria, vlr_total, num_nf, fornecedor")
        .gte("data_lancamento", "2026-04-01")
        .not_.is_("categoria", "null")
        .range(0, 4999)
        .execute()
    )
    df = pd.DataFrame(resp.data)
    if df.empty:
        return df
    df["mes"] = pd.to_datetime(df["data_lancamento"]).dt.to_period("M").apply(
        lambda p: p.to_timestamp().date()
    )
    df["vlr_total"] = pd.to_numeric(df["vlr_total"], errors="coerce").fillna(0)
    return (
        df.groupby(["mes", "categoria"])
        .agg(vlr_compras=("vlr_total", "sum"),
             nfs=("num_nf", "nunique"),
             fornecedores=("fornecedor", "nunique"))
        .reset_index()
    )


def fetch_clima() -> pd.DataFrame:
    """Open-Meteo (gratuito, sem chave) — histórico diário SP → agregado mensal."""
    resp = requests.get(
        "https://archive-api.open-meteo.com/v1/archive",
        params={
            "latitude": -23.5505, "longitude": -46.6333,
            "start_date": "2025-12-01", "end_date": "2026-05-25",
            "daily": "temperature_2m_mean,precipitation_sum",
            "timezone": "America/Sao_Paulo",
        },
        timeout=30,
    )
    resp.raise_for_status()
    d = resp.json()["daily"]
    df = pd.DataFrame({
        "data": pd.to_datetime(d["time"]),
        "temp": d["temperature_2m_mean"],
        "precip": d["precipitation_sum"],
    })
    df["mes"] = df["data"].dt.to_period("M").apply(lambda p: p.to_timestamp().date())
    return df.groupby("mes").agg(
        temp_media=("temp", "mean"),
        precip_total=("precip", "sum"),
        dias_chuva=("precip", lambda x: (x > 1.0).sum()),
    ).reset_index()


# ── Helpers de estilo ─────────────────────────────────────────────────────────

VERDE_DARK = "1A5C38"
VERDE_LIGHT = "D6F0E0"
AMARELO = "FFF3CD"
VERMELHO = "F8D7DA"
CINZA_ALT = "F5F5F5"

FNT_TITULO = Font(name="Calibri", size=13, bold=True, color=VERDE_DARK)
FNT_HEADER = Font(name="Calibri", size=10, bold=True, color="FFFFFF")
FNT_BODY = Font(name="Calibri", size=10)
FNT_BOLD = Font(name="Calibri", size=10, bold=True)
FNT_NOTA = Font(name="Calibri", size=9, italic=True, color="666666")

AL_C = Alignment(horizontal="center", vertical="center", wrap_text=True)
AL_R = Alignment(horizontal="right", vertical="center")
AL_L = Alignment(horizontal="left", vertical="center", wrap_text=True)

BRL = '#,##0.00'
PCT = '0.0"%"'
INT = '#,##0'
DEC1 = '0.0'

def fill(hex_c: str) -> PatternFill:
    return PatternFill("solid", fgColor=hex_c)

def thin_border() -> Border:
    s = Side(style="thin", color="BBBBBB")
    return Border(left=s, right=s, top=s, bottom=s)

def semaforo_cmv(pct) -> PatternFill:
    if pct is None:
        return None
    if pct <= 33.0:  return fill(VERDE_LIGHT)
    if pct <= 36.0:  return fill(AMARELO)
    return fill(VERMELHO)

def set_w(ws, col: int, w: float):
    ws.column_dimensions[get_column_letter(col)].width = w

def hcell(ws, row, col, val):
    c = ws.cell(row=row, column=col, value=val)
    c.font = FNT_HEADER; c.fill = fill(VERDE_DARK)
    c.alignment = AL_C; c.border = thin_border()
    return c

def dcell(ws, row, col, val, fmt=None, bg=None):
    c = ws.cell(row=row, column=col, value=val)
    c.font = FNT_BODY; c.alignment = AL_R; c.border = thin_border()
    if fmt: c.number_format = fmt
    if bg: c.fill = bg
    return c


# ── Sheet 1: Resumo Executivo ─────────────────────────────────────────────────

def build_resumo(ws, df: pd.DataFrame):
    ws.title = "Resumo Executivo"
    ws.sheet_view.showGridLines = False

    ws.merge_cells("A1:N1")
    c = ws["A1"]
    c.value = "Análise CMV × Demanda × Sazonalidade  |  Dez/2025 – Mai/2026"
    c.font = FNT_TITULO; c.alignment = AL_L; c.fill = fill("F0F7F2")
    ws.row_dimensions[1].height = 26

    ws.merge_cells("A2:N2")
    n = ws["A2"]
    n.value = (
        "Fonte: PDV Eclética (faturamento líquido)  |  BTG Movimentações (CMV)  |  Open-Meteo (clima São Paulo / SP)  |  "
        "CMV%: Meta ≤ 33%   |   Atenção 33–36%   |   Crítico > 36%   |   * Mai/26 parcial até ~26/mai"
    )
    n.font = FNT_NOTA; n.alignment = AL_L

    COLS = [
        "Mês", "Faturamento\nLíquido", "CMV\nTotal", "CMV%", "Meta\nCMV%",
        "Pedidos", "Ticket\nMédio", "Fat/Dia", "CMV/\nPedido",
        "Dias c/\nChuva", "Precip.\n(mm)", "Temp.\nMédia °C",
        "Feriados", "Eventos / Observações",
    ]
    widths = [9, 16, 15, 9, 9, 9, 12, 14, 12, 10, 10, 12, 9, 35]
    for i, (col, w) in enumerate(zip(COLS, widths), 1):
        hcell(ws, 3, i, col)
        set_w(ws, i, w)
    ws.row_dimensions[3].height = 34

    for r, row in enumerate(df.itertuples(), start=4):
        alt = fill(CINZA_ALT) if r % 2 == 0 else None

        fat = getattr(row, "faturamento_liq", None)
        cmv = getattr(row, "cmv_total", None)
        ped = getattr(row, "pedidos", None)
        tick = getattr(row, "ticket_medio", None)
        precip = getattr(row, "precip_total", None)
        temp = getattr(row, "temp_media", None)
        dias_c = getattr(row, "dias_chuva", None)
        n_fer = getattr(row, "n_feriados", 0)
        dias_m = getattr(row, "dias_mes", 30)
        obs_txt = getattr(row, "obs", "")

        cmv_pct = round(cmv / fat * 100, 1) if fat and cmv else None
        fat_dia = round(fat / dias_m, 0) if fat else None
        cmv_ped = round(cmv / ped, 2) if cmv and ped else None

        label = ws.cell(row=r, column=1, value=MES_LABELS[r - 4])
        label.font = FNT_BOLD; label.alignment = AL_C
        label.border = thin_border()
        if alt: label.fill = alt

        dcell(ws, r, 2, fat, BRL, alt)
        dcell(ws, r, 3, cmv, BRL, alt)
        dcell(ws, r, 4, cmv_pct, PCT, semaforo_cmv(cmv_pct))
        dcell(ws, r, 5, 33.0, PCT, alt)
        dcell(ws, r, 6, ped, INT, alt)
        dcell(ws, r, 7, tick, BRL, alt)
        dcell(ws, r, 8, fat_dia, BRL, alt)
        dcell(ws, r, 9, cmv_ped, BRL, alt)
        dcell(ws, r, 10, dias_c, INT, alt)
        dcell(ws, r, 11, round(precip, 1) if precip is not None else None, DEC1, alt)
        dcell(ws, r, 12, round(temp, 1) if temp is not None else None, DEC1, alt)
        dcell(ws, r, 13, n_fer, INT, alt)
        oc = ws.cell(row=r, column=14, value=obs_txt)
        oc.font = FNT_NOTA; oc.alignment = AL_L; oc.border = thin_border()
        if alt: oc.fill = alt

    # Totais
    tr = len(df) + 4
    fat_tot = df["faturamento_liq"].sum()
    cmv_tot = df["cmv_total"].sum()
    pct_med = round(cmv_tot / fat_tot * 100, 1) if fat_tot else None

    for i in range(1, 15):
        ws.cell(row=tr, column=i).border = thin_border()
        ws.cell(row=tr, column=i).fill = fill("E8F5EC")

    t = ws.cell(row=tr, column=1, value="TOTAL / MÉD")
    t.font = FNT_BOLD; t.alignment = AL_C; t.border = thin_border(); t.fill = fill("E8F5EC")

    for col, val, fmt in [(2, fat_tot, BRL), (3, cmv_tot, BRL),
                           (6, int(df["pedidos"].sum()), INT)]:
        c = ws.cell(row=tr, column=col, value=val)
        c.number_format = fmt; c.font = FNT_BOLD; c.alignment = AL_R
        c.border = thin_border(); c.fill = fill("E8F5EC")

    pct_c = ws.cell(row=tr, column=4, value=pct_med)
    pct_c.number_format = PCT; pct_c.font = FNT_BOLD; pct_c.alignment = AL_R
    pct_c.border = thin_border()
    pct_c.fill = semaforo_cmv(pct_med) or fill("E8F5EC")

    # Legenda
    lr = tr + 2
    ws.cell(row=lr, column=1, value="Legenda CMV%:").font = FNT_BOLD
    for txt, hex_c, col in [("≤ 33% Ótimo", VERDE_LIGHT, 2),
                              ("33–36% Atenção", AMARELO, 3),
                              ("> 36% Crítico", VERMELHO, 4)]:
        c = ws.cell(row=lr, column=col, value=txt)
        c.fill = fill(hex_c); c.font = FNT_BOLD
        c.alignment = AL_C; c.border = thin_border()


# ── Sheet 2: Sazonalidade ─────────────────────────────────────────────────────

def build_sazonalidade(ws, df: pd.DataFrame):
    ws.title = "Sazonalidade"
    ws.sheet_view.showGridLines = False

    ws.merge_cells("A1:J1")
    ws["A1"].value = "Índices de Sazonalidade — Clima, Feriados e Demanda"
    ws["A1"].font = FNT_TITULO; ws["A1"].alignment = AL_L

    COLS = ["Mês", "Pedidos", "Faturamento\nLíquido", "CMV\nTotal", "CMV%",
            "Precip.\n(mm)", "Temp.\nMédia °C", "Dias c/\nChuva",
            "Feriados", "Índice\nDemanda*"]
    widths = [9, 9, 16, 15, 9, 12, 13, 12, 9, 13]
    for i, (col, w) in enumerate(zip(COLS, widths), 1):
        hcell(ws, 3, i, col)
        set_w(ws, i, w)
    ws.row_dimensions[3].height = 34

    base_ped = df.iloc[0]["pedidos"] if not df.empty else 1

    for r, row in enumerate(df.itertuples(), start=4):
        alt = fill(CINZA_ALT) if r % 2 == 0 else None
        fat = getattr(row, "faturamento_liq", None)
        cmv = getattr(row, "cmv_total", None)
        ped = getattr(row, "pedidos", None)
        cmv_pct = round(cmv / fat * 100, 1) if fat and cmv else None
        idx = round(ped / base_ped * 100, 1) if ped else None
        precip = getattr(row, "precip_total", None)
        temp = getattr(row, "temp_media", None)

        lb = ws.cell(row=r, column=1, value=MES_LABELS[r - 4])
        lb.font = FNT_BOLD; lb.alignment = AL_C; lb.border = thin_border()
        if alt: lb.fill = alt

        dcell(ws, r, 2, ped, INT, alt)
        dcell(ws, r, 3, fat, BRL, alt)
        dcell(ws, r, 4, cmv, BRL, alt)
        dcell(ws, r, 5, cmv_pct, PCT, semaforo_cmv(cmv_pct))
        dcell(ws, r, 6, round(precip, 1) if precip is not None else None, DEC1, alt)
        dcell(ws, r, 7, round(temp, 1) if temp is not None else None, DEC1, alt)
        dcell(ws, r, 8, getattr(row, "dias_chuva", None), INT, alt)
        dcell(ws, r, 9, getattr(row, "n_feriados", 0), INT, alt)
        dcell(ws, r, 10, idx, DEC1, alt)

    ws.cell(row=len(df)+5, column=1,
            value="* Índice Demanda: base 100 = Dez/25. Valor < 100 indica queda relativa de pedidos.").font = FNT_NOTA

    # Tabela de feriados
    fr = len(df) + 8
    ws.merge_cells(f"A{fr}:E{fr}")
    ws[f"A{fr}"].value = "Calendário de Feriados e Eventos — Impacto Esperado"
    ws[f"A{fr}"].font = Font(name="Calibri", size=11, bold=True, color=VERDE_DARK)
    set_w(ws, 1, 13); set_w(ws, 2, 32); set_w(ws, 3, 18); set_w(ws, 4, 9); set_w(ws, 5, 52)

    for i, col in enumerate(["Data", "Feriado / Evento", "Tipo", "Mês", "Impacto Esperado"], 1):
        hcell(ws, fr + 1, i, col)

    for i, (d, nome, tipo) in enumerate(FERIADOS, start=fr + 2):
        mes_idx = next((j for j, m in enumerate(MESES) if m.year == d.year and m.month == d.month), -1)
        mes_label = MES_LABELS[mes_idx] if mes_idx >= 0 else ""
        alt = fill(CINZA_ALT) if i % 2 == 0 else None
        for col, val in [(1, d.strftime("%d/%m/%Y")), (2, nome), (3, tipo),
                         (4, mes_label), (5, IMPACTOS.get(nome, "—"))]:
            c = ws.cell(row=i, column=col, value=val)
            c.font = FNT_BODY; c.alignment = AL_L; c.border = thin_border()
            if alt: c.fill = alt


# ── Sheet 3: Compras por Categoria ────────────────────────────────────────────

def build_categorias(ws, df_cat: pd.DataFrame, df_vendas: pd.DataFrame):
    ws.title = "Compras por Categoria"
    ws.sheet_view.showGridLines = False

    ws.merge_cells("A1:G1")
    ws["A1"].value = "Compras por Categoria Gerencial — Abr/26 e Mai/26 (NF Everest)"
    ws["A1"].font = FNT_TITULO; ws["A1"].alignment = AL_L

    ws.merge_cells("A2:G2")
    ws["A2"].value = (
        "Detalhe de NF disponível a partir de Abr/2026. "
        "Meses anteriores: apenas CMV total via BTG (sem quebra por categoria). "
        "Mai/26 = dados parciais."
    )
    ws["A2"].font = FNT_NOTA; ws["A2"].alignment = AL_L

    if df_cat.empty:
        ws.cell(row=4, column=1, value="Sem dados de NF disponíveis.").font = FNT_NOTA
        return

    meses_cat = sorted(df_cat["mes"].unique())
    pivot = df_cat.pivot_table(index="categoria", columns="mes",
                               values="vlr_compras", aggfunc="sum").fillna(0)
    categorias = pivot.sum(axis=1).sort_values(ascending=False).index.tolist()

    col_labels = (["Categoria"]
                  + [MES_LABELS[MESES.index(m)] for m in meses_cat
                     if m in MESES]
                  + ["Total R$", "% Total", "% Fat."])
    for i, (lab, w) in enumerate(zip(
        col_labels,
        [36] + [16] * len(meses_cat) + [16, 10, 10]
    ), 1):
        hcell(ws, 4, i, lab)
        set_w(ws, i, w)
    ws.row_dimensions[4].height = 28

    grand = float(pivot.values.sum())

    for r, cat in enumerate(categorias, start=5):
        alt = fill(CINZA_ALT) if r % 2 == 0 else None
        lc = ws.cell(row=r, column=1, value=cat.title())
        lc.font = FNT_BODY; lc.alignment = AL_L; lc.border = thin_border()
        if alt: lc.fill = alt

        row_tot = 0.0
        for c, mes in enumerate(meses_cat, start=2):
            val = float(pivot.loc[cat, mes]) if cat in pivot.index and mes in pivot.columns else 0
            row_tot += val
            dcell(ws, r, c, val or None, BRL, alt)

        dcell(ws, r, len(meses_cat) + 2, row_tot, BRL, alt)
        dcell(ws, r, len(meses_cat) + 3, round(row_tot / grand * 100, 1) if grand else None, PCT, alt)

        # % do faturamento do período combinado
        fat_periodo = sum(
            float(df_vendas[df_vendas["mes"] == m]["faturamento_liq"].values[0])
            for m in meses_cat
            if not df_vendas[df_vendas["mes"] == m].empty
        )
        dcell(ws, r, len(meses_cat) + 4,
              round(row_tot / fat_periodo * 100, 1) if fat_periodo else None, PCT, alt)

    # Linha de total
    tr = len(categorias) + 5
    ws.cell(row=tr, column=1, value="TOTAL").font = FNT_BOLD
    ws.cell(row=tr, column=1).alignment = AL_C
    ws.cell(row=tr, column=1).border = thin_border()
    ws.cell(row=tr, column=1).fill = fill("E8F5EC")

    for c, mes in enumerate(meses_cat, start=2):
        val = float(pivot[mes].sum()) if mes in pivot.columns else 0
        cc = ws.cell(row=tr, column=c, value=val)
        cc.number_format = BRL; cc.font = FNT_BOLD
        cc.alignment = AL_R; cc.border = thin_border(); cc.fill = fill("E8F5EC")

    gt = ws.cell(row=tr, column=len(meses_cat) + 2, value=grand)
    gt.number_format = BRL; gt.font = FNT_BOLD; gt.alignment = AL_R
    gt.border = thin_border(); gt.fill = fill("E8F5EC")

    ws.cell(row=tr + 2, column=1,
            value="% Fat. = Total de compras NF da categoria ÷ Faturamento Líquido do período (Abr+Mai/26). "
                  "CMV BTG inclui pagamentos fora das NFs.").font = FNT_NOTA


# ── Sheet 4: Oportunidades ────────────────────────────────────────────────────

def build_oportunidades(ws, df: pd.DataFrame):
    ws.title = "Oportunidades CMV"
    ws.sheet_view.showGridLines = False

    set_w(ws, 1, 4); set_w(ws, 2, 30); set_w(ws, 3, 72)

    ws.merge_cells("B1:C1")
    ws["B1"].value = "Oportunidades de Redução do CMV — Análise 6 Meses (Dez/25–Mai/26)"
    ws["B1"].font = FNT_TITULO; ws["B1"].alignment = AL_L

    fat_tot = df["faturamento_liq"].sum()
    cmv_tot = df["cmv_total"].sum()
    pct_real = cmv_tot / fat_tot * 100 if fat_tot else 0
    eco_33 = cmv_tot - fat_tot * 0.33
    eco_30 = cmv_tot - fat_tot * 0.30

    oportunidades = [
        (
            "1. COMPRAS PRÉ-FERIADO SEM AJUSTE DE DEMANDA",
            (
                f"Abr/26 (CMV {df.loc[df['mes']==date(2026,4,1),'cmv_total'].values[0]/df.loc[df['mes']==date(2026,4,1),'faturamento_liq'].values[0]*100:.1f}%) "
                f"e Dez/25 (CMV {CMV_DEC25/df.loc[df['mes']==date(2025,12,1),'faturamento_liq'].values[0]*100:.1f}%) são os piores meses — "
                f"ambos com feriados de alto impacto (Páscoa, Tiradentes, Natal). "
                f"O volume de compras não recuou proporcionalmente à queda de pedidos. "
                f"Ação: criar calendário de compras com fator de redução por feriado — "
                f"sugestão: -15% proteínas, -10% hortifruti em semanas com feriado prolongado."
            ),
        ),
        (
            "2. HORTIFRUTI — MAIOR RISCO DE DESPERDÍCIO",
            (
                "Hortifruti ultrapassou Proteínas em Mai/26 (R$21k vs R$20,7k) e tem alta variação de preço sazonal. "
                "8 fornecedores/mês indicam compras fragmentadas sem negociação de volume. "
                "Ação: pedido semanal baseado em cobertura de dias (pedidos/dia semana anterior × fator feriado), "
                "não por volume fixo mensal. Meta: consolidar em 4-5 fornecedores para ganho de 5-8% no preço."
            ),
        ),
        (
            "3. SAZONALIDADE CLIMÁTICA — CHUVAS E TEMPERATURA",
            (
                "Dez-Fev é o período de maior precipitação em SP (estação chuvosa). "
                "Chuvas reduzem público presencial mas elevam iFood — o mix de canais muda o mix de produtos. "
                "Ação: em meses com precipitação acima de 150mm, reduzir ingredientes de pratos de salão "
                "e ampliar insumos de delivery. Cruzar dados de precip. × faturamento iFood mensalmente."
            ),
        ),
        (
            "4. JANEIRO — REFERÊNCIA DE EFICIÊNCIA (CMV 28,2%)",
            (
                "Jan/26 é o melhor mês do período: CMV 28,2%, menor faturamento, mas compras bem dimensionadas. "
                "Provável uso de estoque do Natal + equipe mais criteriosa sem pressão de demanda. "
                "Ação: replicar a disciplina de Jan nos demais meses — "
                "realizar inventário completo na última semana do mês anterior antes de autorizar pedidos."
            ),
        ),
        (
            "5. CARNAVAL — OPORTUNIDADE DE REDUÇÃO PONTUAL",
            (
                "Fev/26 (CMV 33,2%) com Carnaval Feb/16-17: queda previsível e mensurável de movimento. "
                "Ação: reduzir pedido da semana de Carnaval em 20-25%; "
                "negociar entrega parcelada de proteínas para essa semana. "
                "Potencial de economia: ~R$8-10k em compras evitadas."
            ),
        ),
        (
            "6. POTENCIAL DE REDUÇÃO CALCULADO",
            (
                f"CMV% médio realizado no período: {pct_real:.1f}%\n"
                f"Meta conservadora (33%): economia acumulada de R${eco_33:,.0f} no semestre "
                f"(~R${eco_33/6:,.0f}/mês)\n"
                f"Meta agressiva (30%): economia acumulada de R${eco_30:,.0f} no semestre "
                f"(~R${eco_30/6:,.0f}/mês)\n"
                f"A diferença entre 33% e 30% representa aproximadamente "
                f"R${(eco_33-eco_30)/6:,.0f}/mês de margem adicional."
            ),
        ),
    ]

    row = 3
    for titulo, desc in oportunidades:
        ws.row_dimensions[row].height = 18
        ws.merge_cells(f"B{row}:C{row}")
        t = ws.cell(row=row, column=2, value=titulo)
        t.font = Font(name="Calibri", size=10, bold=True, color="FFFFFF")
        t.fill = fill(VERDE_DARK); t.alignment = AL_L; t.border = thin_border()
        ws.cell(row=row, column=3).fill = fill(VERDE_DARK); ws.cell(row=row, column=3).border = thin_border()
        row += 1

        for linha in desc.split("\n"):
            ws.row_dimensions[row].height = 42
            ws.merge_cells(f"B{row}:C{row}")
            d = ws.cell(row=row, column=2, value=linha)
            d.font = FNT_BODY
            d.alignment = Alignment(horizontal="left", vertical="top", wrap_text=True)
            d.border = thin_border()
            row += 1

        ws.row_dimensions[row].height = 8
        row += 1

    ws.cell(row=row + 1, column=2,
            value=f"Gerado em {date.today().strftime('%d/%m/%Y')}  |  "
                  f"Eclética (PDV) + BTG (CMV) + Open-Meteo (Clima SP)").font = FNT_NOTA


# ── Main ──────────────────────────────────────────────────────────────────────

def feriados_mes(mes: date) -> list:
    return [(d, n, t) for d, n, t in FERIADOS
            if d.year == mes.year and d.month == mes.month]


def obs_mes(mes: date) -> str:
    nomes = [n for _, n, _ in feriados_mes(mes)]
    return "; ".join(nomes) if nomes else "Sem feriados"


def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)

    print("Buscando vendas (ecletica_pagamentos)...")
    df_vendas = fetch_vendas(sb)

    print("Buscando CMV (BTG / kpi_cmv_mensal)...")
    df_cmv = fetch_cmv(sb)

    print("Buscando compras por categoria (nf_itens)...")
    df_cat = fetch_categorias(sb)

    print("Buscando clima (Open-Meteo SP)...")
    df_clima = fetch_clima()

    # Unificar por mês
    rows = []
    for mes in MESES:
        v = df_vendas[df_vendas["mes"] == mes]
        c = df_cmv[df_cmv["mes"] == mes]
        cl = df_clima[df_clima["mes"] == mes]
        rows.append({
            "mes": mes,
            "faturamento_liq": float(v["faturamento_liq"].values[0]) if not v.empty else None,
            "pedidos": int(v["pedidos"].values[0]) if not v.empty else None,
            "ticket_medio": float(v["ticket_medio"].values[0]) if not v.empty else None,
            "cmv_total": float(c["cmv_total"].values[0]) if not c.empty else None,
            "precip_total": float(cl["precip_total"].values[0]) if not cl.empty else None,
            "temp_media": float(cl["temp_media"].values[0]) if not cl.empty else None,
            "dias_chuva": int(cl["dias_chuva"].values[0]) if not cl.empty else None,
            "n_feriados": len(feriados_mes(mes)),
            "dias_mes": calendar.monthrange(mes.year, mes.month)[1],
            "obs": obs_mes(mes),
        })
    df = pd.DataFrame(rows)

    print("Gerando Excel...")
    wb = Workbook()
    build_resumo(wb.active, df)
    build_sazonalidade(wb.create_sheet(), df)
    build_categorias(wb.create_sheet(), df_cat, df_vendas)
    build_oportunidades(wb.create_sheet(), df)

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    wb.save(OUTPUT_PATH)
    print(f"\nSalvo em: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
