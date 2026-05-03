FROM ruby:3.3.6-slim AS build

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages --no-cache-dir scikit-learn numpy

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4

RUN mkdir -p data && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/references.json.gz" -o data/references.json.gz && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/mcc_risk.json"       -o data/mcc_risk.json && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/normalization.json"  -o data/normalization.json

COPY lib/     ./lib/
COPY scripts/ ./scripts/
COPY config.ru puma.rb ./

# Train RF model during build — bakes rf_model.json into the image.
# At runtime no training needed: startup is instant.
RUN DATA_DIR=data python3 scripts/train_model.py

FROM ruby:3.3.6-slim AS run

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 \
    RUBY_YJIT_ENABLE=1 \
    DATA_DIR=/app/data \
    MALLOC_ARENA_MAX=2 \
    WEB_CONCURRENCY=0 \
    PUMA_THREADS=2 \
    BIND=tcp://0.0.0.0:9999

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

EXPOSE 9999

CMD ["bundle", "exec", "puma", "-C", "puma.rb", "config.ru"]
