"""Placar diário do time (imagem para o grupo do WhatsApp) + envio por email.

    python placar_premio.py                 # gera o placar de ontem
    python placar_premio.py 2026-09-13      # reconstitui um dia
    python placar_premio.py --enviar        # gera e manda para greenjoyaf@gmail.com

Dados: premio_placar(data) e kpi_premio_valores_cargo (views_premio.sql).
Regras: BONUS/Regras_Premiacao_Q4_2026.md. Nunca mostra faturamento em R$.
"""

import os
import sys
import math
import smtplib
import logging
from datetime import date, timedelta
from email.mime.image import MIMEImage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

from dotenv import load_dotenv
from PIL import Image, ImageDraw, ImageFont

from sql import run

BASE = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(BASE, ".env"))
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

SAIDA = os.path.join(BASE, "..", "BONUS", "output", "placar")
DESTINATARIOS = ["greenjoyaf@gmail.com"]

FONTES = r"C:\Windows\Fonts"
W, M = 1080, 44

VERDE_ESCURO = "#1E4D2B"
VERDE = "#2E7D32"
VERDE_CLARO = "#E3F1E4"
AMBAR = "#E09B00"
VERMELHO = "#C62828"
CINZA = "#6B7280"
CINZA_CLARO = "#E5E7EB"
TEXTO = "#1F2937"
FUNDO = "#F3F6F1"

DIAS = ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo"]
DIAS_CURTO = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]
MESES = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho",
         "agosto", "setembro", "outubro", "novembro", "dezembro"]
MES_PILOTO = date(2026, 9, 1)

DICAS_QUALINUT = [
    "Qualinut: etiqueta em todo produto aberto. Vencido, descarte na hora.",
    "Qualinut: produto sempre coberto e identificado, até sobra limpa.",
    "Qualinut: equipamento limpo no fim de cada turno.",
]
DICAS_GOOGLE = [
    "Google: ofereça o QR de avaliação a todo cliente do balcão.",
    "Google: peça avaliação a todo cliente, sem dar nada em troca.",
]
DICAS_IFOOD = [
    "iFood: confira item por item antes de fechar a sacola.",
    "iFood: pedido pronto sai na hora. Atraso tira o Super Restaurante.",
]
DICAS_GERAIS = [
    "Pista: atendimento rápido no pico soma pedido no dia.",
    "Cozinha: gramatura certa em toda receita.",
    "Limpeza: loja limpa no pico ajuda na nota do Google.",
    "Todo mundo: sugira bebida ou sobremesa.",
]


def fonte(tamanho, peso="regular"):
    arquivo = {"regular": "segoeui.ttf", "bold": "segoeuib.ttf", "semi": "seguisb.ttf",
               "simbolo": "seguisym.ttf"}[peso]
    caminho = os.path.join(FONTES, arquivo)
    if not os.path.exists(caminho):
        caminho = os.path.join(FONTES, "segoeuib.ttf" if peso != "regular" else "segoeui.ttf")
    return ImageFont.truetype(caminho, tamanho)


def n(v):
    return f"{int(v):,}".replace(",", ".")


def buscar(ref: date):
    placar = run(f"SELECT * FROM premio_placar('{ref}')", silencioso=True)[0]
    valores = run("SELECT cargo, valor_meta FROM kpi_premio_valores_cargo ORDER BY ordem", silencioso=True)
    return placar, valores


def cor_pct(pct):
    if pct >= 100:
        return VERDE
    if pct >= 95:
        return AMBAR
    return VERMELHO


def dicas(p, ref: date):
    hoje = ref + timedelta(days=1)
    seed = hoje.toordinal()
    linhas = []

    if p["pedidos_ref"] is not None and p["meta_ref"]:
        dif = p["pedidos_ref"] - p["meta_ref"]
        if dif >= 0:
            linhas.append(f"Ontem: meta do dia batida, {n(dif)} pedidos acima. Bora repetir!")
        elif hoje.isoweekday() == 6:
            linhas.append("Sábado é o dia mais forte: é aqui que o mês se decide.")
        else:
            linhas.append(f"Ontem: {n(-dif)} pedidos abaixo da meta do dia. Hoje dá para recuperar.")

    faltando = []
    if not p["qualinut_ok"]:
        faltando.append(DICAS_QUALINUT)
    if not p["google_ok"]:
        faltando.append(DICAS_GOOGLE)
    if not p["ifood_ok"]:
        faltando.append(DICAS_IFOOD)
    pool = faltando[seed % len(faltando)] if faltando else DICAS_GERAIS
    linhas.append(pool[seed % len(pool)])
    return linhas


class Tela:
    def __init__(self, altura=2000):
        self.img = Image.new("RGB", (W, altura), FUNDO)
        self.d = ImageDraw.Draw(self.img)
        self.y = 0

    def texto(self, xy, s, f, cor=TEXTO, anchor="la"):
        self.d.text(xy, s, font=f, fill=cor, anchor=anchor)

    def largura(self, s, f):
        return self.d.textlength(s, font=f)

    def quebrar(self, s, f, largura):
        palavras, linhas, atual = s.split(), [], ""
        for p in palavras:
            teste = f"{atual} {p}".strip()
            if self.largura(teste, f) <= largura:
                atual = teste
            else:
                linhas.append(atual)
                atual = p
        return linhas + [atual]

    def card(self, altura, x0=M, x1=W - M, cor="white"):
        self.d.rounded_rectangle((x0, self.y, x1, self.y + altura), radius=28, fill=cor)
        topo = self.y
        self.y += altura + 22
        return topo

    def barra(self, x0, y, x1, pct, cor):
        self.d.rounded_rectangle((x0, y, x1, y + 26), radius=13, fill=CINZA_CLARO)
        fim = x0 + (x1 - x0) * min(pct, 100) / 100
        if pct > 0:
            self.d.rounded_rectangle((x0, y, max(fim, x0 + 26), y + 26), radius=13, fill=cor)


def desenhar(p, valores, ref: date):
    t = Tela()
    hoje = ref + timedelta(days=1)

    t.d.rectangle((0, 0, W, 190), fill=VERDE_ESCURO)
    t.texto((M, 38), "PLACAR DO TIME", fonte(64, "bold"), "white")
    t.texto((M, 122), "Greenjoy Anália Franco", fonte(32), "#CFE8D2")
    t.d.rounded_rectangle((W - M - 250, 26, W - M, 164), radius=24, fill="white")
    t.texto((W - M - 125, 40), DIAS[hoje.weekday()].upper(), fonte(28, "bold"), VERDE, anchor="ma")
    t.texto((W - M - 125, 76), f"{hoje:%d/%m}", fonte(66, "bold"), VERDE_ESCURO, anchor="ma")
    t.y = 220

    # ONTEM | HOJE
    meio = W // 2
    topo = t.y
    t.card(210, M, meio - 11)
    t.y = topo
    t.card(210, meio + 11, W - M, VERDE_CLARO)
    pct_ref = 100 * p["pedidos_ref"] / p["meta_ref"] if p["meta_ref"] else 0
    t.texto((M + 34, topo + 26), f"ONTEM ({DIAS_CURTO[ref.weekday()]} {ref:%d/%m})", fonte(28, "bold"), CINZA)
    t.texto((M + 34, topo + 66), n(p["pedidos_ref"] or 0), fonte(80, "bold"), TEXTO)
    t.texto((M + 34, topo + 160), f"meta do dia {n(p['meta_ref'] or 0)} · {pct_ref:.0f}%",
            fonte(28, "bold"), cor_pct(pct_ref))
    if p["hoje_aberto"] is False:
        t.texto((meio + 45, topo + 26), "HOJE", fonte(28, "bold"), VERDE_ESCURO)
        t.texto((meio + 45, topo + 80), "Loja fechada", fonte(52, "bold"), VERDE_ESCURO)
    else:
        t.texto((meio + 45, topo + 26), "HOJE PRECISAMOS", fonte(28, "bold"), VERDE_ESCURO)
        t.texto((meio + 45, topo + 66), n(p["meta_hoje"] or 0), fonte(80, "bold"), VERDE_ESCURO)
        t.texto((meio + 45, topo + 160), "pedidos", fonte(28, "bold"), VERDE_ESCURO)

    # SEMANA
    ini = p["semana_inicio"] if isinstance(p["semana_inicio"], date) else date.fromisoformat(p["semana_inicio"])
    fechada = ref.isoweekday() == 7
    rotulo = f"SEMANA {ini:%d/%m} a {ini + timedelta(days=6):%d/%m}" + (" · FECHADA" if fechada else "")
    base = p["semana_meta"] if fechada else p["semana_meta_ate_ref"]
    pct_sem = 100 * (p["semana_pedidos"] or 0) / base if base else 0
    topo = t.card(190)
    t.texto((M + 34, topo + 26), rotulo, fonte(28, "bold"), CINZA)
    t.texto((M + 34, topo + 64), n(p["semana_pedidos"] or 0), fonte(56, "bold"))
    t.texto((M + 34 + t.largura(n(p["semana_pedidos"] or 0), fonte(56, "bold")) + 14, topo + 88),
            f"de {n(base or 0)}" + ("" if fechada else " até ontem"), fonte(30), CINZA)
    t.texto((W - M - 34, topo + 70), f"{pct_sem:.0f}%", fonte(56, "bold"), cor_pct(pct_sem), anchor="ra")
    t.barra(M + 34, topo + 142, W - M - 34, pct_sem, cor_pct(pct_sem))

    # MÊS
    mes = date.fromisoformat(str(p["mes"]))
    pct_mes = float(p["pct_meta"])
    pct_proj = float(p["pct_projecao"] or 0)
    piloto = mes == MES_PILOTO
    topo = t.card(290 if piloto else 240)
    t.texto((M + 34, topo + 26), f"{MESES[mes.month - 1].upper()} · META {n(p['pedidos_meta'])} PEDIDOS",
            fonte(28, "bold"), CINZA)
    t.texto((M + 34, topo + 64), n(p["mes_pedidos"]), fonte(56, "bold"))
    t.texto((M + 34 + t.largura(n(p["mes_pedidos"]), fonte(56, "bold")) + 14, topo + 88),
            "pedidos no mês", fonte(30), CINZA)
    t.texto((W - M - 34, topo + 70), f"{pct_mes:.0f}%", fonte(56, "bold"), TEXTO, anchor="ra")
    t.barra(M + 34, topo + 142, W - M - 34, pct_mes, cor_pct(pct_proj))
    dias = p["dias_restantes"]
    if dias:
        por_dia = math.ceil(p["faltam_meta"] / dias)
        ritmo = {"Super Green": "Super Green", "Mega Green": "Super Green", "Ultra Green": "Super Green",
                 "Meta": "Meta", "Quase lá": "Quase lá"}.get(p["faixa_projetada"], "abaixo de 95%")
        linha = f"Faltam {n(p['faltam_meta'])} em {dias} dias (~{por_dia}/dia) · ritmo: {ritmo}"
    else:
        linha = f"Mês fechado · faixa: {p['faixa_projetada']}"
    t.texto((M + 34, topo + 186), linha, fonte(29, "bold"), cor_pct(pct_proj))
    if piloto:
        t.texto((M + 34, topo + 232), "Setembro é o mês de lançamento: prêmio da Meta garantido.",
                fonte(28), VERDE)

    # SELOS
    topo = t.card(250)
    t.texto((M + 34, topo + 26), "SELOS DO MÊS · +10% CADA", fonte(28, "bold"), CINZA)
    nota = p["qualinut_nota"]
    selos = [
        ("Qualinut", p["qualinut_ok"],
         f"nota {float(nota):.0f}% (precisa 65%)" if nota is not None else "sem visita"),
        ("iFood Super", p["ifood_ok"], "ativo" if p["ifood_ok"] else "em apuração" if p["ifood_ok"] is None else "inativo"),
        ("Google", p["google_ok"],
         f"{p['google_avaliacoes']}/30 · média {float(p['google_media']):.1f}".replace(".", ",")
         if p["google_avaliacoes"] is not None else "em apuração"),
    ]
    for i, (nome, ok, detalhe) in enumerate(selos):
        y = topo + 78 + i * 56
        cor = VERDE if ok else CINZA if ok is None or nome == "Google" and p["google_avaliacoes"] is None else AMBAR
        t.d.ellipse((M + 34, y + 4, M + 70, y + 40), fill=cor)
        t.texto((M + 52, y + 22), "✓" if ok else "…" if ok is None else "!", fonte(24, "simbolo"), "white", anchor="mm")
        t.texto((M + 90, y + 2), nome, fonte(32, "bold"))
        t.texto((W - M - 34, y + 4), detalhe, fonte(30), cor if cor != CINZA else CINZA, anchor="ra")

    # VALORES
    topo = t.card(180)
    t.texto((M + 34, topo + 26), "NA META, CADA UM GANHA NO MÊS", fonte(28, "bold"), CINZA)
    larg = (W - 2 * M - 68 - 4 * 12) / len(valores)
    for i, v in enumerate(valores):
        x = M + 34 + i * (larg + 12)
        t.d.rounded_rectangle((x, topo + 72, x + larg, topo + 152), radius=18, fill=VERDE_CLARO)
        t.texto((x + larg / 2, topo + 82), v["cargo"], fonte(24, "bold"), VERDE_ESCURO, anchor="ma")
        t.texto((x + larg / 2, topo + 112), f"R$ {float(v['valor_meta']):.0f}", fonte(34, "bold"), VERDE_ESCURO, anchor="ma")

    # DICAS
    linhas = []
    f_dica = fonte(30)
    for s in dicas(p, ref):
        linhas.extend(t.quebrar(s, f_dica, W - 2 * M - 110))
    topo = t.card(58 + 44 * len(linhas), cor="#FFF7E0")
    t.d.rounded_rectangle((M, topo, M + 14, topo + 58 + 44 * len(linhas)), radius=7, fill=AMBAR)
    for i, s in enumerate(linhas):
        t.texto((M + 50, topo + 28 + i * 44), s, f_dica, TEXTO)

    t.texto((W // 2, t.y + 6), "Prêmio por desempenho com vigência determinada · regulamento com a gestão",
            fonte(22), CINZA, anchor="ma")
    return t.img.crop((0, 0, W, t.y + 52))


def enviar(caminho, ref: date):
    hoje = ref + timedelta(days=1)
    msg = MIMEMultipart("related")
    msg["Subject"] = f"Placar do Time · {DIAS_CURTO[hoje.weekday()]} {hoje:%d/%m}"
    msg["From"] = os.environ["GMAIL_USER"]
    msg["To"] = ", ".join(DESTINATARIOS)
    msg.attach(MIMEText(
        '<p>Placar pronto para encaminhar no grupo do time.</p><img src="cid:placar" width="540">',
        "html", "utf-8"))
    with open(caminho, "rb") as fh:
        dados = fh.read()
    inline = MIMEImage(dados, "png")
    inline.add_header("Content-ID", "<placar>")
    inline.add_header("Content-Disposition", "inline", filename=os.path.basename(caminho))
    msg.attach(inline)
    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as s:
        s.login(os.environ["GMAIL_USER"], os.environ["GMAIL_APP_PASSWORD"])
        s.sendmail(os.environ["GMAIL_USER"], DESTINATARIOS, msg.as_string())
    log.info(f"Placar enviado para {DESTINATARIOS}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ref = date.fromisoformat(args[0]) if args else date.today() - timedelta(days=1)
    placar, valores = buscar(ref)
    if placar["mes"] is None or placar["pedidos_meta"] is None:
        log.warning(f"Sem meta cadastrada para {ref:%m/%Y} — placar não gerado")
        return
    if str(placar["ultimo_dia_sincronizado"]) < str(ref):
        log.error(f"PDV sincronizado só até {placar['ultimo_dia_sincronizado']} — placar de {ref} não gerado")
        sys.exit(1)
    os.makedirs(SAIDA, exist_ok=True)
    caminho = os.path.join(SAIDA, f"placar_{ref + timedelta(days=1)}.png")
    marcador = caminho.replace(".png", ".enviado")
    if "--enviar" in sys.argv and os.path.exists(marcador):
        log.info(f"Placar de {ref + timedelta(days=1)} já enviado — nada a fazer")
        return
    desenhar(placar, valores, ref).save(caminho, optimize=True)
    log.info(f"Placar salvo em {caminho}")
    if "--enviar" in sys.argv:
        enviar(caminho, ref)
        open(marcador, "w").close()


if __name__ == "__main__":
    main()
