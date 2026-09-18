# Greenjoy Anália Franco — Dashboard: Contexto e Manutenção

**Última atualização:** 2026-08-15  
**Projeto Supabase:** `xlpcnkjqitdimcpwnkcv`  
**Projeto Lovable:** `987f37ae-c7c8-44f4-ad79-11847a51e1a6`

> **Aplicar o schema:** `python database/aplicar_views.py` roda todos os arquivos SQL na
> ordem de dependência e é seguro repetir. Cada view tem **uma única definição, num
> único arquivo** — a regra existe porque uma view definida em dois lugares causou a
> reversão silenciosa de uma correção quando o arquivo errado foi reaplicado por último.
> Ao editar uma view, edite onde ela vive e rode o aplicador inteiro.
>
> | Arquivo | Conteúdo |
> |---|---|
> | `funcoes.sql` | `hoje_br()`, `brl()` |
> | `schema_auditoria.sql` | tabelas do Qualinut |
> | `btg_classificacao.sql` + `_inferidos.sql` | de-para do extrato |
> | `btg_classificado.sql` | camada única + cobertura do mapping |
> | `views_financeiro_btg.sql` | faturamento, CMV, prime cost, DRE |
> | `views_cmv_acionavel.sql` | rolling, desvios semanais, ações |
> | `views_cmv_acompanhamento.sql` | orçamento de compra semana/mês, histórico, alertas de base |
> | `views_socios_v2.sql` | painel, ponte, canal, dias suspeitos |
> | `views_produtos.sql` | curva ABC, top produtos |
> | `views_qualinut.sql` | qualidade |
> | `rls_metas_desperdicio.sql` | políticas de acesso |
>
> **SQL avulso:** `database/sql.py` executa SQL via Management API do Supabase
> (`SUPABASE_PAT` e `SUPABASE_PROJECT_REF` no `.env`).
> `python sql.py arquivo.sql` ou `python sql.py -c "select 1"`.
> No código: `from sql import run; run("select ...", silencioso=True)`.

---

## 1. Arquitetura

```
Eclética (PDV MySQL)                     Supabase PostgreSQL
    └── sync_ecletica.py ──────────────►  ecletica_*  ──► mv_produto_dia
         (diário 00:30 BRT)                                    │
                                                               │ views KPI
BTG (extrato bancário)                                         ├──────► Dashboard
    └── Apps Script Google Drive ─────►  btg_movimentacoes      │
         (diário 06:00 BRT)                    │               │
                                    btg_classificacao (de-para) │
                                               ▼               │
                                       btg_classificado  ──────┘
                                     (camada única de CMV/DRE)

Qualinut (PDFs de auditoria)
    └── importar_auditorias.py ──────►  auditoria_qualinut{,_categoria,_itens}
         (sob demanda, a cada visita)
```

**Duas fontes automáticas sustentam o dashboard:** PDV (vendas) e BTG (todo o resto).
Everest e JAFEB saíram das telas em Ago/2026 — ver seção 2.

**Janela de dados:** últimos 24 meses (rolling) em `ecletica_pagamentos` / `ecletica_vendas`.

**Regra de ouro:** toda view de CMV, DRE, folha ou fornecedor lê `btg_classificado`,
nunca `btg_movimentacoes` cru. A camada única existe porque cada view fazia seu próprio
JOIN com regras divergentes, e 49% dos débitos caíam em "não mapeado".

---

## 2. Fontes de Dados

### Eclética (PDV)
- **Sistema:** ACOM Sistemas — MySQL local na loja
- **Acesso:** VPN ou acesso direto via `ECLETICA_HOST` (ver `.env`)
- **Script:** `Greenjoy/database/sync_ecletica.py`
- **Frequência:** diária via Agendador de Tarefas Windows (`run_sync.bat`)
- **Lookback:** 2 dias (variável `SYNC_LOOKBACK_DAYS`, padrão 2)
- **Tabelas populadas:** `ecletica_grupos`, `ecletica_produtos`, `ecletica_pagamentos`, `ecletica_vendas`

### Everest (Compras/NF) — APOSENTADO do dashboard em Ago/2026
- **Motivo:** a importação manual parou em 18/05/2026 e ficou 89 dias sem atualizar.
  Manter views vivas sobre dado congelado é pior que não ter a informação.
- **O que sobrou:** `ref_custo_produto` (custo unitário sugerido no formulário do
  estoquista, em `/desperdicio`). É o único consumo de `nf_itens` no frontend.
- **Scripts mantidos** (`importar_everest_compras.py`) para reativação futura, mas
  compras, fornecedores e CMV saem todos do BTG agora.

### Modelo JAFEB — DRE APOSENTADA do dashboard em Ago/2026
- **Motivo:** `dre_competencia` / `dre_caixa` pararam em Mai/2026. A aba `/financeiro`
  agora monta a DRE de caixa direto do BTG, que se atualiza sozinha todo dia.
- **O que continua valendo:** `jafeb_despesas_mapping` é a base do de-para de despesas
  e segue em uso por `btg_classificado`.
- **Para reativar a DRE de competência:** baixar a planilha e rodar `importar_jafeb.py`.

### BTG (Extrato Bancário — backbone de CMV, folha, impostos e despesas)
- **Fonte:** Google Sheet "Movimentações BTG" (ID: `1A0m67vjcHJYA8fsYjUZSjhheNjeJJLXvftrN9fTeOFw`) — conta `greenjoyaf@gmail.com`
- **Script:** Google Apps Script bound ao Sheet — editar em script.google.com, implantação "Teste"
- **Frequência:** diária 06:00-07:00 BRT, lookback 30 dias, upsert em `id_externo`
- **Credenciais:** PropertiesService do Apps Script (`SUPABASE_URL`, `SUPABASE_KEY`, `LOOKBACK_DAYS`)
- **Tabela alvo:** `btg_movimentacoes` — operacional, ~16.430 linhas (Mai/2023–presente)
- **Status:** operacional — 572 registros no teste inicial (Mai/2026)
- **Join pattern:** `UPPER(TRIM(COALESCE(nome_pagador_recebedor, descricao)))` é a `chave`
- **Nunca consumir direto:** usar a view `btg_classificado` (abaixo)

#### Camada de classificação — `btg_classificado`

Criada em Ago/2026 porque 49% dos débitos (R$303k só em julho) não tinham natureza:
impostos apareciam zerados, transferências da conta remunerada entravam no resultado,
e a margem operacional era exibida como 46% — impossível para food service.

**Precedência:** `btg_classificacao` (manual/inferido) → `jafeb_despesas_mapping` → `'Não classificado'`.

**Naturezas padronizadas:** `Custo` (CMV), `Despesa`, `Folha`, `Imposto`, `CAPEX`,
`Transferência`. A view normaliza o legado do JAFEB: `Despesa`+`Funcionários` vira
`Folha`, e `Impostos` (plural) vira `Imposto` — a view antiga procurava o plural, que
não existia, e por isso impostos davam zero.

| Arquivo | Papel |
|---|---|
| `database/btg_classificacao.sql` | tabela + chaves manuais (transferências, impostos, PJ) |
| `database/btg_classificacao_inferidos.sql` | 131 pessoas físicas → Folha (revisadas 15/08/2026) |
| `database/dump_classificacao.py` | regenera o arquivo acima a partir do banco |
| `database/btg_classificado.sql` | a view + `kpi_cobertura_mapping` + `kpi_mapping_pendentes` |

**Manutenção:** quando aparecer fornecedor novo, ele cai em "Não classificado".
`kpi_mapping_pendentes` lista o que falta, ordenado por R$. Classifique com um INSERT
em `btg_classificacao` e rode `python dump_classificacao.py` para versionar.
`kpi_cobertura_mapping` acusa no dashboard se passar de 5% — hoje está em 1,6%.

**Pagamentos a sócios:** `categoria_1 = 'Sócios'` marca distribuição/pró-labore, que
fica fora da DRE. Hoje só Felipe Mitunari (pagamentos de 2024-2025, nada em 2026).

---

## 3. Fórmula de Saldo Líquido

**Crítico:** o dashboard usa saldo líquido, não faturamento bruto.

```
Saldo Líquido = vlr_total + vlr_serv - vlr_desc_tot
```

Equivale ao campo **"Total Liq. Registrado"** do relatório financeiro da Eclética.  
**Não** subtrair `outras_taxas` — esse campo não compõe o líquido registrado.

Validação Mai/2026 (01–12):
- Bruto: R$215.271,21
- + Serviço: R$302,83
- − Desconto: R$5.554,88
- **= Líquido: R$210.019,16** ✓

---

## 4. Tabelas no Supabase

| Tabela | Fonte | Linhas (~) | Descrição |
|---|---|---|---|
| `ecletica_pagamentos` | Eclética | 94.298 | Pedidos/tickets — 24 meses |
| `ecletica_vendas` | Eclética | 1.369.533 | Itens vendidos — 24 meses |
| `ecletica_produtos` | Eclética | 886 | Catálogo de produtos |
| `ecletica_grupos` | Eclética | 30 | Grupos de produto |
| `nf_recebimento` | Everest | 1.015 | Notas fiscais de compra (Jan–Mai/2026) |
| `nf_itens` | Everest | 2.447 | Itens das NFs — colunas `data_lancamento` e `fornecedor` presentes a partir de Abr/2026 |
| `metas` | Manual | 2 | Metas mensais de faturamento |
| `registro_desperdicio` | Manual | — | Registro de perdas pelo estoquista — ativo |
| `kanban_tarefas` | Manual | — | Kanban da equipe (A fazer / Em andamento / Concluído / Bloqueado) |
| `resumo_mensal_historico` | Calculado | 48 | Agregado mensal Jun/2022–Mai/2026 |
| `jafeb_despesas_mapping` | JAFEB + Manual | ~1.081 | De-para: descrição → natureza / categoria_1 / categoria_2 (30 novos em Mai/2026: Simples, ICMS, FGTS, colaboradores, Royalties, transferências internas) |
| `dre_competencia` | JAFEB | ~2.900 | DRE accrual mensal — Mai/2023–Mai/2026 (55 meses × ~53 linhas) |
| `dre_caixa` | JAFEB | ~2.200 | DRE caixa mensal — mesmo período |
| `btg_movimentacoes` | BTG/Apps Script | ~16.430 | Extrato bancário BTG — backbone do CMV · sync diário 06:00 BRT |

**Colunas de `registro_desperdicio`:** `id`, `data` (default hoje), `descr_livre` (produto), `qtde`, `unidade`, `vlr_unit` (custo unitário — preenchido automaticamente do Everest), `motivo`, `registrado_por`, `observacao`, `loja` (default 'analia_franco'), `criado_em`.

**Atenção:** `flag_canc` no iFood usa `'*'` para pedidos válidos (não `NULL` nem vazio como no balcão). Sempre filtrar `flag_canc != 'C'` para excluir cancelados.

---

## 5. Views do Dashboard

### Agregado materializado
| Objeto | Descrição |
|---|---|
| `mv_produto_dia` | Dia × produto × canal, 24 meses (271k linhas no lugar de 1,37M cruas). Existe porque `kpi_curva_abc`, `kpi_top_produtos_venda` e `kpi_ifood_top_produtos` varriam `ecletica_vendas` a cada request e **estouravam o statement_timeout** — as páginas não estavam lentas, estavam quebradas. Refresh no fim de `sync_ecletica.py` (~50s) |

### Visão Geral / Financeiro
| View | Descrição |
|---|---|
| `kpi_faturamento_diario` | Faturamento líquido diário por canal (iFood / Balcão / Delivery) |
| `kpi_ticket_por_canal` | Ticket médio e participação por canal — últimos 30 dias |
| `kpi_pedidos_por_hora` | Volume e ticket por hora — últimos 30 dias |
| `kpi_semana_vs_meta` | Realizado da semana vs meta ajustada (meta_diaria_ajustada sobe quando abaixo da meta) |
| `kpi_metas_vs_realizado` | Meta vs realizado do mês |

**Nota `kpi_semana_vs_meta`:** campo `meta_diaria_ajustada` = `(meta_semana - realizado_semana) / dias_restantes_semana`. Sobe quando a semana está abaixo da meta. Não usar o campo legado de meta fixa.

### Sócios — Painel Executivo (reescrito Ago/2026)
| View | Descrição |
|---|---|
| `kpi_socios_painel` | Linha única do mês. CMV do semáforo é o **rolling 30d**, não compras-do-mês/faturamento-do-mês. Compara com o **mesmo nº de dias** do mês anterior (`var_mes_pct`) e do ano passado (`var_ano_pct`). Semáforo de meta usa a projeção, não o realizado parcial. Traz `cmv_mes_pct` (o CMV que compõe o Prime Cost) e `status_dado` da cobertura do mapping |
| `kpi_bridge_faturamento` | **O porquê da variação**: decompõe mês a mês em `efeito_volume` e `efeito_ticket`, que somam exatamente `variacao_total`. Coluna `parcial` marca o mês em curso — o frontend filtra |
| `kpi_canal_mensal` | Mix e ticket por canal com `var_share_pp` — explica o efeito ticket |
| `kpi_historico_24m` | Tendência 24 meses direto de `ecletica_pagamentos` (antes emendava `resumo_mensal_historico` com live e **perdia um mês** no meio) |
| `kpi_dia_semana` | Faturamento e ticket médios por dia da semana — 90 dias |
| `kpi_dias_suspeitos` | Dias sem venda ou com menos de 50% da mediana do mesmo dia da semana. Buraco de sync distorce CMV e projeção |

### Financeiro (BTG)
| View | Descrição |
|---|---|
| `kpi_prime_cost_mensal` | CMV + pessoal. `labor_total` = folha + encargos, **medidos** no extrato — o ×1.75 anterior duplicava encargos e marcava crítico em 5 de 8 meses. `prime_cost_pct` é o número oficial: ≤58% ótimo, ≤65% bom |
| `kpi_dre_btg_mensal` | DRE caixa: faturamento, CMV, folha, despesas_op, impostos, CAPEX, transferências, não classificado, resultado_op e margem. Transferências e CAPEX fora do resultado |
| `kpi_cobertura_mapping` | % de débitos sem classificação por mês, com status. Se >5%, o dashboard avisa em vez de mostrar número errado |
| `kpi_mapping_pendentes` | Fila de trabalho: o que classificar, ordenado por R$ |
| `kpi_faturamento_mes` | Base comum de faturamento mensal (líquido, pedidos, ticket, dias operados) |

### Compras / CMV (reescrito Ago/2026)
| View | Descrição |
|---|---|
| `kpi_cmv_mensal` | CMV mensal via `btg_classificado` WHERE natureza='Custo' |
| `kpi_cmv_rolling` | **Número oficial do CMV**: janelas móveis de 30 e 90 dias, por dia. Imune ao calendário de compra. Série termina no último dia com venda registrada |
| `kpi_cmv_categoria_semanal` | Gasto por categoria por semana vs média das 8 anteriores, com `situacao` (acima / muito_acima) e flag `parcial` |
| `kpi_cmv_fornecedor_semanal` | O mesmo desvio, por fornecedor |
| `kpi_cmv_acoes` | **O card "o que atacar"**: junta os desvios da última semana fechada com o texto da ação pronto. Fornecedor não repete evento já reportado como categoria |
| `kpi_cmv_por_mil` | Custo por R$1.000 de venda por categoria — normaliza sazonalidade |
| `kpi_cmv_semanal`, `kpi_cmv_proxy`, `kpi_compras_mensal` | Legado, ainda usados por `/bonus-gerente` |

### Acompanhamento semana/mês (Set/2026)
Nasceu de uma lacuna: o dashboard sabia dizer **quanto** o CMV está, mas não **quanto ainda
cabe comprar**. Sem orçamento de compra, o estouro só aparecia no fechamento do mês.

| View | Descrição |
|---|---|
| `kpi_meta_cmv` | Meta de CMV por mês com fallback: meta do mês → última meta cadastrada → `premio_config.estoq_cmv_pct_1` → 31. A tabela `metas` é manual e vive desatualizada (parou em Ago/2026); sem fallback a tela nascia vazia todo mês |
| `kpi_compras_semana` | Semana ISO com faturamento, compras, **orçamento** (venda × meta), desvio da semana e acumulado do mês. O semáforo lê `cmv_4s_pct` (janela de 4 semanas), não a semana crua — semana isolada oscila mais de 10 p.p. por calendário de compra |
| `kpi_compras_mes_acompanhamento` | Mês em curso: projeção de venda por run-rate sobre dia aberto, **saldo de orçamento** (quanto ainda cabe comprar) e `ritmo_diario_permitido` vs `ritmo_diario_atual`. Traz `confiavel` |
| `kpi_cmv_historico_mensal` | 24 meses com médias móveis de 3 e 6 meses, desvio da meta em p.p., YoY e o excesso de compra em R$ |
| `kpi_cmv_alertas` | 7 checagens de base, cada uma com evidência e ação: cobertura do de-para, fila de classificação, frescor de PDV e BTG, dias suspeitos, semana sem compra, nível do CMV e royalty dentro do custo |

**Armadilhas resolvidas nestas views — não desfazer:**
- **O acumulado do mês é apurado no dia, não somando semanas.** A semana ISO pertence ao mês
  da segunda-feira; somar semanas jogava 1 a 6 de setembro dentro de agosto e fazia a aba
  semanal dizer "acima do orçamento" enquanto a mensal dizia "abaixo" — R$71,7 mil de
  diferença. Daí `mes_acum`, `compras_mes_ate_semana` e `desvio_acum_mes`.
- **`confiavel` tem piso em Mai/2025** + densidade de débito (≥200) + venda em quase todo dia
  aberto (tolerância de 4 dias, porque `loja_dias_fechados` não tem os feriados de 2025).
  Jan e Fev/2025 têm R$19k de venda contra R$200k de compra; Mar e Abr dão 57,5% e 41,4% —
  PDV entrando no ar. Ago e Set/2025 caem pela densidade (93 e 14 débitos, CMV de 8,4% e 1,0%).
  As médias móveis só calculam sobre janela cheia e contígua de meses confiáveis.
- **Venda e compra são projetadas com réguas diferentes, de propósito.** Venda: run-rate por
  dia **decorrido aberto**. Ponderar por `premio_peso_dia_semana` não ganha nada (4,36% contra
  4,20% de erro no dia 17) e a tabela de pesos está desatualizada — segunda mede 0,73 e a
  tabela diz 0,50. Dividir por **dia com venda** é pior ainda (4,91%): dia zerado por falha de
  sync sai do denominador e infla a projeção — em mai/2026 dava R$621k contra R$535k
  realizados. Compra: o que já saiu é fato, e a venda que falta entra ao CMV de
  `kpi_cmv_rolling`. Se as duas usassem a mesma razão, `cmv_projetado_pct` sairia idêntico ao
  realizado e o card não diria nada. O rolling entra com **banda de 20% a 50%** — em 16% dos
  dias da série ele está fora dela (cauda do buraco do extrato de 2025, chegou a 0%), e sem a
  banda uma parada do sync do BTG acenderia o semáforo como `otimo` justo quando o dado quebrou.
- **O alerta de royalty filtra `tipo ILIKE 'D%'`.** Sem isso pegava crédito (estorno) da
  franqueadora e mandava corrigir uma regra que está certa.
- **A severidade da fila de classificação olha os últimos 60 dias.** O total carrega resíduo
  de 12 meses e nunca sairia de crítico.

### Curva ABC
| View | Descrição |
|---|---|
| `kpi_curva_abc` | Curva ABC de produtos por receita — 90 dias, sobre `mv_produto_dia` |
| `kpi_curva_abc_cmv` | Curva ABC de categorias por custo |
| `kpi_curva_abc_fornecedor` | Curva ABC de fornecedores por custo — sobre `btg_classificado` |

### Curva ABC
| View | Descrição |
|---|---|
| `kpi_curva_abc` | Curva ABC de produtos por receita — últimos 90 dias |
| `kpi_curva_abc_cmv` | Curva ABC de categorias por custo |
| `kpi_curva_abc_fornecedor` | Curva ABC de fornecedores por custo |

### Qualidade (Qualinut)
| View | Descrição |
|---|---|
| `kpi_qualinut_status` | Linha única: data última auditoria, score%, score/score_max, var vs anterior, evolução total, dias desde última, pontos para meta, itens crônicos/abertos, status RAG |
| `kpi_qualinut_evolucao` | Série histórica de auditorias: data, rótulo, pct, score, var_pp, gap_pp, média móvel 3 auditorias, faixa (verde/amarelo/vermelho) |
| `kpi_qualinut_categoria` | Score por categoria em cada auditoria: obtido, máximo, pct, nao_conformes, pontos_perdidos |
| `kpi_qualinut_gap` | Análise de Pareto de perdas por categoria: pontos_perdidos, itens_nc, pct das perdas, pct_acumulado |
| `kpi_qualinut_reincidencia` | Itens com NC recorrente: vezes_nc, taxa_nc_pct, situacao, acao, responsavel, nc_na_ultima |
| `kpi_qualinut_simulador` | Simulador de projeção: impacto de fechar cada NC — pct_projetado, atinge_meta |

### Desperdício
| View | Descrição |
|---|---|
| `kpi_desperdicio_mensal` | Resumo mensal: qtde_registros, dias_com_registro, total_valor, media_dia |
| `kpi_desperdicio_por_motivo` | Ocorrências e R$ por motivo + % do total (window function) |
| `kpi_desperdicio_top_itens` | Top 20 produtos por valor desperdiçado acumulado |
| `ref_custo_produto` | Custo unitário mais recente por produto (últimos 180 dias, do Everest) — usado para auto-preencher vlr_unit no formulário do estoquista |

### iFood
| View | Descrição |
|---|---|
| `kpi_ifood_mensal` | Série mensal iFood: pedidos, faturamento líquido, ticket, descontos |
| `kpi_ifood_vs_balcao` | iFood vs Balcão mensal + % participação iFood |
| `kpi_ifood_descontos_mensal` | % pedidos com desconto, total descontado, desconto médio por mês |
| `kpi_ifood_descontos_faixa` | Distribuição por faixa de desconto (últimos 90 dias) |
| `kpi_ifood_retirada_vs_entrega` | Retirada vs entrega: volume e ticket por mês |
| `kpi_ifood_cancelamentos_mensal` | Taxa de cancelamento mensal iFood |
| `kpi_ifood_hora` | Pedidos e ticket por hora do dia (últimos 90 dias) |
| `kpi_ifood_dia_semana` | Pedidos e ticket por dia da semana (últimos 90 dias) |
| `kpi_ifood_top_produtos` | Top 30 produtos mais vendidos no iFood (últimos 90 dias) |

---

## 6. Automações (Task Scheduler Windows)

| Tarefa | Horário | Script | Task Name |
|---|---|---|---|
| Sync Eclética → Supabase | 00:30 BRT | `run_sync.bat` | `GreenjoySync` |
| Relatório diário por email | 01:00 BRT | `run_relatorio.bat` | `GreenjoyRelatorio` |

**Destinatários do relatório:** rafa.dallana@gmail.com, brunobjusto@gmail.com, felipemitunari@gmail.com  
**Remetente:** rafa.dallana@gmail.com (Gmail App Password em `.env`)

**Recriar as tarefas** (PowerShell como Administrador):
```powershell
# Sync
$bat = "C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\database\run_sync.bat"
$action   = New-ScheduledTaskAction -Execute $bat
$trigger  = New-ScheduledTaskTrigger -Daily -At "00:30"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName "GreenjoySync" -Action $action -Trigger $trigger -Settings $settings -Force

# Relatório
$bat = "C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\database\run_relatorio.bat"
$action   = New-ScheduledTaskAction -Execute $bat
$trigger  = New-ScheduledTaskTrigger -Daily -At "01:00"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName "GreenjoyRelatorio" -Action $action -Trigger $trigger -Settings $settings -Force
```

**Nota:** PC precisa estar ligado. `StartWhenAvailable` garante que roda assim que o PC ligar, caso estivesse desligado no horário agendado. Se o PC ficar desligado por mais de 24h, os relatórios dos dias perdidos não são recuperados automaticamente — enviar manualmente com a data específica.

> **TODO (fase futura):** Migrar sync e relatório para servidor/VPS sempre ligado com acesso à rede da loja, eliminando dependência do PC local.

### 6.1 Sync diário Eclética (automático)
Log em `Greenjoy/database/sync_ecletica.log`.

**Se o sync falhar — rodar manualmente:**
```powershell
cd C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\database
python sync_ecletica.py
```

**Re-sincronizar mais dias:**
```powershell
$env:SYNC_LOOKBACK_DAYS = "30"
python sync_ecletica.py
```

### 6.2 Importar novo Excel do Everest (corrente — 2-3×/semana)
Quando Rafael colocar novo arquivo em `Greenjoy/Everest - compras/`:
```powershell
cd C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\database
python importar_everest_compras.py
```
O script processa **todos** os `.xlsx` da pasta. Para cada arquivo, detecta os meses cobertos, apaga os itens daqueles meses e reinsere — sem duplicatas. Também faz upsert em `nf_recebimento`.

**Para o import histórico** (arquivo legado em `dados/`):
```powershell
python importar_everest.py
```

### 6.3 Importar/atualizar DRE JAFEB
Quando a planilha JAFEB for atualizada (mensal):
1. Baixar do Google Drive → salvar em `Greenjoy/docs/Modelo JAFEB.xlsx`
2. Executar:
```powershell
cd C:\Users\Usuario\OneDrive\GiRafa_Code\Greenjoy\database
python importar_jafeb.py
```
O script é idempotente — usa ON CONFLICT DO UPDATE nas três tabelas.

### 6.4 Sync BTG → Supabase (Google Apps Script — operacional)

**Onde editar:** script.google.com → conta `greenjoyaf@gmail.com` → Script bound ao Google Sheet "Movimentações BTG"  
**Trigger:** diário 06:00-07:00 BRT, implantação "Teste"  
**Lookback:** 30 dias (configurável via Properties)  
**Status:** operacional desde Mai/2026 — 572 registros no teste inicial

**Alterar configurações (Properties):**
1. No editor Apps Script → Projeto → Propriedades do script
2. Chaves: `SUPABASE_URL`, `SUPABASE_KEY` (service_role key ~230 chars, copiar pelo botão no Supabase), `LOOKBACK_DAYS`

**Se o sync falhar — forçar manualmente:**
No editor Apps Script, selecionar função `syncBtgToSupabase` e clicar em Executar.

**Scripts Python alternativos (não são o método ativo):**
- `database/sync_btg.py` — chama API BTG diretamente (requer refresh token via `setup_btg_auth.py`)
- `database/importar_btg_gsheet.py` — import de CSV histórico exportado do Drive (uso único)

### 6.5 Atualizar metas mensais
No Supabase SQL Editor:
```sql
INSERT INTO metas (mes, tipo, valor_meta)
VALUES ('2026-06-01', 'faturamento', 550000)
ON CONFLICT DO NOTHING;
```

---

## 7. Gestão de Disco Supabase

**Situação atual:** disco em 4 GB (upgrade de 2→4 GB em Mai/2026 após estouro).  
**Política:** manter apenas últimos 24 meses em `ecletica_pagamentos` e `ecletica_vendas`.

**Quando o banco se aproximar do limite (>85%):**

1. Verificar tamanho:
```sql
SELECT
  schemaname, tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS tamanho
FROM pg_tables WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

2. Atualizar resumo histórico (roda antes de deletar):
```sql
INSERT INTO resumo_mensal_historico
SELECT
    DATE_TRUNC('month', data_hora_fecha AT TIME ZONE 'America/Sao_Paulo')::DATE AS mes,
    COUNT(*) FILTER (WHERE flag_canc != 'C') AS pedidos_total,
    -- (usar query completa da criação original)
    ...
ON CONFLICT (mes) DO UPDATE SET pedidos_total = EXCLUDED.pedidos_total, ...;
```

3. Deletar dados antigos:
```sql
DELETE FROM ecletica_vendas    WHERE data_hora       < NOW() - INTERVAL '24 months';
DELETE FROM ecletica_pagamentos WHERE data_hora_fecha < NOW() - INTERVAL '24 months';
```

4. Forçar VACUUM para liberar espaço físico:
```sql
VACUUM (ANALYZE) ecletica_vendas;
VACUUM (ANALYZE) ecletica_pagamentos;
```

---

## 8. Variáveis de Ambiente (.env)

Arquivo em `Greenjoy/database/.env`:

```
SUPABASE_URL=https://xlpcnkjqitdimcpwnkcv.supabase.co
SUPABASE_SERVICE_KEY=<service_role_key>

ECLETICA_HOST=<ip_ou_hostname>
ECLETICA_PORT=3306
ECLETICA_USER=<usuario>
ECLETICA_PASSWORD=<senha>
ECLETICA_DB=<nome_banco>

SYNC_LOOKBACK_DAYS=2
```

---

## 9. Segurança — RLS

**Resolvido em Ago/2026** (`database/rls_metas_desperdicio.sql`).

Antes, `metas` e `registro_desperdicio` estavam sem RLS e com escrita liberada para
`anon` — e a chave anon vai no bundle do frontend. Qualquer pessoa com ela podia
alterar a meta de faturamento que o painel dos sócios exibe.

| Tabela | anon | authenticated | Por quê |
|---|---|---|---|
| `metas` | SELECT | SELECT, INSERT, UPDATE | `/metas` fica atrás do AuthGate |
| `registro_desperdicio` | SELECT, INSERT, DELETE | idem | `/desperdicio` roda **sem login** — o estoquista registra pelo celular |

`TRUNCATE` foi revogado de `anon` nas duas: RLS não filtra truncate, só grant resolve.

**Atenção ao mexer:** `/desperdicio`, `/bonus` e `/bonus-gerente` estão fora do
`AuthGate` (ver `__root.tsx:113`). Restringir `registro_desperdicio` a `authenticated`
quebra a página do estoquista.

As tabelas de auditoria (`auditoria_qualinut*`) nascem com RLS e policy só de SELECT.

---

## 10. Rotas Lovable

| Rota | Quem usa | Descrição |
|---|---|---|
| `/` | Gestores / Sócios | Dashboard de vendas — faturamento, meta, ticket, canal |
| `/socios` | Sócios | Painel executivo + bloco "Por que mudou" (volume × ticket × mix), 24 meses, canal. Avisa se houve dia sem venda ou cobertura de dado ruim |
| `/semana` | Operação | Realizado da semana vs meta ajustada — **fora do menu** desde Ago/2026 |
| `/ifood` | Gestores | KPIs iFood — **fora do menu** desde Ago/2026 |
| `/compras` | Gestores | CMV & Compras — 5 sub-abas: **Semana & mês** (orçamento de compra, saldo, ritmo), Onde atacar, Histórico, Estoque e Saúde da base |
| `/curva-abc` | Gestores | Curva ABC de produtos — **fora do menu** desde Ago/2026 |
| `/analise-desperdicio` | Gestores | Análise de desperdício — 4 KPIs, gráfico 6m, por motivo, top itens, registros recentes |
| `/desperdicio` | Estoquista | Standalone mobile — registrar perdas (sem nav, QR code em `docs/qr_desperdicio.png`) |
| `/qualidade` | Gestores / Sócios | Qualinut audit KPI — score%, evolução histórica, análise de Pareto por categoria, reincidências, simulador de projeção |
| `/financeiro` | Sócios / C-Level | DRE BTG — CMV%, Labor, Prime Cost, resultado_op, EBITDA · migrado de JAFEB→BTG em Ago/2026 |
| `/metas` | Gestores | Metas de vendas e CMV — **fora do menu** desde Ago/2026 |
| `/kanban` | Equipe | Kanban de tarefas — **fora do menu**, base parada desde Mai/2026 |
| `/chat` | Todos | Assistente IA |

**Rotas fora do menu:** continuam existindo e acessíveis por URL. Saíram porque
duplicavam informação que passou a viver em `/socios` e `/compras`, ou porque a base
parou de ser alimentada. Nenhum arquivo foi deletado — para trazer de volta, basta
reinserir em `items` no `app-sidebar.tsx`.

**Aba `/compras` (Set/2026 — sub-abas):**
- **Semana & mês** (padrão) — orçamento de compra do mês, saldo, quanto pode comprar por dia,
  barra de orçamento consumido x calendário, série de 13 semanas fechadas e tabela semana a semana
- **Onde atacar** — o conteúdo anterior: rolling 30/90d, ações da semana, categorias, ABC de fornecedores
- **Histórico** — 24 meses com médias móveis, YoY e excesso de compra em R$; mês com base
  incompleta fica fora do gráfico e marcado na tabela
- **Estoque** — contagens do app Greenjoy Stock, que vive em **outro projeto Supabase**
  (`mjhjwjpmuqsxwkrvvedp`, cliente em `src/integrations/supabase/stock.ts`). Não há JOIN possível.
  A aba lista explicitamente o que falta para o estoque fechar CMV: nenhum dos 268 itens tem
  `estoque_minimo` nem custo unitário, e a série de contagem começou em 14/09/2026
- **Saúde da base** — `kpi_cmv_alertas` + fila de classificação

**Meta de CMV — duas réguas ainda convivem:** `/compras` usa meta/meta+3 de `kpi_meta_cmv`
(hoje 30% e 33%); `kpi_cmv_rolling.semaforo_cmv` usa 33/37 fixos e alimenta `kpi_socios_painel`.
A 34% um diz "crítico" e o outro "bom". Unificar é decisão de negócio, não de código.

**Aba `/financeiro` (Ago/2026 — 100% BTG):**
- Seletor de mês
- Cards: Receita líquida, Prime Cost (semáforo), Resultado operacional (semáforo), Carga tributária
- DRE de caixa do mês com % da receita e variação vs mês anterior
- Blocos separados para CAPEX, transferências internas e não classificado — o que fica fora do resultado
- Gráfico 12m: CMV% + Pessoal% em barras, Prime Cost% em linha, referências 58% e 65%
- Gráfico 12m: Receita vs Resultado operacional + margem
- Avisa no topo se a cobertura do mapping do mês estiver ruim

---

## 11. Projeto Local (greenjoyaf-pulse)

**Localização:** `GiRafa_Code/greenjoyaf-pulse/` (note: o nome da pasta tem 'a' — `greenjoyaf`, não `greenjoyf`)  
**Stack:** React + TypeScript + Vite + TanStack Router (SSR via `@tanstack/react-start`) + Supabase + shadcn/ui  
**Deploy:** Cloudflare Workers via `wrangler.jsonc`

**⚠️ routeTree.gen.ts — gerado automaticamente pelo plugin Vite**
- O arquivo `src/routeTree.gen.ts` é regenerado a cada `vite dev` no Windows
- Novas rotas criadas sem passar pelo dev server precisam ser inseridas manualmente no gen file
- Rotas presentes (Ago/2026): `/`, `/socios`, `/compras`, `/financeiro`, `/qualidade`, `/analise-desperdicio`, `/bonus`, `/bonus-gerente`, `/bonus-gestao`, `/chat`, `/curva-abc`, `/desperdicio`, `/ifood`, `/intranet-gestao`, `/kanban`, `/metas`, `/semana`, `/api/chat`
- Para adicionar nova rota: (1) criar `src/routes/minha-rota.tsx` com `createFileRoute("/minha-rota")`, (2) rodar `npm run dev` no Windows para regenerar o gen file, OU adicionar manualmente em todos os blocos do gen file

**Menu sidebar (app-sidebar.tsx) — abas visíveis:**
| Aba | Rota | Status |
|---|---|---|
| Dashboard Vendas | `/` | ativo |
| Sócios | `/socios` | ativo |
| CMV & Compras | `/compras` | ativo |
| Financeiro | `/financeiro` | ativo |
| Qualidade | `/qualidade` | ativo |
| Desperdício Insumos | `/analise-desperdicio` | ativo |

Rotas acessíveis por URL mas fora do menu: `/semana`, `/ifood`, `/curva-abc`, `/metas`, `/kanban`, `/chat`, `/bonus`, `/bonus-gerente`, `/bonus-gestao`, `/intranet-gestao`.  
Standalone (sem auth/nav): `/desperdicio` (formulário mobile estoquista).

---

## 12. Arquivos de Referência em `docs/`



| Arquivo | Descrição |
|---|---|
| `kpi_gap_socios.xlsx` | Gap analysis de 24 KPIs: o que temos, o que falta, prioridade — gerado por `gerar_kpi_gap.py` |
| `lovable_prompts.md` | Prompts prontos para atualizar o Lovable (Sócios, Kanban, Desperdício) |
| `qr_desperdicio.png` | QR code para a rota `/desperdicio` — imprimir e colar no estoque |
| `Greenjoy_Dashboard_Plano.md` | Roadmap 90 dias do dashboard |
| `Analise KPIs Gestão.md` | Benchmarks e KPIs para fast casual — Prime Cost, Labor, EBITDA, NPS etc. com fontes NRA/ABRASEL |
| `integracao_pagseguro_btg.md` | Plano de integração PagSeguro + BTG + Stone — conciliação financeira (pendente credenciais Stone/PagSeguro) |
| `Modelo JAFEB.xlsx` | Fonte da DRE histórica + de-para de despesas — importar via `importar_jafeb.py` quando atualizar |

---

## 13. Contatos e Acessos

| Sistema | Onde acessar |
|---|---|
| Supabase Dashboard | https://supabase.com → projeto `xlpcnkjqitdimcpwnkcv` |
| Lovable Dashboard | https://lovable.dev → projeto `987f37ae-c7c8-44f4-ad79-11847a51e1a6` |
| Lovable URL pública | https://greenjoyaf-pulse.lovable.app |
| ACOM Sistemas | https://acomsistemas.com.br |
| Eclética (homologação) | https://homologacao.acomsistemas.com.br |
