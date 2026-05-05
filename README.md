# Rinha de Backend 2026 - Ruby + C/Spinel

Backend para a Rinha de Backend 2026, focado em p99 baixo e boa deteccao sem Python no build nem no runtime.

## Stack

- Ruby 3.3 + YJIT
- Puma + Rack + Oj
- nginx como load balancer na porta `9999`
- Extensao C `spinel_detector`, compilada no `docker build`
- Builder Ruby `scripts/build_border_index.rb` para gerar `data/cache/border_index.bin`

## Estrategia

O gerador oficial separa a massa em perfis muito distintos e uma faixa pequena de casos borderline. O detector usa dois caminhos:

1. Regras Ruby de perfil para aprovar/nega rapidamente os casos claramente legitimos ou fraudulentos.
2. KNN exato em C/Spinel, com `k=5`, apenas sobre um indice compacto de referencias na regiao borderline.

Assim, o runtime nao carrega os 3M vetores completos. O arquivo `references.json.gz` e usado somente durante o build para gerar o indice compacto e depois e removido da imagem final.

## Layout

```text
.
|-- lib/
|   |-- app.rb
|   |-- detector.rb
|   |-- spinel_logic.c
|   |-- spinel_wrapper.c
|   `-- extconf.rb
|-- scripts/
|   |-- build_border_index.rb
|   |-- fetch-data.sh
|   `-- start.sh
|-- test/
|   |-- test.js
|   |-- smoke.js
|   `-- offline_detector_test.rb
|-- Dockerfile
|-- docker-compose.yml
`-- nginx.conf
```

## Rodando

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d
curl http://localhost:9999/ready
```

Teste offline de deteccao:

```bash
DATA_DIR=data ruby test/offline_detector_test.rb
```

Teste da Rinha:

```bash
docker run --rm -v "$PWD:/work" -w /work grafana/k6:latest run test/test.js
```

## Limites da submissao

O `docker-compose.yml` declara duas APIs e um nginx em rede `bridge`, somando `1 CPU` e `350 MB`:

| servico | CPU | memoria |
| --- | ---: | ---: |
| api1 | 0.40 | 150 MB |
| api2 | 0.40 | 150 MB |
| nginx | 0.20 | 50 MB |
