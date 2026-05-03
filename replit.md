# Rinha de Backend 2026 — Ruby/RF

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude com Random Forest treinado sobre 3M vetores de referência em 17 dimensões.

## Stack

- **Ruby 3.3.6 + YJIT** — JIT habilitado via `RUBYOPT=--yjit`
- **Puma 6.6** — single process, 2 threads
- **Random Forest puro Ruby** — inferência em ~40µs/call com YJIT
- **oj** — JSON parsing rápido
- **scikit-learn + FAISS** (build stage apenas) — treinamento durante `docker build`

## Performance (3M vetores, RF 200 árvores 17D, YJIT)

| Métrica | Valor |
|---|---|
| Inferência (YJIT, local) | 40 µs/call |
| Throughput single-conn (local) | 3440 req/s |
| Throughput 2-conn concurrent (local) | 3497 req/s |
| Throughput estimado Docker (0.4 CPU × 2) | ~2800 req/s (vs alvo 900) |
| P99 estimado em Docker | < 2 ms |
| Memória Puma (RSS) | ~52 MB |
| Modelo | 200 árvores, depth 10, min_leaf 100, 0.28 MB |
| FNR | 0.000% |
| FPR (BallTree local) | ~2.55% |

## Score estimado (Teste 4+)

| Componente | Valor |
|---|---|
| P99 esperado | < 2ms |
| p99Score | +2000 |
| FP estimados (~30K legítimos × 2.55%) | ~765 |
| FN estimados | 0 |
| Detection score | ~980 |
| **Score final estimado** | **~2980** |

## Features do modelo (17D)

14 features base + 3 derivadas que melhoram separação FP vs fraude:

| # | Feature | Importância | FP-média | Fraude-média |
|---|---|---|---|---|
| 0 | amount_norm | 18.24% | 0.172 | 0.577 |
| 1 | inst_norm | 16.16% | 0.408 | 0.736 |
| 2 | amount_ratio (÷cust_avg) | 29.66% | 0.597 | 0.977 |
| 3 | hour | 0.72% | — | — |
| 4 | wday | 0.01% | — | — |
| 5 | mins_since_last | 0.78% | -0.154 | -0.203 |
| 6 | km_from_last | 0.12% | -0.064 | 0.252 |
| 7 | km_from_home | 11.60% | 0.208 | 0.584 |
| 8 | tx_count_24h | 8.47% | 0.371 | 0.685 |
| 9 | is_online | 0.00% | — | — |
| 10 | card_present | 0.00% | — | — |
| 11 | unknown_merchant | 2.09% | 0.494 | 0.975 |
| 12 | mcc_risk | 6.96% | 0.440 | 0.783 |
| 13 | merch_avg_norm | 1.17% | 0.017 | 0.007 |
| **14** | **amount ÷ merch_avg (÷100)** | **3.93%** | **0.121** | **0.788** |
| **15** | **(1−card_present) × amount** | **0.04%** | 0.098 | 0.469 |
| **16** | **travel speed (km/h ÷ 900)** | **0.07%** | **0.213** | **0.765** |

Feature 14 (`amt_merch_ratio`) é o mais discriminante dos novos: **6.5× separação** entre FP e fraude. Com FAISS (Docker), labels mais precisas permitirão ao RF explorar essa separação.

## Estrutura do projeto

```
.
├── lib/
│   ├── app.rb          # Rack: GET /ready, POST /fraud-score; warmup 2000x
│   ├── detector.rb     # build_vector (17D) + RF score + threshold
│   └── rf_model.rb     # Inferência pura Ruby: traversal de árvores, YJIT-friendly
├── scripts/
│   ├── start.sh          # Entrypoint: verifica modelo → treina se ausente → puma
│   ├── train_model.py    # Python/sklearn+FAISS: KNN labels (14D) → RF (17D) → threshold
│   └── warmup_server.rb  # Servidor temporário durante treinamento (dev)
├── data/
│   ├── references.json.gz      # 3M vetores de referência (50MB gzipped)
│   ├── mcc_risk.json
│   ├── normalization.json
│   └── cache/
│       └── rf_model.json       # Modelo treinado (0.28MB, 200 árvores 17D, threshold=0.54)
├── Dockerfile                  # Multi-stage: build(Python+sklearn+FAISS) → run(ruby-slim)
├── docker-compose.yml          # 2 instâncias + nginx, 150MB/instância, RUBYOPT=--yjit
├── nginx.conf                  # least_conn, keepalive 256, buffering off
├── config.ru
└── puma.rb                     # YJIT.enable + 2 threads + preload_app!
```

## API

- `GET /ready` → `{"ok":true}`
- `POST /fraud-score` → `{"approved":bool,"fraud_score":float}`

## Variáveis de ambiente (runtime Docker)

| Variável | Valor | Descrição |
|---|---|---|
| `RUBYOPT` | `--yjit` | Habilita YJIT (Ruby 3.2+) |
| `DATA_DIR` | `/app/data` | Diretório dos dados |
| `BIND` | `tcp://0.0.0.0:9999` | Endereço Puma (nginx upstream) |
| `PUMA_THREADS` | `2` | 2 threads = ótimo para RF CPU-bound |
| `WEB_CONCURRENCY` | `0` | Single process |
| `MALLOC_ARENA_MAX` | `2` | Reduz RSS |
| `RUBY_GC_HEAP_FREE_SLOTS` | `200000` | Menos pauses de GC |
| `RUBY_GC_HEAP_INIT_SLOTS` | `200000` | GC inicial maior |

## Modelo RF (rf_model.json)

- **200 árvores**, max_depth=10, min_samples_leaf=100
- **class_weight={0:1, 1:3}** — penaliza 3× FN
- **KNN labels via BallTree** (local) ou FAISS (Docker)
- **Threshold=0.54** — mínimo de FP com FNR=0 na validação
- Features 14-16 derivadas de 0-13 sem dados adicionais
