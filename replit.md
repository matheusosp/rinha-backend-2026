# Rinha de Backend 2026 — Ruby/RF

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude com Random Forest treinado sobre 3M vetores de referência em 17 dimensões.

## Stack

- **Ruby 3.3.6 + YJIT** — JIT habilitado via `RUBYOPT=--yjit`
- **Puma 6.6** — single process, 8 threads (`WEB_CONCURRENCY=0`, `PUMA_THREADS=8`)
- **Random Forest puro Ruby** — inferência em ~31µs/call com YJIT (local), ~97µs no Docker (0.4 CPU)
- **oj** — JSON parsing rápido
- **scikit-learn + FAISS** (build stage apenas) — treinamento durante `docker build`

## Performance (medida, local)

| Métrica | Valor |
|---|---|
| Inferência (YJIT, local) | 31 µs/call |
| P99 conns=1 (local) | 0.52 ms |
| P99 conns=4 (local, 8 threads) | 3.95 ms ✓ |
| P99 conns=8 (local, 8 threads) | 5.32 ms ✓ |
| P99 projetado Docker (ρ=0.044) | ~0.1–0.5 ms |
| p99Score projetado | ~3000–3300 |
| Memória Puma RSS (local) | ~67 MB |
| Memória Docker estimada | ~120 MB (< 150 MB) |
| GC frequency (2M slots) | ~1x em 89s → negligível |

## Configuração Docker (por instância)

| Variável | Valor | Motivo |
|---|---|---|
| `WEB_CONCURRENCY` | `0` | Single process: sem duplicação de heap (2 workers × 80 MB = OOM) |
| `PUMA_THREADS` | `8` | Absorve bursts de nginx; ρ=0.044 → fila praticamente vazia |
| `RUBY_GC_HEAP_INIT_SLOTS` | `2000000` | GC a cada ~89s → 1 evento no teste de 120s |
| `RUBY_GC_HEAP_FREE_SLOTS` | `2000000` | Idem |
| `RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR` | `4` | Atrasa major GC (default=2) |
| `MALLOC_ARENA_MAX` | `2` | Reduz fragmentação RSS |
| `RUBYOPT` | `--yjit` | 3× faster inference |
| `BIND` | `tcp://0.0.0.0:9999` | nginx upstream |

## Nginx

- `worker_processes 1` — 1 worker = conexões keepalive controladas
- `keepalive 32` — max 16 conns simultâneas por instância api (era 256)
- `least_conn` — balanceamento por menor fila

## Modelo RF (data/cache/rf_model.json)

- **200 árvores**, max_depth=8, min_samples_leaf=100
- **class_weight={0:1, 1:3}** — penaliza 3× FN (falso negativo = fraude aprovada)
- **KNN labels via BallTree** (local) / **FAISS** (Docker build — labels mais precisos)
- Features 14–16 derivadas melhoram separação FP vs fraude:
  - `14`: amount ÷ merchant_avg ÷ 100 (fraude ~82×, legítimo ~1×)
  - `15`: (1 − card_present) × amount_norm
  - `16`: velocidade de deslocamento km/h ÷ 900

## Testes com k6

### Pré-requisito

```bash
# Instalar k6 (Linux)
curl -fsSL https://github.com/grafana/k6/releases/download/v0.55.0/k6-v0.55.0-linux-amd64.tar.gz \
  | tar xz -C /tmp && sudo cp /tmp/k6-v0.55.0-linux-amd64/k6 /usr/local/bin/k6
```

### Teste local (dev, porta 5000)

```bash
# Smoke test (5 requisições, validação básica)
./scripts/test-local.sh smoke

# Load test completo (120s, ramp até 900 req/s) — results em test/results.json
./scripts/test-local.sh load
```

### Teste oficial (Docker, porta 9999)

```bash
# Conforme especificação da Rinha
./run.sh
```

### Arquivos de teste

| Arquivo | Descrição |
|---|---|
| `test/test.js` | Teste oficial: ramping-arrival-rate 120s → 900 req/s, fórmula de score |
| `test/smoke.js` | Smoke test: 5 iterações, 4 checks (status, JSON, approved, fraud_score) |
| `test/test-data.json` | 54100 entradas oficiais (26 MB) — campo `expected_approved` por entrada |
| `test/results.json` | Resultado do último `k6 run test/test.js` |

### Fórmula de score

```
E = FP×1 + FN×3 + errors×5
p99Score    = 1000 × log10(1000 / max(p99_ms, 1))
detScore    = 1000 × log10(1/ε) − 300 × log10(1+E)  [ε = E/N]
finalScore  = p99Score + detScore
```

Cortes: `p99 > 2000ms → p99Score = -3000` | `failures > 15% → detScore = -3000`

## Estrutura do projeto

```
.
├── lib/
│   ├── app.rb          # Rack: GET /ready, POST /fraud-score; warmup 2000x
│   ├── detector.rb     # build_vector (17D) + RF score + threshold
│   └── rf_model.rb     # Inferência pura Ruby: traversal de árvores, YJIT-friendly
├── scripts/
│   ├── start.sh            # Entrypoint: verifica modelo → treina se ausente → puma
│   ├── train_model.py      # Python/sklearn+FAISS: KNN labels → RF 17D → threshold
│   ├── fetch-data.sh       # Baixa references.json.gz, mcc_risk, normalization, test-data.json
│   ├── test-local.sh       # k6 smoke/load contra localhost:5000 (dev)
│   └── warmup_server.rb    # Servidor temporário durante treinamento (dev)
├── test/
│   ├── test.js             # Teste oficial k6 (cópia exata do repo Rinha)
│   ├── smoke.js            # Smoke test k6 (5 req, checks básicos)
│   ├── test-data.json      # 54100 entradas oficiais com expected_approved
│   └── results.json        # Output do último k6 run
├── data/
│   ├── references.json.gz      # 3M vetores (50 MB gzipped)
│   ├── mcc_risk.json
│   ├── normalization.json
│   └── cache/rf_model.json     # Modelo treinado (200 árvores 17D)
├── run.sh                  # Script oficial: k6 run test/test.js + cat results.json
├── Dockerfile              # Multi-stage: build(Python+FAISS) → run(ruby-slim)
├── docker-compose.yml      # 2×api (150MB, 0.4CPU) + nginx (50MB, 0.2CPU)
├── nginx.conf              # worker_processes=1, keepalive=32, least_conn
├── config.ru
└── puma.rb                 # YJIT + WEB_CONCURRENCY=0 + 8 threads + preload_app!
```

## API

- `GET /ready` → `{"ok":true}`
- `POST /fraud-score` → `{"approved":bool,"fraud_score":float}`
