"""
gerar_auditoria_kpis.py — Auditoria de todos os KPIs do dashboard Greenjoy
Gera Excel com análise de fontes, inconsistências e valores reais para validação.
"""
import os
from datetime import date
from dotenv import load_dotenv

load_dotenv()
from supabase import create_client
import openpyxl
from openpyxl.styles import (
    Font, PatternFill, Alignment, Border, Side, numbers
)
from openpyxl.utils import get_column_letter

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]

VERDE_ESCURO  = "1a6b3c"
VERDE         = "22c55e"
VERDE_CLARO   = "dcfce7"
AMARELO       = "fef9c3"
AMARELO_ESCURO= "ca8a04"
VERMELHO      = "fee2e2"
VERMELHO_ESCURO="dc2626"
CINZA         = "f1f5f9"
CINZA_BORDA   = "cbd5e1"
BRANCO        = "ffffff"
PRETO         = "0f172a"

def hdr(ws, row, col, value, fg=VERDE_ESCURO, bg=VERDE_CLARO, bold=True, sz=11):
    c = ws.cell(row=row, column=col, value=value)
    c.font = Font(name="Calibri", bold=bold, size=sz, color=fg)
    c.fill = PatternFill("solid", fgColor=bg)
    c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    c.border = thin_border()
    return c

def cell(ws, row, col, value, bold=False, color=PRETO, bg=BRANCO, align="left", fmt=None, sz=10):
    c = ws.cell(row=row, column=col, value=value)
    c.font = Font(name="Calibri", bold=bold, size=sz, color=color)
    c.fill = PatternFill("solid", fgColor=bg)
    c.alignment = Alignment(horizontal=align, vertical="center", wrap_text=True)
    c.border = thin_border()
    if fmt:
        c.number_format = fmt
    return c

def thin_border():
    s = Side(style="thin", color=CINZA_BORDA)
    return Border(left=s, right=s, top=s, bottom=s)

def titulo_aba(ws, texto, subtexto=""):
    ws.merge_cells("A1:J1")
    c = ws["A1"]
    c.value = texto
    c.font = Font(name="Calibri", bold=True, size=14, color=BRANCO)
    c.fill = PatternFill("solid", fgColor=VERDE_ESCURO)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[1].height = 30
    if subtexto:
        ws.merge_cells("A2:J2")
        c2 = ws["A2"]
        c2.value = subtexto
        c2.font = Font(name="Calibri", italic=True, size=10, color=PRETO)
        c2.fill = PatternFill("solid", fgColor=CINZA)
        c2.alignment = Alignment(horizontal="left", vertical="center")
        ws.row_dimensions[2].height = 18

def fmt_brl(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0

def fmt_pct(v):
    try:
        return float(v) / 100
    except (TypeError, ValueError):
        return 0.0

BRL = '#,##0.00'
PCT = '0.0%'
N0  = '#,##0'

def main():
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)
    wb = openpyxl.Workbook()
    wb.remove(wb.active)

    # ===========================================================
    # ABA 1: RESUMO — PROBLEMAS E INCONSISTÊNCIAS
    # ===========================================================
    ws = wb.create_sheet("1. Problemas e Ações")
    titulo_aba(ws, "Auditoria de KPIs — Greenjoy Anália Franco",
               f"Gerado em {date.today().strftime('%d/%m/%Y')} · Validar cada ponto antes de corrigir o dashboard")

    headers = ["#", "Severidade", "KPI / Tela", "Problema Identificado", "Impacto", "Ação Recomendada"]
    widths  = [4, 12, 25, 55, 30, 40]
    for i, (h, w) in enumerate(zip(headers, widths), 1):
        hdr(ws, 3, i, h, fg=BRANCO, bg=VERDE_ESCURO, sz=10)
        ws.column_dimensions[get_column_letter(i)].width = w

    problemas = [
        (1, "CRÍTICO",
         "CMV% (/compras, /sócios)",
         "CMV% inclui Embalagens (10.5% do custo em abr/26) e CAYENA TECNOLOGIA R$122k (sistema Eclética — PDV). Não é apenas alimentação.",
         "CMV% superestimado. Meta 33% fica distorcida.",
         "Reclassificar CAYENA como 'Despesa Operacional' no de-para. Decidir se Embalagens entra no CMV ou sai."),

        (2, "CRÍTICO",
         "CMV% (/compras, /sócios)",
         "GREENJOY FRANQUEADORA S.A. mapeada como 'Custo' (R$141k em 6 meses). São royalties/taxas de franquia, não insumo de alimento.",
         "CMV% inflado por royalties, distorcendo comparação com benchmarks de restaurante.",
         "Reclassificar GREENJOY FRANQUEADORA como 'Royalties' (natureza Despesa) no de-para."),

        (3, "ALTO",
         "Curva ABC Fornecedor (/compras)",
         "kpi_curva_abc_fornecedor usa Everest NF (nota fiscal) — fonte diferente de todas as outras views de CMV que usam BTG.",
         "Fornecedores e valores inconsistentes: ex. Everest mostra 'GREENJOY CENTRAL KITCHEN' (R$64k), BTG mostra 'GREENJOY FRANQUEADORA' (R$141k).",
         "Reescrever kpi_curva_abc_fornecedor usando BTG × de-para, igual a kpi_cmv_fornecedor_mensal."),

        (4, "ALTO",
         "Top Itens por Custo (/compras)",
         "kpi_cmv_top_itens usa nf_itens (Everest NF — nível de produto). BTG não tem granularidade de item.",
         "Dados de produto vêm do Everest (histórico parcial, sem data limite), enquanto o CMV total vem do BTG. Visões desconexas.",
         "Decidir: manter Top Itens como análise de produto (Everest, dados de composição) e deixar claro no dashboard que é uma fonte diferente. OU remover a seção."),

        (5, "ALTO",
         "CMV join inconsistente",
         "kpi_cmv_mensal e kpi_socios_painel fazem JOIN só em nome_pagador_recebedor. fn_projecao_cmv_periodo faz COALESCE(nome, descricao). 799 débitos sem nome (R$10.7M histórico) podem ser excluídos do CMV.",
         "CMV mensal pode estar subestimado. Valores da aba /semana (RPC) vs aba /compras (view) podem divergir.",
         "Padronizar todos os JOINs para COALESCE(nome_pagador_recebedor, descricao). Verificar quais dessas 799 transações são custo."),

        (6, "MÉDIO",
         "CMV 41.6% em abr/26",
         "Abril/2026: compras R$216,703 / fat R$520,442 = 41.6%. Inclui Embalagens (R$22,8k), Estoque Seco (R$21,3k) além de alimentos.",
         "Número acima do benchmark (meta 33%), mas parte do desvio é por categorias não-alimento.",
         "Após reclassificar Embalagens e Royalties, recalcular o CMV real de alimentos e definir nova meta."),

        (7, "MÉDIO",
         "Categoria 'bebidas' duplicada",
         "kpi_compras_mensal exibe 'Bebidas' e 'bebidas' como categorias separadas (case inconsistente no de-para).",
         "Split visual no gráfico, valor real de bebidas subestimado em cada linha.",
         "Normalizar categoria_2='Bebidas' (capitalize) em jafeb_despesas_mapping para todos os registros de bebidas."),

        (8, "BAIXO",
         "Faturamento bruto vs líquido",
         "Diferença entre faturamento bruto (vlr_total) e líquido (vlr_total+vlr_serv-vlr_desc_tot): abr/26 = R$21,294 (descontos iFood).",
         "Se algum card/relatório usar vlr_total puro, superestima faturamento.",
         "Confirmar que kpi_faturamento_diario (base de tudo) usa fórmula correta — CONFIRMADO OK."),

        (9, "BAIXO",
         "kpi_semana_vs_meta: projeção simples",
         "Projeção do mês = (realizado / dias corridos) × dias do mês. Não considera sazonalidade (pico no fim de semana).",
         "Projeção pode ser imprecisa em semanas atípicas.",
         "Aceitar limitação ou implementar projeção ponderada por dia da semana (melhoria futura)."),
    ]

    for row_i, (num, sev, kpi, prob, impacto, acao) in enumerate(problemas, 4):
        bg = VERMELHO if sev == "CRÍTICO" else AMARELO if sev == "ALTO" else CINZA
        cor_sev = VERMELHO_ESCURO if sev == "CRÍTICO" else AMARELO_ESCURO if sev == "ALTO" else PRETO
        cell(ws, row_i, 1, num, bold=True, align="center", bg=bg)
        cell(ws, row_i, 2, sev, bold=True, color=cor_sev, bg=bg, align="center")
        cell(ws, row_i, 3, kpi, bg=bg)
        cell(ws, row_i, 4, prob, bg=bg)
        cell(ws, row_i, 5, impacto, bg=bg)
        cell(ws, row_i, 6, acao, bg=bg)
        ws.row_dimensions[row_i].height = 52

    ws.freeze_panes = "A4"

    # ===========================================================
    # ABA 2: MAPEAMENTO DE KPIs POR TELA
    # ===========================================================
    ws2 = wb.create_sheet("2. Mapa de KPIs")
    titulo_aba(ws2, "Mapa de KPIs por Tela — Fonte e Consistência",
               "Verde = consistente com backbone BTG  |  Amarelo = atenção  |  Vermelho = inconsistência")

    h2 = ["Tela", "KPI / Seção", "View / RPC", "Fonte Faturamento", "Fonte CMV", "Período", "Status", "Nota"]
    w2 = [12, 25, 28, 22, 25, 14, 12, 40]
    for i, (h, w) in enumerate(zip(h2, w2), 1):
        hdr(ws2, 3, i, h, fg=BRANCO, bg=VERDE_ESCURO, sz=10)
        ws2.column_dimensions[get_column_letter(i)].width = w

    kpis = [
        # (tela, kpi, view, fonte_fat, fonte_cmv, periodo, status, nota)
        ("/sócios",   "Faturamento líquido, Pedidos, Ticket",  "kpi_socios_painel",     "ecletica_pagamentos (vlr_total+serv-desc)", "BTG × de-para (nome)", "Mês corrente", "OK",        "Fórmula correta. CMV inclui royalties e embalagens."),
        ("/sócios",   "Meta do mês, Projeção",                 "kpi_socios_painel",     "ecletica_pagamentos",                       "—",                    "Mês corrente", "OK",        "Projeção simples (sem sazonalidade)."),
        ("/sócios",   "CMV%",                                  "kpi_socios_painel",     "ecletica_pagamentos",                       "BTG × de-para (nome)", "Mês corrente", "ATENÇÃO",   "Inclui CAYENA TECNOLOGIA e royalties. Ver problema #1 e #2."),
        ("/sócios",   "Prime Cost%",                           "kpi_socios_painel",     "ecletica_pagamentos",                       "BTG × de-para (nome)", "Mês corrente", "ATENÇÃO",   "Labor = pagamentos diretos × 1.75 (estimativa CLT). CMV com mesmos problemas."),
        ("/sócios",   "Tendência 24 meses",                    "kpi_historico_24m",     "resumo_mensal_historico + ecletica",        "—",                    "24 meses",     "OK",        "Meses passados = tabela histórica; recentes = live."),
        ("/sócios",   "Canal de vendas 6 meses",               "kpi_canal_evolucao_6m", "ecletica_pagamentos",                       "—",                    "6 meses",      "OK",        "Sem problemas identificados."),

        ("/semana",   "Meta mensal, Projeção, Falta",          "kpi_semana_vs_meta",    "kpi_faturamento_diario",                    "—",                    "Mês corrente", "OK",        ""),
        ("/semana",   "Realizado semana, Meta semana",         "kpi_semana_vs_meta",    "kpi_faturamento_diario",                    "—",                    "Semana atual", "OK",        "Meta semana = meta mensal / 31 × 7 (não pondera dias)"),
        ("/semana",   "HERO: Limite de compras",               "fn_projecao_cmv_periodo","ecletica_pagamentos",                      "BTG × de-para (COALESCE)", "Semana",   "ATENÇÃO",   "RPC usa COALESCE(nome,descricao); views usam só nome. Valores podem divergir ligeiramente."),
        ("/semana",   "Faturamento diário (tabela)",           "kpi_faturamento_diario","ecletica_pagamentos",                       "—",                    "Semana atual", "OK",        ""),

        ("/compras",  "Planejamento CMV — Fat. período",       "fn_projecao_cmv_periodo","ecletica_pagamentos",                      "BTG × de-para (COALESCE)", "Paramétrico","ATENÇÃO",  "RPC usa COALESCE; view kpi_cmv_mensal usa apenas nome. Podem divergir."),
        ("/compras",  "Planejamento CMV — Budget 29%",         "fn_projecao_cmv_periodo","ecletica_pagamentos",                      "BTG × de-para (COALESCE)", "Paramétrico","ATENÇÃO",  "Budget inclui royalties/embalagens no CMV realizado."),
        ("/compras",  "Maiores gastos — por categoria",        "fn_cmv_por_categoria",  "—",                                         "BTG × de-para (COALESCE)", "Paramétrico","OK",       "Usa categoria_2. 'Bebidas'/'bebidas' duplicado."),
        ("/compras",  "Maiores gastos — por fornecedor",       "fn_cmv_por_fornecedor", "—",                                         "BTG × de-para (COALESCE)", "Paramétrico","OK",       "CAYENA TECNOLOGIA aparece como fornecedor de custo."),
        ("/compras",  "CMV% mensal — card + gráfico + tabela","kpi_cmv_mensal",         "ecletica_pagamentos",                       "BTG × de-para (nome)",  "6 meses",    "ATENÇÃO",   "JOIN só em nome, sem COALESCE descricao. Pode subestimar CMV."),
        ("/compras",  "CMV% semanal",                          "kpi_cmv_semanal",        "ecletica_pagamentos",                       "BTG × de-para (nome)",  "8 semanas",   "ATENÇÃO",   "Mesmo problema de JOIN que kpi_cmv_mensal."),
        ("/compras",  "Curva ABC — por categoria",             "kpi_curva_abc_cmv",      "—",                                         "BTG × de-para",         "All-time",    "OK",        "All-time sem filtro de período — pode ser confuso."),
        ("/compras",  "Curva ABC — por fornecedor",            "kpi_curva_abc_fornecedor","—",                                        "NF Everest (nf_recebimento)","All-time","CRÍTICO",  "FONTE DIFERENTE: Everest NF, não BTG. Valores e fornecedores divergem do resto do dashboard."),
        ("/compras",  "Top Itens por Custo",                   "kpi_cmv_top_itens",      "—",                                         "NF Everest (nf_itens)", "All-time",    "CRÍTICO",   "FONTE DIFERENTE: nível de produto via NF Everest, não BTG. Sem filtro de período."),
        ("/compras",  "Composição custo por categoria 6m",     "kpi_compras_mensal",     "—",                                         "BTG × de-para (nome)",  "6 meses",     "ATENÇÃO",   "'Bebidas' e 'bebidas' aparecem separadas (case inconsistente)."),
    ]

    for row_i, (tela, kpi, view, ffat, fcmv, per, status, nota) in enumerate(kpis, 4):
        bg = VERMELHO if status == "CRÍTICO" else AMARELO if status == "ATENÇÃO" else VERDE_CLARO
        cor = VERMELHO_ESCURO if status == "CRÍTICO" else AMARELO_ESCURO if status == "ATENÇÃO" else VERDE_ESCURO
        cell(ws2, row_i, 1, tela,   bold=True, bg=bg)
        cell(ws2, row_i, 2, kpi,    bg=bg)
        cell(ws2, row_i, 3, view,   bg=bg)
        cell(ws2, row_i, 4, ffat,   bg=bg)
        cell(ws2, row_i, 5, fcmv,   bg=bg)
        cell(ws2, row_i, 6, per,    bg=bg, align="center")
        cell(ws2, row_i, 7, status, bold=True, color=cor, bg=bg, align="center")
        cell(ws2, row_i, 8, nota,   bg=bg)
        ws2.row_dimensions[row_i].height = 42
    ws2.freeze_panes = "A4"

    # ===========================================================
    # ABA 3: CMV MENSAL — valores reais 6 meses
    # ===========================================================
    ws3 = wb.create_sheet("3. CMV Mensal")
    titulo_aba(ws3, "CMV Mensal — Valores Reais (últimos 6 meses)",
               "Fonte: kpi_cmv_mensal (BTG × de-para). CMV inclui royalties, embalagens e PDV (ver Aba 1)")

    dados_cmv = sb.table("kpi_cmv_mensal").select("mes,total_compras,faturamento_mes,cmv_pct") \
        .order("mes", desc=True).limit(6).execute().data

    h3 = ["Mês", "Faturamento Líquido", "Compras (CMV)", "CMV%", "Meta CMV", "Desvio vs Meta", "Status"]
    w3 = [12, 20, 20, 10, 12, 18, 12]
    for i, (h, w) in enumerate(zip(h3, w3), 1):
        hdr(ws3, 3, i, h, fg=BRANCO, bg=VERDE_ESCURO)
        ws3.column_dimensions[get_column_letter(i)].width = w

    for row_i, r in enumerate(dados_cmv, 4):
        fat  = fmt_brl(r["faturamento_mes"])
        comp = fmt_brl(r["total_compras"])
        pct_v = fmt_brl(r["cmv_pct"])
        meta_cmv = 33.0
        desvio = pct_v - meta_cmv
        status = "Saudável" if pct_v <= 33 else "Atenção" if pct_v <= 37 else "Crítico"
        bg = VERDE_CLARO if pct_v <= 33 else AMARELO if pct_v <= 37 else VERMELHO
        cor = VERDE_ESCURO if pct_v <= 33 else AMARELO_ESCURO if pct_v <= 37 else VERMELHO_ESCURO

        cell(ws3, row_i, 1, r["mes"],     bold=True, align="center")
        cell(ws3, row_i, 2, fat,          align="right", fmt=BRL)
        cell(ws3, row_i, 3, comp,         align="right", fmt=BRL)
        cell(ws3, row_i, 4, pct_v/100,   align="right", fmt=PCT, bg=bg, bold=True, color=cor)
        cell(ws3, row_i, 5, meta_cmv/100, align="right", fmt=PCT)
        cell(ws3, row_i, 6, desvio/100,   align="right", fmt=PCT,
             color=VERMELHO_ESCURO if desvio > 0 else VERDE_ESCURO)
        cell(ws3, row_i, 7, status,       align="center", bold=True, bg=bg, color=cor)
        ws3.row_dimensions[row_i].height = 18

    # linha de aviso
    r_aviso = len(dados_cmv) + 5
    ws3.merge_cells(f"A{r_aviso}:G{r_aviso}")
    c = ws3.cell(row=r_aviso, column=1,
                 value="⚠ ATENÇÃO: CMV% inclui Embalagens (~10.5%), royalties GREENJOY FRANQUEADORA e CAYENA TECNOLOGIA (sistema PDV). CMV real de alimentos é menor.")
    c.font = Font(name="Calibri", bold=True, size=10, color=VERMELHO_ESCURO)
    c.fill = PatternFill("solid", fgColor=VERMELHO)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws3.row_dimensions[r_aviso].height = 22
    ws3.freeze_panes = "A4"

    # ===========================================================
    # ABA 4: BREAKDOWN CMV ABR/2026
    # ===========================================================
    ws4 = wb.create_sheet("4. CMV por Categoria (Abr26)")
    titulo_aba(ws4, "Breakdown CMV por Categoria — Abril/2026",
               "Fonte: kpi_compras_mensal (BTG). Identifica o que compõe o CMV de 41.6% do mês anterior.")

    dados_cat = sb.table("kpi_compras_mensal").select("mes,categoria,total_compras") \
        .eq("mes", "2026-04").order("total_compras", desc=True).execute().data

    h4 = ["Categoria", "Compras (R$)", "% do total", "É alimento?", "Validar com Rafael"]
    w4 = [30, 18, 12, 14, 40]
    for i, (h, w) in enumerate(zip(h4, w4), 1):
        hdr(ws4, 3, i, h, fg=BRANCO, bg=VERDE_ESCURO)
        ws4.column_dimensions[get_column_letter(i)].width = w

    total_cat = sum(fmt_brl(r["total_compras"]) for r in dados_cat)

    # Classificação manual de alimento
    eh_alimento = {
        "Hortaliças": "Sim",
        "Queijos": "Sim",
        "Proteínas": "Sim",
        "Sobremesas e Smoothies": "Sim",
        "Tortas": "Sim",
        "Bebidas": "Sim",
        "bebidas": "Sim",
        "Molhos Cozinha Central": "Verificar — compra da cozinha central JAFEB?",
        "Embalagens": "NÃO — custo operacional",
        "Estoque Seco": "Verificar — pode incluir utensílios",
    }

    for row_i, r in enumerate(dados_cat, 4):
        cat  = r["categoria"]
        val  = fmt_brl(r["total_compras"])
        pct_v = val / total_cat if total_cat else 0
        alim = eh_alimento.get(cat, "Verificar")
        bg = VERDE_CLARO if alim == "Sim" else VERMELHO if alim.startswith("NÃO") else AMARELO

        cell(ws4, row_i, 1, cat,   bold=True, bg=bg)
        cell(ws4, row_i, 2, val,   align="right", fmt=BRL, bg=bg)
        cell(ws4, row_i, 3, pct_v, align="right", fmt=PCT, bg=bg)
        cell(ws4, row_i, 4, alim,  align="center", bg=bg,
             bold=alim.startswith("NÃO") or alim.startswith("Verificar"))
        cell(ws4, row_i, 5, "",    bg=CINZA)  # coluna de validação do Rafael
        ws4.row_dimensions[row_i].height = 18

    # total
    r_tot = len(dados_cat) + 4
    cell(ws4, r_tot, 1, "TOTAL", bold=True, bg=CINZA)
    cell(ws4, r_tot, 2, total_cat, bold=True, align="right", fmt=BRL, bg=CINZA)
    cell(ws4, r_tot, 3, 1.0, bold=True, align="right", fmt=PCT, bg=CINZA)

    # faturamento e CMV%
    fat_abr = 520442.08
    r_cmv = r_tot + 1
    cell(ws4, r_cmv, 1, f"Faturamento abr/26 = R$ {fat_abr:,.2f}".replace(",","X").replace(".",",").replace("X","."), bold=True)
    cell(ws4, r_cmv, 2, total_cat / fat_abr, bold=True, align="right", fmt=PCT,
         bg=VERMELHO, color=VERMELHO_ESCURO)
    cell(ws4, r_cmv, 3, "= CMV% 41.6%", bold=True, color=VERMELHO_ESCURO)
    ws4.freeze_panes = "A4"

    # ===========================================================
    # ABA 5: FORNECEDORES — BTG vs Everest NF
    # ===========================================================
    ws5 = wb.create_sheet("5. Fornecedores BTG vs NF")
    titulo_aba(ws5, "Comparação: Fornecedores BTG vs Nota Fiscal Everest",
               "BTG = últimos 6 meses (kpi_cmv_fornecedor_mensal)  |  Everest NF = all-time (kpi_curva_abc_fornecedor) — FONTES DIFERENTES no dashboard!")

    # BTG top 10 (últimos 6 meses)
    dados_btg_forn = sb.rpc("fn_cmv_por_fornecedor", {
        "p_inicio": "2025-12-01",
        "p_fim": "2026-05-18"
    }).execute().data or []

    # Everest NF top 10
    dados_nf_forn = sb.table("kpi_curva_abc_fornecedor").select(
        "posicao,fornecedor,custo_total,pct_custo,curva"
    ).order("posicao").limit(10).execute().data or []

    ws5.cell(row=3, column=1, value="FONTE BTG (últimos 6 meses — método ativo)").font = Font(bold=True, size=11, color=VERDE_ESCURO)
    ws5.cell(row=3, column=6, value="FONTE EVEREST NF (all-time — usado em Curva ABC Fornecedor)").font = Font(bold=True, size=11, color=VERMELHO_ESCURO)

    btg_hdrs = ["#", "Fornecedor (BTG)", "Compras R$", "% Total"]
    nf_hdrs  = ["#", "Fornecedor (NF Everest)", "Custo R$", "% Total", "Curva"]
    btg_w = [5, 40, 18, 10]
    nf_w  = [5, 40, 18, 10, 8]

    for i, (h, w) in enumerate(zip(btg_hdrs, btg_w), 1):
        hdr(ws5, 4, i, h, fg=BRANCO, bg=VERDE_ESCURO)
        ws5.column_dimensions[get_column_letter(i)].width = w
    for i, (h, w) in enumerate(zip(nf_hdrs, nf_w), 6):
        hdr(ws5, 4, i, h, fg=BRANCO, bg=VERMELHO_ESCURO)
        ws5.column_dimensions[get_column_letter(i)].width = w

    for row_i, r in enumerate(dados_btg_forn[:10], 5):
        bg = AMARELO if "FRANQUEADORA" in str(r.get("fornecedor","")).upper() or \
             "CAYENA" in str(r.get("fornecedor","")).upper() else BRANCO
        cell(ws5, row_i, 1, row_i - 4, align="center", bg=bg)
        cell(ws5, row_i, 2, r.get("fornecedor",""), bg=bg)
        cell(ws5, row_i, 3, fmt_brl(r.get("total_compras",0)), align="right", fmt=BRL, bg=bg)
        cell(ws5, row_i, 4, fmt_pct(r.get("pct_cmv",0)), align="right", fmt=PCT, bg=bg)

    for row_i, r in enumerate(dados_nf_forn, 5):
        cell(ws5, row_i, 6, r.get("posicao",""), align="center")
        cell(ws5, row_i, 7, r.get("fornecedor",""))
        cell(ws5, row_i, 8, fmt_brl(r.get("custo_total",0)), align="right", fmt=BRL)
        cell(ws5, row_i, 9, fmt_pct(r.get("pct_custo",0)), align="right", fmt=PCT)
        cell(ws5, row_i, 10, r.get("curva",""), align="center")

    aviso_row = 16
    ws5.merge_cells(f"A{aviso_row}:J{aviso_row}")
    c = ws5.cell(row=aviso_row, column=1,
                 value="⚠ CAYENA TECNOLOGIA (sistema Eclética/PDV, ~R$122k/6m) e GREENJOY FRANQUEADORA (royalties, ~R$141k/6m) aparecem como 'Custo' no BTG. Reclassificar no de-para.")
    c.font = Font(bold=True, size=10, color=VERMELHO_ESCURO)
    c.fill = PatternFill("solid", fgColor=VERMELHO)
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws5.row_dimensions[aviso_row].height = 22

    # ===========================================================
    # ABA 6: FATURAMENTO — fórmulas e divergências
    # ===========================================================
    ws6 = wb.create_sheet("6. Faturamento — Validação")
    titulo_aba(ws6, "Validação do Faturamento — Bruto vs Líquido",
               "Fórmula correta: vlr_total + vlr_serv - vlr_desc_tot  |  Confirmado em todas as views principais")

    # Dados da query de faturamento (executada via Supabase MCP)
    fat_rows = [
        ("2026-05", 328331.26, 320719.75, -7611.51),
        ("2026-04", 541736.47, 520442.08, -21294.39),
        ("2026-03", 570847.30, 549954.68, -20892.62),
        ("2026-02", 532069.51, 517431.29, -14638.22),
        ("2026-01", 547331.38, 532291.23, -15040.15),
    ]

    h6 = ["Mês", "Fat. Bruto (vlr_total)", "Fat. Líquido (fórmula correta)", "Diferença (descontos iFood)", "% Desconto/Bruto", "Status views"]
    w6 = [12, 24, 28, 28, 18, 20]
    for i, (h, w) in enumerate(zip(h6, w6), 1):
        hdr(ws6, 3, i, h, fg=BRANCO, bg=VERDE_ESCURO)
        ws6.column_dimensions[get_column_letter(i)].width = w

    for row_i, (mes, bruto, liq, dif) in enumerate(fat_rows, 4):
        pct_desc = abs(dif) / bruto if bruto else 0
        cell(ws6, row_i, 1, mes,      bold=True, align="center")
        cell(ws6, row_i, 2, bruto,    align="right", fmt=BRL)
        cell(ws6, row_i, 3, liq,      align="right", fmt=BRL, bg=VERDE_CLARO, bold=True)
        cell(ws6, row_i, 4, dif,      align="right", fmt=BRL, color=VERMELHO_ESCURO)
        cell(ws6, row_i, 5, pct_desc, align="right", fmt=PCT)
        cell(ws6, row_i, 6, "OK — usa fórmula correta", align="center", color=VERDE_ESCURO, bold=True)
        ws6.row_dimensions[row_i].height = 18

    # nota final
    r_nota = len(fat_rows) + 5
    ws6.merge_cells(f"A{r_nota}:F{r_nota}")
    cn = ws6.cell(row=r_nota, column=1,
                  value="✓ kpi_faturamento_diario, kpi_socios_painel, kpi_semana_vs_meta, kpi_cmv_mensal, kpi_canal_evolucao_6m — todos usam vlr_total+vlr_serv-vlr_desc_tot. Fórmula consistente.")
    cn.font = Font(bold=True, size=10, color=VERDE_ESCURO)
    cn.fill = PatternFill("solid", fgColor=VERDE_CLARO)
    cn.alignment = Alignment(horizontal="left", vertical="center")
    ws6.row_dimensions[r_nota].height = 22
    ws6.freeze_panes = "A4"

    # ===========================================================
    # SALVAR
    # ===========================================================
    out = r"C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\Auditoria_KPIs_Dashboard.xlsx"
    wb.save(out)
    print(f"Excel salvo em: {out}")
    return out


if __name__ == "__main__":
    main()
