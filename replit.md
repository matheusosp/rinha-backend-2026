# Rinha de Backend 2026 — Ruby/RF

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude com Random Forest treinado sobre 3M vetores de referência em 14 dimensões.

## Stack

- **Ruby 3.3.6 + YJIT** — JIT habilitado via `RUBYOPT=--yjit` (Docker) e `RUBYOPT="--yjit"` (start.sh)
- **Puma 6.6** — single process, 2 threads (ótimo para workload CPU-bound puro)
- **Random Forest puro Ruby** — inferência em 30µs/call com YJIT
- **oj** — JSON parsing rápido
- **scikit-learn + FAISS** (build stage apenas) — treinamento do modelo durante `docker build`

## Performance (3M vetores, RF 200 árvores, YJIT)

| Métrica | Valor |
|---|---|
| Inferência (YJIT, local) | 30 µs/call |
| Throughput single-conn (local) | **3221 req/s** |
| Throughput 2-conn concurrent (local) | **3035 req/s** |
| Throughput por instância (0.4 CPU, Docker) | **~1286 req/s** |
| Throughput total 2 instâncias (Docker) | **~2572 req/s** (vs alvo 900) |
| P99 estimado em Docker | **< 2 ms** |
| Memória Puma (RSS) | **~52 MB** (vs 930 MB HNSW) |
| Modelo em disco | 0.20 MB |
| FNR (fraudes perdidas) | **0.000%** |
| FPR (falsos positivos) | 2.55% |

## Score estimado na Rinha (Teste 4+)

| Componente | Valor |
|---|---|
| P99 esperado | < 2ms |
| p99Score | **+2000** |
| FP estimados (~30K legítimos × 2.55%) | ~765 |
| FN estimados | 0 |
| Detection score | **~963** |
| **Score final estimado** | **~2963** |
| Melhor score anterior (Teste 2) | 238.85 |
| **Melhoria esperada** | **+2724 pontos (12×)** |

## Mudanças críticas para Teste 4

### 1. Removido `queue_requests false` de puma.rb
**Root cause do P99=1774ms**: com `queue_requests false`, Puma fechava conexões quando todas as threads estavam ocupadas, causando "Broken pipe" e reenvios pelo nginx. Sem essa opção, Puma usa a fila interna padrão — conexões são aceitas imediatamente e aguardam processamento sem drops.

### 2. YJIT garantido via `RUBYOPT=--yjit`
`RUBY_YJIT_ENABLE=1` funciona apenas em Ruby 3.3+. O Dockerfile agora usa `RUBYOPT=--yjit` que funciona em todas as versões. O puma.rb também chama `RubyVM::YJIT.enable` como safety net.

### 3. PUMA_THREADS=2 (ótimo)
Medições mostraram que 2 threads = 4210 req/s vs 4 threads = 1952 req/s (GVL contention piora com mais threads para workload puro CPU).

### 4. GC heap pre-alocado
`RUBY_GC_HEAP_FREE_SLOTS=200000` e `RUBY_GC_HEAP_INIT_SLOTS=200000` reduzem a frequência de GC durante o teste, evitando spikes de latência.

### 5. Threshold 0.15 (mínimo de FP com FNR=0%)
Análise em 100K amostras: threshold 0.12-0.39 → FP=1274, FN=0 (mínimo possível). train_model.py agora busca o ponto mais alto na região plana.

## Arquitetura

O modelo é treinado em Python/sklearn durante o `docker build` (stage `build`), e o JSON do modelo é baked na imagem final. Ao iniciar o container, o puma carrega o JSON em ~100ms e já está pronto para servir.

### Startup (Docker — sem treinamento)

1. Container inicia
2. Puma carrega `rf_model.json` (já baked na imagem)
3. Warmup interno: 2000 iterações de inferência em ~100ms
4. Container healthy em < 10 segundos

### Startup (Replit/dev — com treinamento)

1. `rf_model.json` não existe → inicia warmup_server na porta 5000
2. `scripts/train_model.py` treina RF em ~5-10 min sobre 3M vetores
3. Puma substitui o warmup server

## Estrutura do projeto

```
.
├── lib/
│   ├── app.rb          # Rack: GET /ready, POST /fraud-score; warmup 2000x
│   ├── detector.rb     # build_vector (14D) + RF score + threshold
│   └── rf_model.rb     # Inferência pura Ruby: traversal de árvores, YJIT-friendly
├── scripts/
│   ├── start.sh          # Entrypoint: verifica modelo → treina se ausente → puma
│   ├── train_model.py    # Python/sklearn+FAISS: KNN labels → RF 200 trees → threshold
│   └── warmup_server.rb  # Servidor temporário durante treinamento (dev)
├── data/
│   ├── references.json.gz      # 3M vetores de referência (50MB gzipped)
│   ├── mcc_risk.json
│   ├── normalization.json
│   └── cache/
│       └── rf_model.json       # Modelo treinado (0.20MB, threshold=0.15)
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
| `RUBYOPT` | `--yjit` | Habilita YJIT em todas as versões Ruby 3.x |
| `DATA_DIR` | `/app/data` | Diretório dos dados |
| `BIND` | `tcp://0.0.0.0:9999` | Endereço Puma (nginx upstream) |
| `PUMA_THREADS` | `2` | 2 threads = ótimo para RF CPU-bound |
| `WEB_CONCURRENCY` | `0` | Single process (fork overhead desnecessário) |
| `MALLOC_ARENA_MAX` | `2` | Limita arenas malloc → reduz RSS |
| `RUBY_GC_HEAP_FREE_SLOTS` | `200000` | GC pre-alocado → menos pauses |
| `RUBY_GC_HEAP_INIT_SLOTS` | `200000` | GC inicial maior → menos GC early |

## Modelo RF (rf_model.json)

- **200 árvores**, max_depth=8, min_samples_leaf=200
- **class_weight={0:1, 1:3}** — penaliza 3× mais FN (fraudes perdidas), alinhado à fórmula Rinha
- **KNN labels** — 150K amostras relabeladas com base em 5-NN (FAISS brute-force) para reduzir FNR
- **Threshold=0.15** — região plana de mínimo FP com FNR=0
- Treinado em ~120K amostras (KNN subset)
