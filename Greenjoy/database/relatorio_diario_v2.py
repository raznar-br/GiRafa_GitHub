import os, sys, smtplib, logging
from datetime import date, timedelta
from email.mime.text import MIMEText
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

from sql import run
import mysql.connector

GMAIL_USER     = os.environ["GMAIL_USER"]
GMAIL_PASSWORD = os.environ["GMAIL_APP_PASSWORD"]

DESTINATARIOS = [
    "rafa.dallana@gmail.com",
    "brunobjusto@gmail.com",
    "felipemitunari@gmail.com",
    "greenjoyaf@gmail.com",
]

LIQ = "vlr_total + COALESCE(vlr_serv,0) - COALESCE(vlr_desc_tot,0)"
DIA = "(data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::date"
CANAL = """CASE
  WHEN origem_venda ILIKE '%IFOOD%'                      THEN 'iFood'
  WHEN origem_venda = 'DELIVERY WEB OLGA TECH'           THEN 'Woovi · Entrega'
  WHEN origem_venda = 'ENCOMENDA RETIRADA WEB OLGA TECH' THEN 'Woovi · Retirada'
  ELSE 'Salão' END"""
CANAL_MYSQL = CANAL.replace("ILIKE", "LIKE")
ORDEM_CANAIS = ["iFood", "Woovi · Entrega", "Woovi · Retirada", "Salão"]
CORTE_DIA_FRACO = 50


# ── Dados ─────────────────────────────────────────────────────────────────────

def fat_periodo(ini: date, fim: date) -> tuple[float, int]:
    r = run(f"""SELECT COALESCE(SUM({LIQ}),0) fat, COUNT(*) ped FROM ecletica_pagamentos
                WHERE flag_canc <> 'C' AND {DIA} BETWEEN '{ini}' AND '{fim}'""", silencioso=True)[0]
    return float(r["fat"]), int(r["ped"])


def buscar_dados(dia: date) -> dict:
    canais = {c: {"fat": 0.0, "ped": 0} for c in ORDEM_CANAIS}
    for r in run(f"""SELECT {CANAL} canal, SUM({LIQ}) fat, COUNT(*) ped FROM ecletica_pagamentos
                     WHERE flag_canc <> 'C' AND {DIA} = '{dia}' GROUP BY 1""", silencioso=True):
        canais[r["canal"]] = {"fat": float(r["fat"]), "ped": int(r["ped"])}

    fat_dia, ped_dia = fat_periodo(dia, dia)
    fat_sem_passada, ped_sem_passada = fat_periodo(dia - timedelta(7), dia - timedelta(7))

    medianas = {int(r["dow"]): float(r["mediana"]) for r in run(f"""
        WITH d AS (SELECT {DIA} dia, SUM({LIQ}) fat FROM ecletica_pagamentos
                   WHERE flag_canc <> 'C' AND {DIA} BETWEEN '{dia - timedelta(112)}' AND '{dia - timedelta(1)}'
                   GROUP BY 1)
        SELECT EXTRACT(isodow FROM dia) - 1 dow, percentile_cont(0.5) WITHIN GROUP (ORDER BY fat) mediana
        FROM d GROUP BY 1""", silencioso=True)}
    esperado = medianas.get(dia.weekday(), 0.0)
    esperado_canal = {r["canal"]: float(r["mediana"]) for r in run(f"""
        WITH d AS (SELECT {DIA} dia, {CANAL} canal, SUM({LIQ}) fat FROM ecletica_pagamentos
                   WHERE flag_canc <> 'C' AND {DIA} BETWEEN '{dia - timedelta(112)}' AND '{dia - timedelta(1)}'
                     AND EXTRACT(isodow FROM {DIA}) = {dia.isoweekday()}
                   GROUP BY 1, 2)
        SELECT canal, percentile_cont(0.5) WITHIN GROUP (ORDER BY fat) mediana FROM d GROUP BY 1""", silencioso=True)}

    seg = dia - timedelta(dia.weekday())
    fat_sem, _ = fat_periodo(seg, dia)
    restantes = [dia + timedelta(i) for i in range(1, 7 - dia.weekday())]
    fat_sem_ant, _ = fat_periodo(seg - timedelta(7), dia - timedelta(7))

    compras_sem = float(run(f"""SELECT COALESCE(SUM(valor),0) v FROM btg_classificado
                                WHERE tipo ILIKE 'D%' AND natureza = 'Custo'
                                AND data_movimentacao BETWEEN '{seg}' AND '{dia}'""", silencioso=True)[0]["v"])
    rolling = run(f"SELECT cmv_30d_pct, semaforo_cmv FROM kpi_cmv_rolling WHERE dia = '{dia}'", silencioso=True)

    return {
        "dia": dia, "fat_dia": fat_dia, "ped_dia": ped_dia,
        "ticket": fat_dia / ped_dia if ped_dia else 0,
        "ticket_sem_passada": fat_sem_passada / ped_sem_passada if ped_sem_passada else 0,
        "fat_sem_passada": fat_sem_passada, "ped_sem_passada": ped_sem_passada,
        "pct_esperado": 100 * fat_dia / esperado if esperado else None,
        "canais": canais, "esperado_canal": esperado_canal,
        "seg": seg, "fat_sem": fat_sem, "semana_fechada": not restantes,
        "projecao_sem": fat_sem + sum(medianas.get(d.weekday(), 0.0) for d in restantes),
        "fat_sem_ant": fat_sem_ant, "compras_sem": compras_sem,
        "cmv_sem": 100 * compras_sem / fat_sem if fat_sem else None,
        "cmv_30d": float(rolling[0]["cmv_30d_pct"]) if rolling else None,
        "semaforo_30d": rolling[0]["semaforo_cmv"] if rolling else "",
        **buscar_fechamento(dia, seg),
    }


def buscar_fechamento(dia: date, seg: date) -> dict:
    conn = mysql.connector.connect(
        host=os.environ["ECLETICA_HOST"], port=int(os.environ.get("ECLETICA_PORT", 3306)),
        user=os.environ["ECLETICA_USER"], password=os.environ["ECLETICA_PASSWORD"],
        database=os.environ["ECLETICA_DB"], connection_timeout=10,
    )
    cur = conn.cursor()
    cur.execute(f"""
        SELECT DATE(data_hora_abre), DATE(data_hora_fecha), {CANAL_MYSQL}, COUNT(*), SUM({LIQ})
        FROM pagamentos
        WHERE flag_canc <> 'C' AND DATE(data_hora_fecha) BETWEEN %s AND %s
          AND DATE(data_hora_abre) <> DATE(data_hora_fecha)
        GROUP BY 1, 2, 3 ORDER BY 1, 5 DESC""", (seg, dia))
    fora_do_dia = [{"venda": r[0], "fechou": r[1], "canal": r[2], "ped": int(r[3]), "valor": float(r[4])}
                   for r in cur.fetchall()]
    cur.execute("SELECT COUNT(*) FROM rejeicoes_pedidos_web WHERE DATE(data_hora) = %s", (dia,))
    rejeitados = cur.fetchone()[0]
    conn.close()
    return {"fora_do_dia": fora_do_dia, "rejeitados": rejeitados}


# ── HTML ──────────────────────────────────────────────────────────────────────

DIAS = ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo"]
MESES = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]

VERDE, AMARELO, VERMELHO, CINZA = "#15803d", "#b45309", "#b91c1c", "#6b7280"
TINTA, SUAVE, LINHA, FUNDO = "#111827", "#6b7280", "#e5e7eb", "#f3f4f1"
MARCA = "#1f3d2b"
FONTE = "-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif"
TABELA = 'role="presentation" width="100%" cellpadding="0" cellspacing="0"'


def brl(v: float, centavos=False) -> str:
    s = f"{v:,.2f}" if centavos else f"{v:,.0f}"
    return "R$ " + s.replace(",", "X").replace(".", ",").replace("X", ".")


def ddmm(d: date) -> str:
    return f"{d.day:02d}/{d.month:02d}"


def delta(atual: float, base: float) -> str:
    if not base:
        return ""
    p = 100 * (atual - base) / base
    cor = VERDE if p >= 0 else VERMELHO
    return f'<span style="color:{cor};font-weight:600">{"▲" if p >= 0 else "▼"} {abs(p):.0f}%</span>'


def pill(texto: str, cor: str) -> str:
    return (f'<span style="display:inline-block;padding:4px 12px;border-radius:999px;'
            f'background:{cor};color:#fff;font-size:13px;font-weight:600">{texto}</span>')


def titulo(texto: str) -> str:
    return (f'<tr><td style="padding:28px 20px 10px;font-size:12px;font-weight:700;letter-spacing:.08em;'
            f'text-transform:uppercase;color:{SUAVE}">{texto}</td></tr>')


def cartao(conteudo: str) -> str:
    return (f'<tr><td style="padding:0 12px"><table {TABELA} style="background:#fff;border-radius:14px;'
            f'border:1px solid {LINHA}"><tr><td style="padding:18px 16px">{conteudo}</td></tr></table></td></tr>')


def dois_numeros(esq: tuple, dir: tuple) -> str:
    def celula(rotulo, valor, rodape, cor=TINTA):
        return (f'<td width="50%" style="padding-top:14px;vertical-align:top">'
                f'<div style="font-size:13px;color:{SUAVE}">{rotulo}</div>'
                f'<div style="font-size:24px;font-weight:700;color:{cor}">{valor}</div>'
                f'<div style="font-size:13px;color:{SUAVE};margin-top:2px">{rodape}</div></td>')
    return (f'<table {TABELA} style="margin-top:16px;border-top:1px solid {LINHA}"><tr>'
            f'{celula(*esq)}{celula(*dir)}</tr></table>')


def bloco_dia(d: dict) -> str:
    nome_dia = DIAS[d["dia"].weekday()]
    alerta = ""
    if d["pct_esperado"] is not None and d["pct_esperado"] < CORTE_DIA_FRACO:
        alerta = (f'<div style="margin-top:14px;padding:10px 12px;border-radius:10px;background:#fef2f2;'
                  f'color:{VERMELHO};font-size:14px;line-height:1.4"><b>{d["pct_esperado"]:.0f}% do normal '
                  f'para {nome_dia}.</b> Provável pedido sem fechar — ver bloco 4.</div>')
    return cartao(f"""
      <div style="font-size:13px;color:{SUAVE}">Faturamento líquido</div>
      <div style="font-size:38px;line-height:1.1;font-weight:700;color:{TINTA};letter-spacing:-.02em;margin-top:2px">{brl(d['fat_dia'])}</div>
      <div style="font-size:14px;color:{SUAVE};margin-top:6px">{delta(d['fat_dia'], d['fat_sem_passada'])} vs {nome_dia} anterior ({brl(d['fat_sem_passada'])})</div>
      {dois_numeros(("Ticket médio", brl(d['ticket'], True), delta(d['ticket'], d['ticket_sem_passada'])),
                    ("Pedidos", d['ped_dia'], delta(d['ped_dia'], d['ped_sem_passada'])))}
      {alerta}""")


def bloco_canais(d: dict) -> str:
    linhas = ""
    for i, nome in enumerate(ORDEM_CANAIS):
        c = d["canais"][nome]
        share = 100 * c["fat"] / d["fat_dia"] if d["fat_dia"] else 0
        ticket = c["fat"] / c["ped"] if c["ped"] else 0
        borda = f"border-top:1px solid {LINHA};" if i else ""
        linhas += f"""
        <tr><td style="{borda}padding:12px 0">
          <table {TABELA}>
            <tr>
              <td style="font-size:16px;font-weight:600;color:{TINTA}">{nome}</td>
              <td align="right" style="font-size:16px;font-weight:700;color:{TINTA};white-space:nowrap">{brl(c['fat'])}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:{SUAVE};padding-top:2px">{c['ped']} pedidos · ticket {brl(ticket, True)}</td>
              <td align="right" style="font-size:13px;color:{SUAVE};padding-top:2px">{share:.0f}%</td>
            </tr>
            <tr><td colspan="2" style="padding-top:8px">
              <table {TABELA} style="background:{FUNDO};border-radius:4px"><tr>
                <td width="{max(share, 1):.0f}%" style="background:{MARCA};height:6px;border-radius:4px;font-size:0;line-height:0">&nbsp;</td>
                <td style="font-size:0;line-height:0">&nbsp;</td>
              </tr></table>
            </td></tr>
          </table>
        </td></tr>"""
    return cartao(f"<table {TABELA}>{linhas}</table>")


def bloco_semana(d: dict) -> str:
    cmv = d["cmv_sem"]
    cor_30d = {"otimo": VERDE, "bom": AMARELO, "critico": VERMELHO}.get(d["semaforo_30d"], CINZA)
    rotulo = "semana fechada" if d["semana_fechada"] else "projeção da semana"
    realizado = ("" if d["semana_fechada"] else
                 f'<div style="font-size:14px;color:{SUAVE};margin-top:2px">Realizado até {ddmm(d["dia"])}: {brl(d["fat_sem"])}</div>')
    return cartao(f"""
      <div style="font-size:13px;color:{SUAVE}">{ddmm(d['seg'])} a {ddmm(d['seg'] + timedelta(6))} · {rotulo}</div>
      <div style="font-size:30px;line-height:1.15;font-weight:700;color:{TINTA};margin-top:2px">{brl(d['projecao_sem'])}</div>
      <div style="font-size:14px;color:{SUAVE};margin-top:6px">{delta(d['fat_sem'], d['fat_sem_ant'])} vs mesmos dias da semana anterior</div>
      {realizado}
      {dois_numeros(("CMV da semana", '—' if cmv is None else f'{cmv:.1f}%', f"compras {brl(d['compras_sem'])}"),
                    ("CMV 30 dias", '—' if d['cmv_30d'] is None else f"{d['cmv_30d']:.1f}%", "oficial · meta ≤ 33%", cor_30d))}
      <div style="font-size:12px;color:{SUAVE};margin-top:12px;line-height:1.4">O CMV da semana oscila com o dia em que o fornecedor é pago. Para decidir, vale o de 30 dias.</div>""")


def bloco_fechamento(d: dict) -> str:
    dia = d["dia"]
    atrasados = [x for x in d["fora_do_dia"] if x["fechou"] == dia]

    if d["pct_esperado"] is not None and d["pct_esperado"] < CORTE_DIA_FRACO:
        status = pill("Atenção", VERMELHO)
        abaixo = sorted(((nome, d["canais"][nome]["fat"] - esp) for nome, esp in d["esperado_canal"].items()),
                        key=lambda x: x[1])
        onde = ", ".join(f"<b>{nome}</b> ({brl(-gap)} abaixo)" for nome, gap in abaixo if gap < -300) or "todos os canais"
        frase = (f"{ddmm(dia)} fechou com {d['pct_esperado']:.0f}% do movimento normal. Onde falta: {onde}. "
                 f"A Eclética só registra o pedido quando ele é fechado — confirmar no PDV se há pedidos em aberto.")
    elif atrasados:
        status = pill("Fechou atrasado", AMARELO)
        por_canal = {}
        for x in atrasados:
            por_canal[x["canal"]] = por_canal.get(x["canal"], 0) + x["ped"]
        origem = ", ".join(f"<b>{c}</b> {n}" for c, n in sorted(por_canal.items(), key=lambda i: -i[1]))
        frase = (f"{sum(por_canal.values())} pedidos de dias anteriores só fecharam em {ddmm(dia)} "
                 f"({brl(sum(x['valor'] for x in atrasados))}) e inflam o faturamento do dia. Origem: {origem}.")
    else:
        status = pill("Tudo fechou no dia", VERDE)
        frase = f"Nenhum pedido de dias anteriores fechou em {ddmm(dia)} e o movimento está dentro do normal."

    linhas = "".join(f"""
        <tr>
          <td style="padding:10px 0;border-top:1px solid {LINHA};font-size:14px;color:{TINTA}">
            <b>{x['canal']}</b> · {x['ped']} pedido{'s' if x['ped'] > 1 else ''}<br>
            <span style="font-size:13px;color:{SUAVE}">vendido {ddmm(x['venda'])} → fechou {ddmm(x['fechou'])}</span>
          </td>
          <td align="right" style="padding:10px 0;border-top:1px solid {LINHA};font-size:15px;font-weight:700;color:{AMARELO};white-space:nowrap">{brl(x['valor'])}</td>
        </tr>""" for x in d["fora_do_dia"])
    semana = (f'<div style="font-size:13px;color:{SUAVE};margin-top:18px">Fechados fora do dia nesta semana</div>'
              f'<table {TABELA} style="margin-top:4px">{linhas}</table>'
              if linhas else
              f'<div style="font-size:13px;color:{SUAVE};margin-top:14px">Nenhum pedido fechado fora do dia nesta semana.</div>')
    rejeitados = (f'<div style="font-size:14px;color:{VERMELHO};margin-top:12px"><b>{d["rejeitados"]}</b> pedido(s) '
                  f'rejeitado(s) pela integração iFood/Olga em {ddmm(dia)}.</div>' if d["rejeitados"] else "")
    return cartao(f"""
      {status}
      <div style="font-size:15px;color:{TINTA};margin-top:10px;line-height:1.45">{frase}</div>
      {rejeitados}{semana}""")


def build_html(d: dict) -> str:
    dia = d["dia"]
    return f"""<!DOCTYPE html>
<html lang="pt-BR"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><meta name="supported-color-schemes" content="light">
<title>Greenjoy · Fechamento {ddmm(dia)}</title>
</head>
<body style="margin:0;padding:0;background:{FUNDO};-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden">{brl(d['fat_dia'])} · {d['ped_dia']} pedidos · ticket {brl(d['ticket'], True)}</div>
<table {TABELA} style="background:{FUNDO}">
<tr><td align="center">
<table {TABELA} style="max-width:480px;font-family:{FONTE}">
  <tr><td style="background:{MARCA};padding:22px 20px 20px">
    <div style="font-size:12px;letter-spacing:.1em;text-transform:uppercase;color:#a7c4b0;font-weight:700">Greenjoy Anália Franco</div>
    <div style="font-size:24px;font-weight:700;color:#fff;margin-top:4px">Fechamento de {DIAS[dia.weekday()]}</div>
    <div style="font-size:15px;color:#d1e2d6;margin-top:2px">{dia.day} de {MESES[dia.month-1]} de {dia.year}</div>
  </td></tr>
  {titulo('1 · Fechamento do dia')}
  {bloco_dia(d)}
  {titulo('2 · Faturamento por canal')}
  {bloco_canais(d)}
  {titulo('3 · Semana')}
  {bloco_semana(d)}
  {titulo('4 · O que não fechou na Eclética')}
  {bloco_fechamento(d)}
  <tr><td style="padding:24px 20px 32px;font-size:12px;color:{SUAVE};line-height:1.5;text-align:center">
    Faturamento líquido = total + serviço − descontos, sem cancelados, pela data de fechamento.<br>
    Fontes: Eclética PDV · BTG · Supabase
  </td></tr>
</table>
</td></tr></table>
</body></html>"""


# ── Envio ─────────────────────────────────────────────────────────────────────

def enviar(html: str, dia: date, destinatarios: list[str], prefixo: str = ""):
    msg = MIMEText(html, "html", "utf-8")
    msg["Subject"] = f"{prefixo}Greenjoy | Fechamento {dia.strftime('%d/%m')}"
    msg["From"] = GMAIL_USER
    msg["To"] = ", ".join(destinatarios)
    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as s:
        s.login(GMAIL_USER, GMAIL_PASSWORD)
        s.sendmail(GMAIL_USER, destinatarios, msg.as_string())
    log.info(f"Email enviado para: {destinatarios}")


if __name__ == "__main__":
    dia = date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else date.today() - timedelta(days=1)
    enviar(build_html(buscar_dados(dia)), dia, DESTINATARIOS)
