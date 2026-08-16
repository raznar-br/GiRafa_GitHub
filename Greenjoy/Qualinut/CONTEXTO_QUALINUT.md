# Contexto Qualinut — parser, base e pauta

Arquitetura e armadilhas da trilha de auditoria de qualidade, de PDF a pauta de reunião.
Ler antes de mexer no parser, nas views `kpi_qualinut_*` ou na aba `/qualidade`.

Última atualização: 16/08/2026.

## O fluxo

```
Auditorias/*.pdf  (SafetyCulture, exportado pela Qualinut)
    ↓  importar_auditorias.py          DRY_RUN=1 confere sem gravar
auditoria_qualinut            score e % do cabeçalho do PDF
auditoria_qualinut_categoria  subtotais por categoria, impressos no PDF
auditoria_qualinut_itens      resposta item a item
    ↓  database/views_qualinut.sql     python aplicar_views.py views_qualinut.sql
kpi_qualinut_*                curva, gap, reincidência, simulador, movimento, pauta
    ↓
/qualidade no greenjoyaf-pulse
```

A cada visita da Qualinut: baixar o PDF, salvar em `Auditorias/` como `Analia-Franco-N.pdf`
(o N não importa — a data sai de dentro do PDF), rodar `DRY_RUN=1 python importar_auditorias.py`,
conferir a tabela de saída e rodar sem DRY_RUN.

## O catálogo é a espinha dorsal

`Critério de notas Greenjoy - 2026.pdf` é o catálogo canônico: 38 perguntas, 150 pontos.
Toda auditoria é lida procurando **as perguntas do catálogo dentro do texto do relatório**
e capturando a resposta que vem logo depois. Se o catálogo quebra, tudo quebra em silêncio —
as auditorias continuam importando, só que com itens faltando.

Conferência rápida depois de qualquer mudança no parser:

```bash
python -c "import importar_auditorias as ia; c=ia.ler_criterio(); print(len(c), sum(x['pontos'] for x in c))"
# tem que dar: 38 150
```

O checklist v.4 (a partir de 11/03/26) casa 38/38 itens. O v.3 (até 21/02/26) casa 35 —
ele tem perguntas que não existem no critério v.4, e é normal.

## Armadilhas do PDF, todas já pagas

O SafetyCulture exporta de um jeito diferente a cada vez. As cinco que já custaram caro:

1. **Idioma varia.** O relatório de 22/07/26 veio em português (`22 jul. 2026`, `Resultado`,
   `Concluído`) e os outros em inglês (`3 Aug 2026`, `Score`). O regex de data aceita os dois,
   com mês em qualquer caixa e ponto opcional.

2. **"Não Verificado" precisa ser reconhecido.** Não é conforme nem não conforme — é NA
   (o auditor não avaliou, e o item sai do denominador da categoria). Sem tratar, a busca
   pela resposta seguia adiante e capturava o **"Conforme" do item seguinte**, marcando como
   aprovado algo que ninguém olhou.

3. **Pergunta quebrada entre páginas vem com a resposta enfiada no meio.** Literalmente:
   `contaminacao cruzada evitada atraves de procedimento ou CONFORME separacao fisica...`.
   A frase inteira nunca casa. Por isso o parser tenta prefixos decrescentes de 8 até 4
   palavras (mínimo 30 caracteres, para não casar frase curta em lugar errado).

4. **O cabeçalho de pontuação da seção gruda na primeira pergunta da categoria.** A chave
   nascia como `60 0 ausencia de produtos vencidos...` e nunca casava — foi assim que o item
   de 12 pontos, o mais pesado do checklist, sumiu de todas as auditorias de uma vez.

5. **"Etiqueta primária ou secundária?" não é item conforme/não conforme.** É um campo de
   seleção que só aparece quando a pergunta anterior reprova, e a resposta é "Primária" ou
   "Secundária". Ele fica fora do catálogo de propósito; quando entrava, contava como um
   não conforme de 10 pontos que não existe.

**Delta residual de −2 pontos é esperado** na v.4: a soma dos itens casados fica 2 pontos
abaixo do score oficial porque o relatório tem pontos que o critério v.4 não descreve.
A curva usa sempre o **score oficial do cabeçalho**, nunca a soma dos itens. Os itens servem
para Pareto, reincidência e simulador.

## Categoria não é derivada dos itens

Os subtotais por categoria vêm impressos no próprio relatório (`PONTOS CRÍTICOS` seguido de
`23 / 59 (38.98%)`) e é isso que a gente grava. Derivar somando os itens casados subestima o
máximo — Pontos Críticos aparecia como 22/46 em vez de 23/59. A conferência `soma_cat == score`
roda a cada import e sai como `OK` na tabela de saída.

## A régua da pauta

`kpi_qualinut_pauta` responde "o que levar para a reunião de segunda". Duas camadas, porque
nenhuma sozinha acerta a ordem:

- **Risco sanitário** (`qualinut_acoes.critico_sanitario`) — o achado que pode adoecer cliente
  ou render autuação no dia. Entra na semana **independente de pontuação**. A régua de pontos
  do checklist mede perda de nota, não gravidade: sem o override, "peça de suíno descongelando
  sobre a bancada" ficava em décimo lugar por valer 5 pontos e ter reprovado uma vez em oito.
- **Pontos esperados** — peso do item × taxa histórica de reprovação, mais metade do peso se
  regrediu desde a última visita. É o que a loja deve perder de novo se nada mudar, com
  prioridade para o sinal fresco.

Ordenar por cronicidade (`reprovou em 100% das visitas`) parece certo e não é: joga
"produtos vencidos" — 12 pontos, o item mais pesado — para o fim da fila só porque ele passou
em uma das doze visitas, enquanto um item de 4 pontos abre a reunião.

Dentro da semana a pauta separa **rotina de turno** de **tarefa com prazo**. Uma se cobra todo
dia e disputa a atenção da equipe; a outra tem dono único, data, e fecha ou não fecha. Tratar
"comprar dispenser" e "etiquetar tudo" com a mesma linguagem faz nenhuma das duas andar.

## A regra do "não reavaliado"

Item que reprovou numa visita e voltou como "não verificado" na seguinte **continua na pauta**
como `nao_reavaliado`, até prova em contrário. Sem essa regra ele simplesmente desaparece:
foi o que aconteceu com a documentação legal, reprovada em 22/07 com PGR, PCMSO e ASO vencidos
e PMOC sem preenchimento desde abril, e "não verificada" em 03/08.

Dois motivos para manter: some do radar o item de maior risco de multa, e cria o incentivo
perverso de torcer para o auditor não olhar.

Pelo mesmo motivo `kpi_qualinut_movimento` conta os que trocaram de/para NA. Sem eles o placar
não fecha: entre 22/07 e 03/08 os itens avaliados nas duas visitas explicam 3 pontos de queda,
mas a nota caiu 8 — a diferença estava em dois itens que eram "não verificado" e viraram
reprovação.

## Parecer do auditor de segurança de alimentos (Ago/2026)

Validação externa da pauta contra as evidências dos quatro relatórios mais recentes. O que
ficou incorporado e vale lembrar:

- **Severidade não é frequência.** Descongelamento reprovou 1 vez em 8 e é o achado mais
  perigoso da última visita (RDC 216: degelo sob refrigeração ≤5 °C, micro-ondas ou cocção).
- **Formulários de qualidade são risco sanitário**, apesar de valerem 4 pontos: são o único
  registro que prova controle de temperatura. Sem eles a próxima pista a 15,8 °C só aparece
  na visita seguinte, e é o primeiro documento que a vigilância pede.
- **Ação estava atacando sintoma.** A ação cadastrada para equipamentos mandava agendar
  preventiva de coifa e dutos — que não aparece em nenhuma evidência das auditorias. Era falso
  casamento do padrão de texto. Foi trocada por lista de OS com prazo e foto do reparo.
- **Donos errados.** Descongelamento é decisão de D-1, na puxada do freezer: dono é o chefe de
  turno, não o cozinheiro que executa. Higiene do estoque é layout e acesso, do líder de setor,
  não do ajudante. A validade errada no cadastro do sistema (suco a 12h em vez de 6h) é do
  gerente, não do operador que etiqueta.
- **Leitura da oscilação:** a curva serrilhada (24,6 → 55,1 → 36,4 → 63,8 → 58,0) é assinatura
  de melhoria por mutirão, não por rotina. A loja sabe fechar item e não sabe sustentar —
  5 fechados e 4 regredidos na mesma janela confirmam que a capacidade existe e o mecanismo de
  manutenção não. O que cobrar: autoauditoria interna com o mesmo checklist na semana sem
  Qualinut, lista de reincidentes com OS e prazo, e responsável nomeado por turno.
- **Distorção que continua de pé:** o denominador muda entre visitas (v.3 tem 35 itens, v.4
  tem 38, e cada visita tem 3 a 7 itens NA). "8/8" e "7/7" não são 100% de reprovação — são
  itens avaliados poucas vezes. Comparar com "4/12" é comparar bases diferentes.

## Onde estamos (03/08/2026)

12 auditorias importadas em 2026:

| Data | Nota | Data | Nota |
|---|---|---|---|
| 09/01 | 24,6% | 06/05 | 54,1% |
| 24/01 | 36,2% | 21/06 | 46,3% |
| 05/02 | 46,2% | 08/07 | 63,8% |
| 21/02 | 55,1% | 22/07 | 63,8% |
| 11/03 | 53,9% | 03/08 | **57,97%** |
| 28/03 | 52,6% | | |
| 21/04 | 36,4% | | |

Meta 70%. Faltam 17 pontos. 12 itens abertos valendo 61 pontos, 8 deles na semana (48 pontos),
7 marcados como risco sanitário.

Crônicos (reprovam em toda visita avaliada): produtos identificados 12/12, caixas e potes 11/11,
equipamentos 8/8, formulários 7/7.

## Pendências conhecidas

- `analise_qualinut_2026.md` está congelado em Mai/26 e serve só como referência de conferência
  do parser. Não é fonte de verdade.
- `gerar_ppt_qualinut.py` ainda monta o deck a partir do JSON antigo; não foi revisado nesta
  rodada.
- Recebimento e higienização de frutas e verduras vêm como "não verificado" há duas visitas
  seguidas — não é lacuna do parser, é o auditor que não pegou o processo acontecendo. Se
  reprovarem, entram na pauta automaticamente.
