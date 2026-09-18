# Arquivos legados — NÃO APLICAR

Estes `.sql` foram substituídos na revisão de Ago/2026 e estão aqui só como
histórico. **Aplicar qualquer um deles reverte correções que estão em produção.**

Isso não é teórico: durante a própria revisão, uma view definida em dois arquivos
fez uma correção ser desfeita sem aviso quando o arquivo errado foi reaplicado por
último. Foi por isso que a regra passou a ser uma definição por view, num arquivo só.

| Arquivo | Substituído por | O que mudou |
|---|---|---|
| `views_socios.sql` | `views_socios_v2.sql` | `kpi_socios_painel` ganhou CMV rolling, comparação por mesmo nº de dias e `cmv_mes_pct`. `kpi_historico_24m` deixou de emendar histórico congelado com live (junho sumia do gráfico). `kpi_canal_evolucao_6m` virou `kpi_canal_mensal` e saiu de uso |
| `view_curva_abc_fornecedor_btg.sql` | `views_produtos.sql` | `kpi_curva_abc_fornecedor` passou a ler `btg_classificado`; a versão daqui ignora a tabela de classificação e perde ~R$6,3k em 90 dias |

Para aplicar o schema correto: `python aplicar_views.py` (um nível acima).
