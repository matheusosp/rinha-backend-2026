# Rinha de Backend 2026 — Ruby

A Ruby fraud detection API built for the [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) challenge.

## Overview

This is a REST API that scores financial transactions for fraud probability using HNSW (Hierarchical Navigable Small World) approximate nearest-neighbor search over a 14-dimensional feature vector.

## Stack

- **Ruby 3.2** — via Replit module `ruby-3.2`
- **Puma 6.6** — Rack web server (single process, 2 threads by default)
- **Rack 3.x** — minimal HTTP framework
- **hnswlib** — HNSW index for fast K-NN search
- **numo-narray / numo-linalg** — numerical arrays (requires OpenBLAS/LAPACK)
- **oj** — fast JSON parsing

## System Dependencies

- `openblas` and `lapack` — required by `numo-linalg` native extension (installed via Nix)

## Project Structure

```
.
├── lib/
│   ├── app.rb          # Rack app: GET /ready, POST /fraud-score
│   ├── detector.rb     # Orchestrates HNSW + fraud threshold logic
│   ├── references.rb   # Loads/caches HNSW index from references data
│   └── spinel_*.c      # Optional C extension (Spinel) — not compiled in Replit
├── data/
│   ├── references.json.gz      # Full 3M reference vectors (production)
│   ├── references_dev.json.gz  # 100K sample for dev (used when RACK_ENV != production)
│   ├── mcc_risk.json           # MCC category risk scores
│   ├── normalization.json      # Feature normalization bounds
│   └── cache/                  # Pre-built HNSW index cache (auto-generated)
├── config.ru           # Rack entry point
├── puma.rb             # Puma server config (port 5000 default)
├── scripts/
│   └── fetch-data.sh   # Downloads data files from upstream repo
└── test_payload.json   # Sample fraud score request payload
```

## API Endpoints

- `GET /ready` — Health check, returns `{"ok":true}`
- `POST /fraud-score` — Score a transaction, returns `{"approved":bool,"fraud_score":float}`

## Development Setup

1. Gems are managed via Bundler:
   ```bash
   bundle install
   ```

2. Data files are fetched from upstream:
   ```bash
   ./scripts/fetch-data.sh data
   ```

3. The HNSW index cache is pre-built in `data/cache/`. In development, the app uses a 100K-entry sample (`references_dev.json.gz`).

4. Server runs on port **5000** via workflow: `bundle exec puma -C puma.rb config.ru`

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DATA_DIR` | `data` | Path to data files directory |
| `BIND` | `tcp://0.0.0.0:5000` | Puma bind address |
| `PUMA_THREADS` | `2` | Thread pool size |
| `WEB_CONCURRENCY` | `0` | Puma worker processes (0 = single mode) |
| `FRAUD_K` | `12` | K nearest neighbors for scoring |
| `FRAUD_SCORE_THRESHOLD` | `0.32` | Fraud score threshold (approve if score < threshold) |
| `HNSW_M` | `14` | HNSW M parameter |
| `HNSW_EF` | `28` | HNSW ef search parameter |
| `HNSW_EF_CONSTRUCTION` | `150` | HNSW ef construction parameter |
| `RACK_ENV` | `development` | Set to `production` to use full 3M reference dataset |

## Notes

- The Spinel C extension (`spinel_detector.so`) is compiled in Docker but not in Replit. The app falls back gracefully to pure Ruby mode.
- First boot without cache takes very long (building HNSW from 3M vectors). The cache in `data/cache/` eliminates this on subsequent starts.
- In dev mode (`RACK_ENV != production`), the app uses the 100K-entry dev dataset to allow fast startup.
