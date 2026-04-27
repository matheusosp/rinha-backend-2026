FROM ruby:3.3.6-slim AS build

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential g++ curl libopenblas-dev liblapack-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4

RUN mkdir -p data && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/references.json.gz" -o data/references.json.gz && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/mcc_risk.json" -o data/mcc_risk.json && \
    curl -fsSL "https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources/normalization.json" -o data/normalization.json

COPY lib/ ./lib/
COPY config.ru puma.rb ./

# Build Spinel extension
RUN cd lib && \
    ruby extconf.rb && \
    make && \
    cp spinel_detector.so .. && \
    cd ..

# Pre-build the HNSW index and labels cache (alinhado ao run)
ENV HNSW_M=14 HNSW_EF_CONSTRUCTION=150 HNSW_EF=36
RUN rm -rf data/cache && bundle exec ruby -Ilib -e "require 'references'; \
    index, labels = References.load('data/references.json.gz', 'data/cache'); \
    puts \"cached vectors with index\""

FROM ruby:3.3.6-slim AS run

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 \
    RUBY_YJIT_ENABLE=1 \
    DATA_DIR=/app/data \
    MALLOC_ARENA_MAX=2 \
    FRAUD_SCORE_THRESHOLD=0.32 \
    FRAUD_K=11 \
    HNSW_M=14 \
    HNSW_EF_CONSTRUCTION=150 \
    HNSW_EF=36

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends libopenblas0 liblapack3 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

EXPOSE 9999

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
