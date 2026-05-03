# Rinha de Backend 2026 — Ruby

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) — detecção de fraude com busca vetorial em 14 dimensões sobre 3 milhões de referências.

## Stack

- **Ruby 3.2 + YJIT** — JIT habilitado via `RUBYOPT=--yjit`
- **Puma 6.6** — single process, 6 threads (= nproc)
- **hnswlib** — índice HNSW aproximado sobre 3M vetores (M=16, ef_construction=200, ef=40)
- **numo-narray** — labels em binário Int8 (~3MB em vez de ~150MB como Array Ruby)
- **oj** — JSON parsing rápido

## Performance (índice 3M vetores, AMD EPYC 9B14, 6 CPUs)

| Métrica | Valor |
|---|---|
| Latência P50 (sequential) | ~51ms |
| Throughput concorrente (6 threads) | ~64 req/s |
| Memória Puma (RSS) | ~930 MB |
| Índice HNSW em disco | 586 MB |
| Labels em binário | 3 MB |

## Otimizações aplicadas

### YJIT
- Ruby 3.2 JIT habilitado via `RUBYOPT=--yjit`
- Reduz alocações e inline-caches no hot path (`build_vector`, `score`)

### Threads Puma: 6
- `PUMA_THREADS=6` (= nproc do servidor)
- `hnswlib`'s `search_knn` é native C e libera o GVL → threads concorrem de verdade na busca (parte mais pesada do request)
- `queue_requests false` — sem fila interna → menor latência P99 sob carga alta

### Parâmetros HNSW otimizados para 3M vetores
| Param | Antes | Depois | Motivo |
|---|---|---|---|
| `HNSW_M` | 14 | 16 | Melhor conectividade em datasets grandes → recall ↑ |
| `HNSW_EF_CONSTRUCTION` | 150 | 200 | Índice de maior qualidade (custo só no build) |
| `HNSW_EF` | 28 | 40 | Melhor recall na query para 14 dimensões |

### Warmup
- 2000 iterações (era 500) → aquece o JIT, caches do HNSW e branch-predictor da CPU

### Cache automático do índice
- `scripts/build_cache.rb` — constrói o índice de 3M vetores e salva em `data/cache/`
- Cache invalidado automaticamente ao mudar `HNSW_M` ou `HNSW_EF_CONSTRUCTION`
- Após primeiro build (~44min), reinicializações subsequentes carregam do disco em segundos

### Startup com servidor warmup
- `scripts/start.sh` — orquestra fetch de dados + build de cache + start do puma
- `scripts/warmup_server.rb` — servidor TCP mínimo que ocupa a porta 5000 (retorna 503) enquanto o índice é construído no primeiro boot, garantindo que o processo não seja morto por timeout

## Estrutura do projeto

```
.
├── lib/
│   ├── app.rb          # Rack: GET /ready, POST /fraud-score; warmup 2000x
│   ├── detector.rb     # build_vector (14D) + search_knn + score
│   ├── references.rb   # Carrega/constrói índice HNSW com cache em disco
│   └── spinel_*.c      # Extensão C opcional (não compilada no Replit)
├── scripts/
│   ├── start.sh        # Entrypoint: fetch → cache build → puma
│   ├── build_cache.rb  # Constrói índice HNSW a partir de references.json.gz
│   ├── warmup_server.rb # Servidor temporário durante o build do cache
│   └── fetch-data.sh   # Download de references.json.gz, mcc_risk.json, normalization.json
├── data/
│   ├── references.json.gz      # 3M vetores de referência (50MB gzipped)
│   ├── mcc_risk.json
│   ├── normalization.json
│   └── cache/
│       ├── hnsw_m16_ec200.idx  # Índice HNSW (586MB, M=16, ef_construction=200)
│       └── labels.bin          # Labels Int8 binárias (3MB)
├── config.ru
└── puma.rb
```

## API

- `GET /ready` → `{"ok":true}`
- `POST /fraud-score` → `{"approved":bool,"fraud_score":float}`

## Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `DATA_DIR` | `data` | Diretório dos dados |
| `BIND` | `tcp://0.0.0.0:5000` | Endereço Puma |
| `PUMA_THREADS` | `6` | Threads Puma |
| `WEB_CONCURRENCY` | `0` | Workers Puma |
| `FRAUD_K` | `12` | K vizinhos para scoring |
| `FRAUD_SCORE_THRESHOLD` | `0.32` | Threshold de fraude |
| `HNSW_M` | `16` | Parâmetro M do HNSW |
| `HNSW_EF` | `40` | ef de busca do HNSW |
| `HNSW_EF_CONSTRUCTION` | `200` | ef de construção do HNSW |
