# Rinha de Backend 2026 — Ruby/RF

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude com Random Forest treinado sobre 3M vetores de referência em 14 dimensões.

## Stack

- **Ruby 3.3.6 + YJIT** — JIT habilitado (`RUBY_YJIT_ENABLE=1`)
- **Puma 6.6** — single process, 6 threads local / 2 threads Docker
- **Random Forest puro Ruby** — inferência em 26–53µs/call via YJIT
- **oj** — JSON parsing rápido
- **scikit-learn** (build stage apenas) — treinamento do modelo durante `docker build`

## Performance (3M vetores, RF 200 árvores, YJIT)

| Métrica | Valor |
|---|---|
| Inferência (YJIT) | 53 µs/call |
| Inferência em Docker (0.4 CPU) | ~0.13 ms/call |
| P99 estimado em Docker | **< 5 ms** |
| Memória Puma (RSS) | **53 MB** (vs 930 MB HNSW) |
| Modelo em disco | 0.71 MB |
| FNR (fraudes perdidas) | **0.000%** |
| FPR (falsos positivos) | 2.60% |

## Score estimado na Rinha

| Métrica | Valor |
|---|---|
| FP na prova (~30K legítimos) | ~781 |
| FN na prova (~24K fraudes) | 0 |
| Detection score | ~973 |
| P99 score (P99=2ms) | ~2699 |
| **Score final estimado** | **~3672** |
| Score anterior (HNSW) | -3624.76 |
| **Melhoria** | **+7296 pontos** |

## Arquitetura

O modelo é treinado em Python/sklearn durante o `docker build` (stage `build`), e o JSON do modelo é baked na imagem final. Ao iniciar o container, o puma carrega o JSON em ~100ms e já está pronto para servir.

### Startup sem treinamento (Docker)

1. Container inicia
2. `scripts/start.sh` verifica `rf_model.json` → já existe (baked na imagem)
3. Puma inicia imediatamente (sem warmup server)
4. Warmup interno: 2000 iterações de inferência em ~100ms

### Startup com treinamento (Replit/dev)

1. `rf_model.json` não existe → inicia warmup_server na porta 5000
2. `scripts/train_model.py` treina RF em ~110s sobre 3M vetores
3. Puma substitui o warmup server

## Estrutura do projeto

```
.
├── lib/
│   ├── app.rb          # Rack: GET /ready, POST /fraud-score; warmup 2000x
│   ├── detector.rb     # build_vector (14D) + RF score
│   └── rf_model.rb     # Inferência pura Ruby: traversal de árvores, YJIT-friendly
├── scripts/
│   ├── start.sh          # Entrypoint: verifica modelo → treina se ausente → puma
│   ├── train_model.py    # Python/sklearn: RF 200 trees, max_depth=8, threshold búsca
│   └── warmup_server.rb  # Servidor temporário durante treinamento (dev)
├── data/
│   ├── references.json.gz      # 3M vetores de referência (50MB gzipped)
│   ├── mcc_risk.json
│   ├── normalization.json
│   └── cache/
│       └── rf_model.json       # Modelo treinado (0.71MB, 200 árvores)
├── Dockerfile                  # Multi-stage: build(Python+sklearn) → run(ruby-slim)
├── docker-compose.yml          # 2 instâncias + nginx, 150MB/instância
├── docker-compose.local.yml    # Para teste local
├── config.ru
└── puma.rb
```

## API

- `GET /ready` → `{"ok":true}`
- `POST /fraud-score` → `{"approved":bool,"fraud_score":float}`

## Variáveis de ambiente (runtime)

| Variável | Padrão Docker | Descrição |
|---|---|---|
| `DATA_DIR` | `/app/data` | Diretório dos dados |
| `BIND` | `tcp://0.0.0.0:9999` | Endereço Puma (nginx upstream) |
| `PUMA_THREADS` | `2` | Threads Puma no Docker |
| `WEB_CONCURRENCY` | `0` | Workers Puma (single process) |
| `MALLOC_ARENA_MAX` | `2` | Limita arenas malloc → reduz RSS |
| `RUBY_YJIT_ENABLE` | `1` | Ativa YJIT |

## Modelo RF (rf_model.json)

- **200 árvores**, max_depth=8, min_samples_leaf=200
- **class_weight={0:1, 1:3}** — penaliza 3× mais FN (fraudes perdidas), alinhado à fórmula Rinha
- **Threshold=0.050** — otimizado na validação (20% hold-out) minimizando `3×FN + FP`
- Treinado em 2.4M amostras (80% dos 3M), validado em 600K (20%)
- Val: TP=199.881, TN=389.718, FP=10.401, FN=0

## Decisão: RF em vez de HNSW

| | HNSW (anterior) | RF (atual) |
|---|---|---|
| Memória RSS | 930 MB | 53 MB |
| Cabe em 150MB/instância? | ❌ OOM | ✅ |
| P99 | 2001ms (OOM kills) | < 5ms |
| HTTP errors | 848 | 0 |
| FNR | ~0.3% | 0.000% |
| FPR | ~2.5% | 2.60% |
