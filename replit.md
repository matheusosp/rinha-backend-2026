# Project Notes

This solution is Ruby + C only. The Docker build downloads the official Rinha resources, compiles the `spinel_detector` native extension, and builds `data/cache/border_index.bin` with Ruby.

Runtime flow:

- Ruby handles the Rack app, JSON parsing, and fast profile gates.
- C/Spinel builds the normalized vector for ambiguous requests and runs exact 5-NN over the compact borderline index.
- The full `references.json.gz` file is not kept in the final image.

Useful commands:

```bash
./scripts/fetch-data.sh data
DATA_DIR=data ruby scripts/build_border_index.rb
DATA_DIR=data ruby test/offline_detector_test.rb
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build -d
docker run --rm -v "$PWD:/work" -w /work grafana/k6:latest run test/test.js
```
