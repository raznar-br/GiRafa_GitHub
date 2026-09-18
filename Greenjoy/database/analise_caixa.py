from dotenv import load_dotenv
import os
load_dotenv()
from supabase import create_client
from collections import defaultdict

sb = create_client(os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_KEY'))

meses_range = {
    '2025-12': ('2025-12-01','2025-12-31'),
    '2026-01': ('2026-01-01','2026-01-31'),
    '2026-02': ('2026-02-01','2026-02-28'),
    '2026-03': ('2026-03-01','2026-03-31'),
    '2026-04': ('2026-04-01','2026-04-30'),
}
dre = defaultdict(lambda: defaultdict(float))
for m, (ini, fim) in meses_range.items():
    r = sb.table('dre_competencia').select('linha_dre,valor').gte('periodo', ini).lte('periodo', fim).limit(3000).execute()
    for row in r.data:
        dre[m][row['linha_dre']] += float(row['valor'] or 0)

meses = sorted(meses_range.keys())

# Helper: pega valor de linha (tolerante a acentos)
def g(m, chave):
    if chave in dre[m]:
        return dre[m][chave]
    chave_low = chave.lower().replace(' ','')
    for l, v in dre[m].items():
        if l.lower().replace(' ','') == chave_low:
            return v
    return 0

# Correcao abril: INSS+FGTS faltantes
folha_abr = g('2026-04', 'Folha')
folha_mar = g('2026-03', 'Folha')
inss_mar   = g('2026-03', 'INSS') + g('2026-03', 'INSS Terceiros')
fgts_mar   = g('2026-03', 'FGTS')
inss_est   = folha_abr * (inss_mar / folha_mar) if folha_mar else 0
fgts_est   = folha_abr * (fgts_mar / folha_mar) if folha_mar else 0
correcao   = inss_est + fgts_est

# Pega linha Funcionarios
def get_func(m):
    for l, v in dre[m].items():
        if 'Funcion' in l and 'rios' in l and '(-)'  not in l:
            return v
    return 0

func_raw = {m: get_func(m) for m in meses}
func_corr = dict(func_raw)
func_corr['2026-04'] += correcao

# Resultado corrigido
res_raw  = {m: g(m, 'Resultado pre investimentos') or g(m, 'Resultado pré investimentos') for m in meses}
# fallback busca
for m in meses:
    if res_raw[m] == 0:
        for l, v in dre[m].items():
            if 'resultado' in l.lower() and 'invest' in l.lower():
                res_raw[m] = v
                break
res_corr = dict(res_raw)
res_corr['2026-04'] -= correcao

print(f'CORRECAO ABRIL: +R${correcao:,.0f} encargos (INSS R${inss_est:,.0f} + FGTS R${fgts_est:,.0f})')
print()

cabecalho = f'{"Indicador":<35}' + ''.join(f'{m:>10}' for m in meses)
cabecalho += f'  {"Med Dez-Fev":>12}  {"Med Mar-Abr":>12}  {"Delta/mes":>10}'
print(cabecalho)
print('-' * len(cabecalho))

def row(label, vals_dict):
    s = f'{label:<35}'
    for m in meses:
        v = vals_dict.get(m, 0)
        s += f'{v:>10,.0f}' if v else f'{"—":>10}'
    ant = [vals_dict.get(m, 0) for m in ['2025-12','2026-01','2026-02']]
    rec = [vals_dict.get(m, 0) for m in ['2026-03','2026-04']]
    med_ant = sum(ant) / 3
    med_rec = sum(rec) / 2
    delta = med_rec - med_ant
    sinal = '+' if delta >= 0 else ''
    s += f'  {med_ant:>12,.0f}  {med_rec:>12,.0f}  {sinal}{delta:>9,.0f}'
    print(s)

# Faturamento
fat = {m: g(m, 'Faturamento SAT') for m in meses}
row('Faturamento Bruto (SAT)', fat)
rec_bruta = {m: g(m, 'Receita Bruta') for m in meses}
row('Receita Bruta (DRE)', rec_bruta)
print()

# Custos
custos = {m: g(m, 'Custos') for m in meses}
row('Custos Totais', custos)
print()

# Pessoal
row('Funcionarios DRE (raw)', func_raw)
row('Funcionarios CORRIGIDO', func_corr)
folha = {m: g(m, 'Folha') for m in meses}
row('  Folha base', folha)
resc = {}
for m in meses:
    for l, v in dre[m].items():
        if 'Rescis' in l and 'FGTS' not in l:
            resc[m] = v
            break
row('  Rescisao', resc)
fgts_resc = {}
for m in meses:
    for l, v in dre[m].items():
        if 'FGTS' in l and 'Rescis' in l:
            fgts_resc[m] = v
            break
row('  FGTS Rescisao', fgts_resc)
print()

# Resultado
ebitda = {m: g(m, 'EBITDA') for m in meses}
row('EBITDA', ebitda)
row('Resultado pre invest (raw)', res_raw)
row('Resultado pre invest (CORRIG)', res_corr)
print()

# Resumo impacto
print('=== IMPACTO ACUMULADO MAR-ABR vs RITMO DEZ-FEV ===')
med_ant_res = sum(res_raw[m] for m in ['2025-12','2026-01','2026-02']) / 3
res_acc = res_corr['2026-03'] + res_corr['2026-04']
esperado = med_ant_res * 2
queimado = res_acc - esperado
print(f'  Media resultado mensal (Dez-Fev):          R${med_ant_res:>10,.0f}')
print(f'  Resultado acumulado Mar+Abr (corrigido):   R${res_acc:>10,.0f}')
print(f'  Esperado no mesmo ritmo (2 meses):         R${esperado:>10,.0f}')
print(f'  CAIXA QUEIMADO vs ESPERADO:                R${queimado:>10,.0f}')
print()
print('  Decomposicao:')
resc_norm = sum(resc.get(m, 0) for m in ['2025-12','2026-01','2026-02']) / 3
resc_atual = sum(resc.get(m, 0) for m in ['2026-03','2026-04']) / 2
resc_extra = (resc_atual - resc_norm) * 2
print(f'    Rescisoes acima do normal:   R${resc_extra:>8,.0f}  ({resc_norm:,.0f}/mes -> {resc_atual:,.0f}/mes)')
folha_norm = sum(folha.get(m, 0) for m in ['2025-12','2026-01','2026-02']) / 3
folha_atual = sum(folha.get(m, 0) for m in ['2026-03','2026-04']) / 2
folha_extra = (folha_atual - folha_norm) * 2
print(f'    Folha acima do normal:       R${folha_extra:>8,.0f}  ({folha_norm:,.0f}/mes -> {folha_atual:,.0f}/mes)')
print(f'    Encargos faltantes abril:    R${correcao:>8,.0f}  (lancamento pendente)')
fat_norm = sum(fat.get(m, 0) for m in ['2025-12','2026-01','2026-02']) / 3
fat_atual = sum(fat.get(m, 0) for m in ['2026-03','2026-04']) / 2
fat_delta = (fat_atual - fat_norm) * 2
print(f'    Variacao faturamento:        R${fat_delta:>8,.0f}  ({fat_norm:,.0f}/mes -> {fat_atual:,.0f}/mes)')
