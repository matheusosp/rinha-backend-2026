FROM ruby:3.3.6-slim AS build

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

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

RUN cd lib && ruby extconf.rb && make
RUN DATA_DIR=data bundle exec ruby scripts/build_border_index.rb && \
    rm -f data/references.json.gz

FROM ruby:3.3.6-slim AS run

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 \
    RUBYOPT=--yjit \
    DATA_DIR=/app/data \
    MALLOC_ARENA_MAX=2 \
    RUBY_GC_HEAP_FREE_SLOTS=2000000 \
    RUBY_GC_HEAP_INIT_SLOTS=2000000 \
    RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=4 \
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
