# Rinha de Backend 2026 — Ruby

Solução em Ruby para o desafio [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026)
(detecção de fraude com busca vetorial em 14 dimensões).

## Stack

- **Ruby 3.3** + YJIT
- **Puma** (1 worker, 4 threads — operações vetorizadas liberam o GVL)
- **Numo::NArray** + BLAS para o KNN (`gemv` em 100k × 14)
- **Oj** para JSON
- **nginx** como load balancer (round-robin)

## Estratégia de performance

Em vez de calcular distâncias euclidianas direto, a distância ao quadrado é decomposta:

```
‖r − q‖² = ‖r‖² + ‖q‖² − 2·r·q
```

`‖r‖²` é pré-computado uma vez no boot. Por requisição sobra apenas:

1. um produto matriz × vetor (`refs.dot(q)`, BLAS `sgemv`),
2. uma soma vetorial,
3. um sort parcial para os 5 menores.

Tudo roda em C (Numo + BLAS), com um único traço pelos 100k vetores.

## Layout

```
.
├── lib/
│   ├── app.rb          # Rack app: /ready, /fraud-score
│   ├── detector.rb     # vetorização + KNN
│   └── references.rb   # carregamento + cache Marshal
├── scripts/fetch-data.sh
├── data/               # populado por fetch-data.sh
├── config.ru
├── puma.rb
├── Dockerfile
├── docker-compose.yml
└── nginx.conf
```

## Recursos (limite total: 1 CPU + 350 MB)

| serviço | CPU  | memória |
|--------:|:----:|:-------:|
| nginx   | 0.10 | 50 MB   |
| api1    | 0.45 | 150 MB  |
| api2    | 0.45 | 150 MB  |

## Rodando

```bash
./scripts/fetch-data.sh data
docker compose up --build
curl http://localhost:9999/ready
curl -X POST http://localhost:9999/fraud-score \
  -H 'content-type: application/json' \
  -d @resources/example-payloads.json
```

(Em CI/Docker o `fetch-data.sh` é executado dentro do build da imagem.)
