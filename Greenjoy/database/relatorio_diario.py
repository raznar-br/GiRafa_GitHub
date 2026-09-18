"""
relatorio_diario.py
Envia email HTML com o fechamento do dia anterior — Greenjoy Anália Franco.
Rodar após o sync (Task Scheduler 01:00 BRT).
"""

import os, smtplib, logging
from datetime import date, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]

GMAIL_USER     = os.environ["GMAIL_USER"]         # rafa.dallana@gmail.com
GMAIL_PASSWORD = os.environ["GMAIL_APP_PASSWORD"] # app password Google

DESTINATARIOS = [
    "rafa.dallana@gmail.com",
    "brunobjusto@gmail.com",
    "felipemitunari@gmail.com",
    "greenjoyaf@gmail.com",
]

LOJA = "analia_franco"

# ── Dados ─────────────────────────────────────────────────────────────────────

def buscar_dados(ontem: date) -> dict:
    sb = create_client(SUPABASE_URL, SUPABASE_KEY)
    ontem_str = ontem.isoformat()

    # Faturamento do dia por canal
    res_dia = sb.rpc("execute_sql", {}).execute() if False else None  # placeholder
    res_canais = (
        sb.table("kpi_faturamento_diario")
        .select("*")
        .eq("data", ontem_str)
        .execute()
    )
    canais = res_canais.data or []

    # Resumo do mês (kpi_socios_painel — retorna mês corrente)
    res_mes = sb.table("kpi_socios_painel").select("*").execute()
    mes = res_mes.data[0] if res_mes.data else {}

    # Totais do dia
    fat_dia     = sum(c.get("faturamento", 0) or 0 for c in canais)
    pedidos_dia = sum(c.get("qtd_pedidos", 0) or 0 for c in canais)
    ticket_dia  = round(fat_dia / pedidos_dia, 2) if pedidos_dia else 0

    ifood  = next((c for c in canais if c.get("canal") == "iFood"),   {})
    balcao = next((c for c in canais if c.get("canal") == "Balcao"),  {})

    return {
        "ontem":        ontem,
        "fat_dia":      fat_dia,
        "pedidos_dia":  pedidos_dia,
        "ticket_dia":   ticket_dia,
        "ifood_fat":    ifood.get("faturamento", 0) or 0,
        "ifood_ped":    ifood.get("qtd_pedidos",  0) or 0,
        "balcao_fat":   balcao.get("faturamento", 0) or 0,
        "balcao_ped":   balcao.get("qtd_pedidos",  0) or 0,
        "fat_mes":      mes.get("fat_liquido",   0) or 0,
        "meta_mes":     mes.get("valor_meta",    0) or 0,
        "pct_meta":     mes.get("pct_meta",      0) or 0,
        "projecao":     mes.get("projecao_mes",  0) or 0,
        "cmv_pct":      mes.get("cmv_pct",       0) or 0,
        "semaforo_meta": mes.get("semaforo_meta", ""),
        "semaforo_cmv":  mes.get("semaforo_cmv",  ""),
    }


# ── HTML ──────────────────────────────────────────────────────────────────────

DIAS_PT = ["Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado", "Domingo"]
MESES_PT = ["jan","fev","mar","abr","mai","jun","jul","ago","set","out","nov","dez"]

COR = {
    "otimo":   "#16a34a",
    "bom":     "#ca8a04",
    "critico": "#dc2626",
    "":        "#6b7280",
}

def fmt_brl(valor) -> str:
    return f"R$ {float(valor):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")

def pct_canal(parte, total) -> str:
    if not total:
        return "0%"
    return f"{round(100 * parte / total, 1)}%"

def semaforo_label(s: str) -> str:
    return {"otimo": "Ótimo", "bom": "Bom", "critico": "Crítico"}.get(s, "—")

def build_html(d: dict) -> str:
    ontem: date = d["ontem"]
    dia_semana  = DIAS_PT[ontem.weekday()]
    data_fmt    = f"{ontem.day} de {MESES_PT[ontem.month-1].capitalize()} de {ontem.year}"

    cor_meta = COR.get(d["semaforo_meta"], COR[""])
    cor_cmv  = COR.get(d["semaforo_cmv"],  COR[""])

    ifood_pct  = pct_canal(d["ifood_fat"],  d["fat_dia"])
    balcao_pct = pct_canal(d["balcao_fat"], d["fat_dia"])

    return f"""<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="UTF-8">
<style>
  body    {{ font-family: Arial, sans-serif; background:#f4f4f4; margin:0; padding:0; }}
  .wrap   {{ max-width:600px; margin:24px auto; background:#fff; border-radius:8px;
             overflow:hidden; box-shadow:0 2px 8px rgba(0,0,0,.08); }}
  .header {{ background:#1a2e1a; color:#fff; padding:24px 28px; }}
  .header h1 {{ margin:0; font-size:20px; font-weight:700; }}
  .header p  {{ margin:4px 0 0; font-size:13px; color:#a3c4a3; }}
  .body   {{ padding:24px 28px; }}
  .section-title {{ font-size:11px; font-weight:700; color:#6b7280;
                    text-transform:uppercase; letter-spacing:.06em; margin:24px 0 10px; }}
  .cards  {{ display:flex; gap:12px; }}
  .card   {{ flex:1; background:#f9fafb; border:1px solid #e5e7eb;
             border-radius:6px; padding:14px; }}
  .card .val {{ font-size:22px; font-weight:700; color:#1f2937; margin:0; }}
  .card .lbl {{ font-size:11px; color:#6b7280; margin:4px 0 0; }}
  .table  {{ width:100%; border-collapse:collapse; font-size:13px; }}
  .table th {{ text-align:left; padding:8px 10px; background:#f3f4f6;
               color:#374151; font-weight:600; border-bottom:1px solid #e5e7eb; }}
  .table td {{ padding:8px 10px; border-bottom:1px solid #f3f4f6; color:#374151; }}
  .badge  {{ display:inline-block; font-size:11px; font-weight:700; padding:2px 8px;
             border-radius:4px; color:#fff; }}
  .footer {{ background:#f9fafb; border-top:1px solid #e5e7eb;
             padding:14px 28px; font-size:11px; color:#9ca3af; text-align:center; }}
</style>
</head>
<body>
<div class="wrap">

  <div class="header">
    <h1>Fechamento do Dia — Greenjoy Anália Franco</h1>
    <p>{dia_semana}, {data_fmt}</p>
  </div>

  <div class="body">

    <!-- DIA -->
    <div class="section-title">Resultado do dia</div>
    <div class="cards">
      <div class="card">
        <p class="val">{fmt_brl(d['fat_dia'])}</p>
        <p class="lbl">Faturamento líquido</p>
      </div>
      <div class="card">
        <p class="val">{d['pedidos_dia']}</p>
        <p class="lbl">Pedidos</p>
      </div>
      <div class="card">
        <p class="val">{fmt_brl(d['ticket_dia'])}</p>
        <p class="lbl">Ticket médio</p>
      </div>
    </div>

    <!-- CANAL -->
    <div class="section-title">Por canal</div>
    <table class="table">
      <tr>
        <th>Canal</th>
        <th>Pedidos</th>
        <th>Faturamento</th>
        <th>Share</th>
      </tr>
      <tr>
        <td>iFood</td>
        <td>{d['ifood_ped']}</td>
        <td>{fmt_brl(d['ifood_fat'])}</td>
        <td>{ifood_pct}</td>
      </tr>
      <tr>
        <td>Balcão</td>
        <td>{d['balcao_ped']}</td>
        <td>{fmt_brl(d['balcao_fat'])}</td>
        <td>{balcao_pct}</td>
      </tr>
    </table>

    <!-- MÊS -->
    <div class="section-title">Acumulado do mês</div>
    <div class="cards">
      <div class="card">
        <p class="val" style="color:{cor_meta}">{fmt_brl(d['fat_mes'])}</p>
        <p class="lbl">Faturamento acumulado</p>
      </div>
      <div class="card">
        <p class="val" style="color:{cor_meta}">{d['pct_meta']}%</p>
        <p class="lbl">da meta &nbsp;
          <span class="badge" style="background:{cor_meta}">
            {semaforo_label(d['semaforo_meta'])}
          </span>
        </p>
      </div>
    </div>
    <div class="cards" style="margin-top:12px">
      <div class="card">
        <p class="val">{fmt_brl(d['projecao'])}</p>
        <p class="lbl">Projeção do mês</p>
      </div>
      <div class="card">
        <p class="val" style="color:{cor_cmv}">{d['cmv_pct']}%</p>
        <p class="lbl">CMV &nbsp;
          <span class="badge" style="background:{cor_cmv}">
            {semaforo_label(d['semaforo_cmv'])}
          </span>
        </p>
      </div>
    </div>

  </div>

  <div class="footer">
    Greenjoy Anália Franco &nbsp;·&nbsp; Relatório automático gerado às 01:00 BRT
    &nbsp;·&nbsp; Dados: Eclética PDV + Supabase
  </div>

</div>
</body>
</html>"""


# ── Envio ─────────────────────────────────────────────────────────────────────

def enviar(html: str, ontem: date):
    assunto = f"Greenjoy | Fechamento {ontem.strftime('%d/%m/%Y')}"

    msg = MIMEMultipart("alternative")
    msg["Subject"] = assunto
    msg["From"]    = GMAIL_USER
    msg["To"]      = ", ".join(DESTINATARIOS)
    msg.attach(MIMEText(html, "html"))

    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as s:
        s.login(GMAIL_USER, GMAIL_PASSWORD)
        s.sendmail(GMAIL_USER, DESTINATARIOS, msg.as_string())

    log.info(f"Email enviado para: {DESTINATARIOS}")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ontem = date.today() - timedelta(days=1)
    log.info(f"Gerando relatório para {ontem}")
    dados = buscar_dados(ontem)
    html  = build_html(dados)
    enviar(html, ontem)
    log.info("Concluído.")
