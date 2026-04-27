# Rinha de Backend 2026 — Ruby

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026)
(detecção de fraude com busca vetorial em 14 dimensões).

## Stack

- **Ruby 3.3** + YJIT
- **Puma** (processo único com múltiplas threads, configurável via `PUMA_THREADS` / `WEB_CONCURRENCY`)
- **HNSW** ([hnswlib](https://github.com/nmslib/hnswlib), gem `hnswlib-rb`) — índice aproximado de vizinhos sobre ~1M vetores; parâmetros `HNSW_M`, `HNSW_EF`, `HNSW_EF_CONSTRUCTION` via env
- **Oj** para JSON
- **Spinel** (ver abaixo) — extensão C opcional para montar o vetor e calcular o score; se não carregar, usa caminho 100% Ruby
- **nginx** como load balancer (upstream com keep-alive)

## Spinel (extensão C)

O **Spinel** é uma extensão nativa compilada no build da imagem (`lib/extconf.rb` + `make` no `Dockerfile`), carregada em `lib/spinel_detector` como o Ruby constant `SpinelDetector`.

- **Quando ativa:** `require` da extensão com sucesso (`USE_SPINEL = true` em `lib/detector.rb`).
- **Quando desativa:** `LoadError` (ambiente de dev sem compilar, ou `.so` ausente) — o detector cai no modo Ruby: `build_vector` + contagem de rótulos fraud nos K vizinhos com `HNSW#search_knn`.
- **Papel no fluxo:** no modo Spinel, a extensão (C, ver `spinel_logic.c` / `spinel_wrapper.c`):
  - recebe os rótulos dos referenciais (bytes 0/1), o mapa MCC → risco e os limites de normalização;
  - **`SpinelDetector#build_vector`**: a partir do payload JSON, monta o vetor de 14 dimensões (equivalente à lógica de `build_vector` em Ruby, otimizado em C);
  - o **índice HNSW** continua sendo o da gem (`References.load` + `HierarchicalNSW#search_knn` em `k` = `FRAUD_K`);
  - **`SpinelDetector#calculate_score`**: a partir dos índices retornados pelo HNSW, produz o score de fraude (fração normalizada) usado na comparação com `FRAUD_SCORE_THRESHOLD`.
- **Concorrência:** o runtime C do Spinel usa o esquema `SP_GC_*` (não reentrante entre threads). Por isso, com **várias threads Puma**, o código serializa com mutex apenas `build_vector` (Spinel) e `calculate_score` (Spinel); a chamada **`search_knn` do HNSW fica fora** desse lock para permitir paralelismo na busca (leitura do grafo), alinhado ao comentário em `Detector#score`.

**Build local da extensão (opcional):**

```bash
cd lib && ruby extconf.rb && make
```

(Em Docker, o `Dockerfile` já compila e copia `spinel_detector.so` para a raiz da app.)

## Estratégia de classificação

- Vetor **14D** a partir de transação, cliente, estabelecimento, terminal, última transação (normalizados com `normalization.json` e MCC com `mcc_risk.json`).
- **K vizinhos** aproximados (HNSW); **score** = proporção de vizinhos rotulados como fraude, dividida por K (e threshold em `FRAUD_SCORE_THRESHOLD`).
- A transação é **aprovada** se `score < threshold`.

## Layout

```
.
├── lib/
│   ├── app.rb              # Rack: /ready, /fraud-score; warmup se aplicável
│   ├── detector.rb         # orquestra Spinel (opcional) + HNSW + threshold
│   ├── references.rb       # cache de índice HNSW + rótulos
│   ├── spinel_*.c          # lógica Spinel (C)
│   └── extconf.rb
├── scripts/fetch-data.sh
├── data/                   # populado no build da imagem
├── config.ru
├── puma.rb
├── Dockerfile
├── docker-compose.yml
└── nginx.conf
```

## Recursos (exemplo, limite no compose da prova: 1 CPU + 350 MB agregado)

| serviço | CPU  | memória (ex.) |
|--------:|:----:|:-------------:|
| nginx   | 0.10 | 50 MB         |
| api1    | 0.45 | 150 MB        |
| api2    | 0.45 | 150 MB        |

## Rodando

```bash
./scripts/fetch-data.sh data
docker compose up --build
curl http://localhost:9999/ready
curl -X POST http://localhost:9999/fraud-score \
  -H 'content-type: application/json' \
  -d @resources/example-payloads.json
```

(Em CI/Docker, os arquivos em `data/` costumam ser baixados no build da imagem.)

Para desenvolvimento local com imagem de código em vez de registry, use o override `docker-compose.local.yml` (ver exemplo no repositório).
