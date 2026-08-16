"""Extrai as auditorias Qualinut dos PDFs e carrega em auditoria_qualinut / auditoria_qualinut_itens.

O PDF de critérios é o catálogo canônico de perguntas e pesos. Cada auditoria é lida
buscando as perguntas do catálogo no texto e capturando a resposta que vem logo depois.
A soma dos pontos obtidos é conferida contra o score impresso no cabeçalho do PDF.
"""

import os
import re
import json
import glob
import unicodedata

import fitz
from dotenv import load_dotenv
from supabase import create_client

BASE = os.path.dirname(os.path.abspath(__file__))
AUDITORIAS = os.path.join(BASE, "Auditorias")
CRITERIO = os.path.join(AUDITORIAS, "Critério de notas Greenjoy - 2026.pdf")

# prefixo normalizado -> rótulo curto usado no dashboard
CATEGORIAS = {
    "pontos criticos": "PONTOS CRÍTICOS",
    "manipulacao e qualidade": "MANIPULAÇÃO E QUALIDADE",
    "procedimentos de higienizacao": "HIGIENIZAÇÃO",
    "recebimento e armazenamento": "RECEBIMENTO E ARMAZENAMENTO",
    "documentacao": "DOCUMENTAÇÃO",
}


def match_categoria(linha):
    n = norm(linha)
    for pref, rotulo in CATEGORIAS.items():
        if n.startswith(pref):
            return rotulo
    return None

RE_SCORE = re.compile(r"(\d+)\s*/\s*(\d+)\s*\((\d+[.,]?\d*)%\)")
# o SafetyCulture exporta ora em inglês ("3 Aug 2026"), ora em português
# ("22 jul. 2026") — depende do idioma da conta que gerou o PDF
RE_DATA = re.compile(
    r"(\d{1,2})\s+(jan|feb|fev|mar|apr|abr|may|mai|jun|jul|aug|ago|sep|set|oct|out|nov|dec|dez)\.?\s+(\d{4})",
    re.I)
# "nao verificado" precisa estar aqui: sem ele o item sem verificação não casa
# resposta nenhuma e a busca segue até o "Conforme" do item seguinte, marcando
# como conforme algo que o auditor não chegou a avaliar
RE_RESP = re.compile(r"\b(nao conforme|conforme|nao verificado|nao se aplica|n a)\b")
MESES = {"jan": 1, "feb": 2, "fev": 2, "mar": 3, "apr": 4, "abr": 4, "may": 5, "mai": 5,
         "jun": 6, "jul": 7, "aug": 8, "ago": 8, "sep": 9, "set": 9, "oct": 10, "out": 10,
         "nov": 11, "dec": 12, "dez": 12}
MAP_RESP = {"conforme": "C", "nao conforme": "NC", "nao verificado": "NA",
            "nao se aplica": "NA", "n a": "NA"}


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^a-zA-Z0-9]+", " ", s.lower())
    return re.sub(r"\s+", " ", s).strip()


RE_RODAPE = re.compile(r"^private & confidential$", re.I)


def limpar(texto):
    """Remove o índice vertical do SafetyCulture (blocos longos de linhas de 1 caractere)
    e o rodapé de página."""
    out, buf = [], []
    for ln in texto.split("\n"):
        if RE_RODAPE.match(ln.strip()):
            continue
        if len(ln.strip()) <= 1:
            buf.append(ln.strip())
            continue
        if len(buf) < 8:
            out.extend(b for b in buf if b)
        buf = []
        out.append(ln.strip())
    return [l for l in out if l]


def ler_criterio():
    """Retorna [{categoria, pergunta, pontos}] na ordem do checklist v.4."""
    doc = fitz.open(CRITERIO)
    linhas = limpar("\n".join(p.get_text() for p in doc))

    itens, categoria, buf = [], None, []
    for ln in linhas:
        cat = match_categoria(ln)
        if cat:
            categoria, buf = cat, []
            continue
        if RE_SCORE.search(ln) or re.fullmatch(r"\d+/\d+", ln.strip()):
            buf = []
            continue
        m = re.search(r"Pontua[çc][ãa]o:\s*(-?\d+)", ln, re.I)
        if m:
            # a pergunta é o início do bloco: linhas antes do primeiro bullet "-"
            pergunta = []
            for b in buf:
                if b.startswith("-") or b.startswith("*") or b.isupper() and len(b) > 40:
                    break
                pergunta.append(b)
            texto = " ".join(pergunta).strip()
            # o cabeçalho de pontuação da seção ("146 (0%)", "60 (0%)") gruda no
            # início da primeira pergunta de cada categoria. Sem tirar, a chave
            # nasce como "60 0 ausencia de produtos vencidos..." e nunca casa com
            # o texto da auditoria — foi assim que o item de 12 pts, o mais pesado
            # do checklist, sumia de todas as 8 auditorias.
            texto = re.sub(r"^\s*\d+\s*\(\d+[.,]?\d*%\)\s*", "", texto).strip()
            pts = int(m.group(1))
            if categoria and pts > 0 and len(norm(texto)) > 20:
                itens.append({"categoria": categoria, "pergunta": texto,
                              "pontos": pts, "chave": norm(texto)})
            buf = []
            continue
        buf.append(ln)
    return itens


def parse_auditoria(caminho, catalogo):
    doc = fitz.open(caminho)
    linhas = limpar("\n".join(p.get_text() for p in doc))
    cab = "\n".join(linhas[:40])

    m = RE_DATA.search(cab)
    if not m:
        raise ValueError(f"data não encontrada em {caminho}")
    data = f"{m.group(3)}-{MESES[m.group(2).lower()]:02d}-{int(m.group(1)):02d}"
    versao = "v.4" if "v.4" in cab else "v.3"

    auditor = None
    for i, ln in enumerate(linhas[:40]):
        if ln.startswith("Aplicado por") and i + 1 < len(linhas):
            auditor = linhas[i + 1]
            break

    ms = RE_SCORE.search(cab)
    score, score_max = (int(ms.group(1)), int(ms.group(2))) if ms else (None, None)

    # subtotais oficiais por categoria, impressos no próprio relatório
    # ("PONTOS CRÍTICOS" seguido de "23 / 59 (38.98%)"). São a fonte da verdade —
    # derivar categoria a partir do casamento item a item subestima o máximo,
    # porque o checklist v.3 tem perguntas que não existem no critério v.4.
    categorias = {}
    for i, ln in enumerate(linhas):
        cat = match_categoria(ln)
        if not cat or cat in categorias:
            continue
        for prox in linhas[i + 1:i + 4]:
            mc = RE_SCORE.fullmatch(prox.strip())
            if mc:
                categorias[cat] = (int(mc.group(1)), int(mc.group(2)))
                break

    # texto contínuo normalizado: imune às quebras de linha do PDF
    plano = norm(" ".join(linhas))

    # localiza cada pergunta em ordem de documento (cursor sequencial evita
    # casar com a mesma frase repetida numa observação anterior)
    achados, cursor = [], 0
    for c in catalogo:
        chave = c["chave"]
        pos = plano.find(chave, cursor)
        if pos < 0:
            pos = plano.find(chave)  # fora de ordem: checklist v.3 reordena
        if pos < 0:
            # duas coisas quebram o casamento da frase inteira: o v.3 reformula o
            # fim de algumas perguntas, e quando uma pergunta quebra entre páginas
            # o PDF injeta o badge da resposta no meio dela ("...procedimento ou
            # CONFORME separação física..."). Encurtar o prefixo resolve os dois.
            for n in range(8, 3, -1):
                prefixo = " ".join(chave.split()[:n])
                if len(prefixo) < 30:
                    break
                pos = plano.find(prefixo, cursor)
                if pos < 0:
                    pos = plano.find(prefixo)
                if pos >= 0:
                    chave = prefixo
                    break
        if pos < 0:
            continue
        achados.append((pos, pos + len(chave), c))
        cursor = pos + len(chave)

    achados.sort(key=lambda x: x[0])
    itens = []
    for idx, (ini, fim, c) in enumerate(achados):
        limite = achados[idx + 1][0] if idx + 1 < len(achados) else len(plano)
        mr = RE_RESP.search(plano[fim:limite])
        if not mr:
            continue
        resposta = MAP_RESP[mr.group(1)]
        itens.append({
            "categoria": c["categoria"],
            "item": c["pergunta"],
            "item_chave": c["chave"],
            "resposta": resposta,
            "pontos_max": c["pontos"],
            "pontos_obtidos": c["pontos"] if resposta == "C" else 0,
        })

    return {
        "data": data,
        "versao_checklist": versao,
        "auditor": auditor,
        # score/pct oficiais do cabeçalho do PDF — fonte da verdade da curva
        "score": score,
        "score_max": score_max,
        "pct": round(100.0 * score / score_max, 2) if score and score_max else None,
        # itens alimentam Pareto e reincidência; a soma pode divergir alguns pontos
        # porque o checklist v.3 tem perguntas que não existem no critério v.4
        "itens_casados": len(itens),
        "itens_catalogo": len(catalogo),
        "pontos_calculados": sum(i["pontos_obtidos"] for i in itens),
        "categorias": categorias,
        "itens": itens,
        "arquivo": os.path.basename(caminho),
    }


def main():
    catalogo = ler_criterio()
    print(f"catalogo: {len(catalogo)} perguntas, {sum(c['pontos'] for c in catalogo)} pts")
    for c in CATEGORIAS.values():
        sub = [x for x in catalogo if x["categoria"] == c]
        print(f"  {c:30} {len(sub):2} itens  {sum(x['pontos'] for x in sub):3} pts")

    auditorias = {}
    for f in sorted(glob.glob(os.path.join(AUDITORIAS, "Analia-Franco-*.pdf"))):
        a = parse_auditoria(f, catalogo)
        if a["data"] in auditorias:
            continue
        auditorias[a["data"]] = a

    print("\ndata        ver  oficial      calculado  itens  delta  categorias")
    for d in sorted(auditorias):
        a = auditorias[d]
        calc = sum(i["pontos_obtidos"] for i in a["itens"])
        cmax = sum(i["pontos_max"] for i in a["itens"] if i["resposta"] != "NA")
        soma_cat = sum(v[0] for v in a["categorias"].values())
        ok = "OK" if soma_cat == a["score"] else f"!! soma={soma_cat}"
        print(f"{d}  {a['versao_checklist']}  {a['score']:3}/{a['score_max']:3}      "
              f"{calc:3}/{cmax:3}   {len(a['itens']):2}     {calc - a['score']:+d}   "
              f"{len(a['categorias'])} {ok}")

    dump = os.path.join(BASE, "output", "auditorias_parsed.json")
    os.makedirs(os.path.dirname(dump), exist_ok=True)
    with open(dump, "w", encoding="utf-8") as fh:
        json.dump([auditorias[d] for d in sorted(auditorias)], fh, ensure_ascii=False, indent=1)
    print(f"\njson: {dump}")

    if os.environ.get("DRY_RUN"):
        return

    load_dotenv(os.path.join(BASE, "..", "database", ".env"))
    sb = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])

    for d in sorted(auditorias):
        a = auditorias[d]
        sb.table("auditoria_qualinut").upsert({
            "data": a["data"], "versao_checklist": a["versao_checklist"],
            "auditor": a["auditor"], "score": a["score"], "score_max": a["score_max"],
            "pct": a["pct"], "arquivo": a["arquivo"],
        }, on_conflict="data").execute()

        sb.table("auditoria_qualinut_categoria").delete().eq("data", a["data"]).execute()
        if a["categorias"]:
            sb.table("auditoria_qualinut_categoria").insert([
                {"data": a["data"], "categoria": c, "obtido": v[0], "maximo": v[1],
                 "pct": round(100.0 * v[0] / v[1], 2) if v[1] else None}
                for c, v in a["categorias"].items()
            ]).execute()

        sb.table("auditoria_qualinut_itens").delete().eq("data", a["data"]).execute()
        linhas = [{"data": a["data"], "categoria": i["categoria"], "item": i["item"][:500],
                   "item_chave": i["item_chave"][:300], "resposta": i["resposta"],
                   "pontos_max": i["pontos_max"], "pontos_obtidos": i["pontos_obtidos"]}
                  for i in a["itens"]]
        for j in range(0, len(linhas), 200):
            sb.table("auditoria_qualinut_itens").insert(linhas[j:j + 200]).execute()
        print(f"  {a['data']}: {len(linhas)} itens carregados")


if __name__ == "__main__":
    main()
