# Greenjoy — Project Guide

## O que é
Projeto profissional paralelo de Rafael na área de qualidade nutricional / fornecedores.
Envolve auditorias de qualidade (Qualinut), análise de dados de compras, reuniões com fornecedores
e dashboard de gestão remota para os sócios da unidade Anália Franco.

## Estrutura de Pastas
```
Greenjoy/
  CLAUDE.md                  ← este arquivo
  CONTEXTO_DASHBOARD.md      ← arquitetura técnica do dashboard (ler ao trabalhar com dados)
  database/
    sync_ecletica.py              ← sync diário MySQL → Supabase (00:30 BRT — Task: GreenjoySync)
    relatorio_diario.py           ← envia email HTML de fechamento para os 3 sócios (01:00 BRT — Task: GreenjoyRelatorio)
    importar_everest.py           ← import histórico Everest (arquivos em dados/) → Supabase
    importar_everest_compras.py   ← import corrente Everest CMV (pasta Everest - compras/) — rodar 2-3×/semana
    importar_jafeb.py             ← import DRE + de-para JAFEB → Supabase (mensal)
    setup_btg_auth.py            ← autorização OAuth BTG (rodar 1 vez)
    sync_btg.py                  ← sync direto API BTG → Supabase (alternativa ao Apps Script)
    importar_btg_gsheet.py       ← import histórico CSV exportado do Google Sheet BTG
    greenjoy_schema.sql           ← schema de referência das tabelas
    views_dashboard.sql           ← views KPI operacionais
    views_socios.sql              ← views KPI para sócios (painel, histórico, canal)
    run_sync.bat                  ← launcher do sync para Task Scheduler
    run_relatorio.bat             ← launcher do relatório para Task Scheduler
    .env                          ← credenciais (não commitar — inclui GMAIL_USER e GMAIL_APP_PASSWORD)
  dados/
    Everest Compras_*.xlsx        ← exportações Everest históricas (usadas por importar_everest.py)
  Everest - compras/
    Extraçao_*.xlsx               ← arquivos CMV correntes (Rafael atualiza 2-3×/semana)
  Qualinut/
    CONTEXTO_QUALINUT.md     ← parser, régua da pauta e armadilhas do PDF (ler antes de mexer)
    Auditorias/              ← PDFs de avaliações de qualidade + Critério de notas
    importar_auditorias.py   ← extrai os PDFs → auditoria_qualinut* no Supabase (rodar a cada visita)
    gerar_ppt_qualinut.py    ← gerador de slide deck PPTX (Claude lê; não executa autonomamente)
    analise_qualinut_2026.md ← análise de auditoria (referência de conferência do parser)
    output/                  ← PPTX, PDF e auditorias_parsed.json
  reunioes/
    gerar_talking_points.py  ← gerador de DOCX para reuniões (Claude lê; não executa autonomamente)
    output/                  ← DOCXs gerados
  BONUS/                     ← sistema de premiação da equipe (ver BONUS/README.md)
    dashboard/               ← bonus_views.sql + bonus_gerente.sql (Supabase) + lovable_prompt_bonus.md
    scripts/                 ← geradores DOCX/PPTX/XLSX, custo/ROI e gerar_auditoria_bonus.py (Excel sob demanda)
    output/                  ← Aprovacao_*.docx, Premiacao PPTX/PDF, Auditoria_Bonus_Greenjoy.xlsx
    Parecer_Juridico_Bonus.md ← riscos trabalhistas do programa (Jul/2026 — ler antes de mudar regra)
  docs/
    Greenjoy_Dashboard_Plano.md  ← roadmap 90 dias do dashboard
    Analise KPIs Gestão.md       ← referência de benchmarks e KPIs para fast casual
  Pesquisa/
```

## Dashboard (Supabase + Lovable)

- **Supabase:** projeto `xlpcnkjqitdimcpwnkcv` — banco PostgreSQL com dados de PDV e compras
- **Lovable:** projeto `987f37ae-c7c8-44f4-ad79-11847a51e1a6` — dashboard web
- **Sync automático:** `sync_ecletica.py` roda às 00:30 BRT via Task Scheduler (`GreenjoySync`) — ao final atualiza `mv_produto_dia`
- **Relatório diário:** `relatorio_diario.py` roda às 01:00 BRT — envia email HTML para os 3 sócios (`GreenjoyRelatorio`)
- **BTG sync:** Google Apps Script (greenjoyaf@gmail.com, bound ao Sheet "Movimentações BTG") — diário 06:00 BRT
- **Aplicar schema:** `python database/aplicar_views.py` (ordem de dependência, seguro repetir). **Cada view tem uma única definição, num único arquivo** — duplicar já causou reversão silenciosa de correção
- **SQL avulso:** `database/sql.py` (Management API, `SUPABASE_PAT` no `.env`) — `python sql.py arquivo.sql` ou `from sql import run`
- **RLS:** `metas` só leitura para anon; `registro_desperdicio` aceita escrita anon de propósito — `/desperdicio`, `/bonus` e `/bonus-gerente` rodam **sem login** (`__root.tsx:113`)
- **CMV / DRE / folha:** sempre pela view `btg_classificado`, nunca `btg_movimentacoes` cru. Precedência `btg_classificacao` → `jafeb_despesas_mapping` → não classificado. Naturezas: Custo, Despesa, Folha, Imposto, CAPEX, Transferência. Cobertura em `kpi_cobertura_mapping` (avisa se >5%); fila de trabalho em `kpi_mapping_pendentes`
- **CMV oficial é rolling 30d** (`kpi_cmv_rolling`), não compras-do-mês/faturamento-do-mês — compra é lumpy e o número do mês parcial dá alarme falso
- **Prime Cost é medido**, não estimado: folha + encargos do extrato. Meta ≤58% ótimo, ≤65% limite
- **Fontes aposentadas (Ago/2026):** Everest (parou 18/05) e DRE JAFEB (parou Mai/26). Everest sobrou só em `ref_custo_produto` para o formulário do estoquista
- **Monitor de bases:** `kpi_status_bases` (frescor) + `kpi_dias_suspeitos` (dia sem venda ou <50% da mediana) + skill `/greenjoy-validar`
- **Bônus:** alvo individual fixo por faixa (op/mês: quase lá 115 · meta 165 · superou 230; líder ×1,2, chefe ×1,5). Meta comunicada ao time em **pedidos**; prêmio em R$. `kpi_bonus_semanal.valor_por_cota` = valor semanal do op; `pool_semana` = custo derivado (valor × elegíveis). Custo variável com o quadro. App `/bonus` gamificado (missão do mês + selos, navegação ‹ › por mês, ~3 meses); gestão em `/bonus-gestao`. Gerente: `/bonus-gerente` (semanal 240/300/450 + custos por faixa do mês com split CMV ≤31% 60% · Folha ≤21% 40%, extras ×1,25; apuração dia 10 em `bonus_gerente_mensal` — SQL em `BONUS/dashboard/bonus_gerente.sql`). Trilha auditável: `BONUS/scripts/gerar_auditoria_bonus.py` → Excel com histórico completo e fontes
- **Qualinut:** 12 auditorias importadas até 03/08/26 (57,97% — meta 70%). A aba `/qualidade` abre com a **pauta da reunião semanal** (`kpi_qualinut_pauta` + `kpi_qualinut_pauta_resumo`), botão de copiar em texto. Ordem da pauta = risco sanitário primeiro (flag `qualinut_acoes.critico_sanitario`, entra por gravidade e não por nota), depois pontos esperados = peso × taxa de reprovação + meio peso se regrediu. Item que reprovou e veio "não verificado" na visita seguinte **continua na pauta** como `nao_reavaliado` — sem isso a documentação legal vencida sumia. `kpi_qualinut_movimento` dá o placar fechado/regrediu/não reavaliado vs a visita anterior
- **Parser Qualinut:** o SafetyCulture exporta ora em inglês, ora em português (`22 jul. 2026`), e quando a pergunta quebra entre páginas injeta o badge da resposta no meio dela — por isso `importar_auditorias.py` casa por prefixo decrescente. "Não Verificado" é NA; sem tratar, o item herdava o "Conforme" do item seguinte
- **Skill:** usar `/greenjoy-dashboard` para diagnóstico, sync manual, e novas views

**Fórmula crítica — Saldo Líquido:**
```
vlr_total + COALESCE(vlr_serv, 0) - COALESCE(vlr_desc_tot, 0)
```
Nunca usar `vlr_total` sozinho. Nunca subtrair `outras_taxas`.

## Scripts Existentes
- `database/sql.py` — roda SQL no Supabase via Management API (usado por todos os outros)
- `database/sync_ecletica.py` — sync incremental Eclética MySQL → Supabase (00:30 BRT) + refresh de `mv_produto_dia`
- `database/relatorio_diario.py` — email HTML de fechamento diário para os 3 sócios (01:00 BRT)
- `database/dump_classificacao.py` — regenera `btg_classificacao_inferidos.sql` a partir do banco (rodar após classificar chaves novas)
- `Qualinut/importar_auditorias.py` — extrai os PDFs de auditoria → `auditoria_qualinut*` (rodar a cada visita da Qualinut; `DRY_RUN=1` só confere sem gravar)
- `database/importar_everest_compras.py` — Everest, **aposentado** do dashboard; manter para reativação
- `database/importar_jafeb.py` — DRE + de-para JAFEB; a DRE saiu do dashboard, o de-para continua em uso
- `database/setup_btg_auth.py` — fluxo OAuth BTG, rodar 1 vez para gerar refresh token
- `database/sync_btg.py` — sync direto API BTG → `btg_movimentacoes` (alternativa; método ativo é o Apps Script)
- `database/importar_btg_gsheet.py` — import CSV histórico exportado do Drive (uso único)
- `Qualinut/gerar_ppt_qualinut.py` — gera PPTX de auditoria com python-pptx
- `reunioes/gerar_talking_points.py` — gera DOCX de reuniões com python-docx

**Enviar relatório manualmente para uma data específica:**
```python
# No terminal, dentro de database/
python -c "
from datetime import date
import relatorio_diario as r
ontem = date(2026, 5, 11)  # ajustar data
r.enviar(r.build_html(r.buscar_dados(ontem)), ontem)
"
```

## Ferramentas
- Python + pandas para análise de dados Excel
- python-pptx para geração de apresentações
- python-docx para documentos Word
- supabase (Python client) + Supabase MCP para dados
- WebFetch permitido para: acomsistemas.com.br e homologacao.acomsistemas.com.br

## Permissões (.claude/settings.json já configurado)
- Leitura de Downloads
- Bash para operações de pasta no Greenjoy
- python -c para testes rápidos
- WebFetch para acomsistemas.com.br

## Skills Disponíveis
| Skill | Quando usar |
|---|---|
| `/greenjoy-dashboard` | Dados desatualizados, novas views, manutenção do dashboard |
| `/greenjoy-validar` | Checar saúde das bases (frescor, buracos, CMV, bônus) e ações corretivas |
| `/greenjoy-audit` | Processar auditoria Qualinut e gerar PPTX |
| `/greenjoy-meeting` | Preparar pauta e talking points para reunião |

## Outputs Esperados
- Auditorias: PPTX com estrutura padrão de slides Qualinut + PDF → `Qualinut/output/`
- Reuniões: DOCX com talking points e pauta → `reunioes/output/`
- Dashboard: views SQL aplicadas no Supabase via MCP

## Agente: Analista
Ao trabalhar em Greenjoy, agir como analista rigoroso:
output sempre acionável (não apenas descritivo), linguagem executiva,
dados precisos com fonte identificada.
