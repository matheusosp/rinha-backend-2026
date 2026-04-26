FROM ruby:3.3.6-slim AS build

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential curl libopenblas-dev liblapack-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4

COPY scripts/ ./scripts/
RUN chmod +x scripts/fetch-data.sh && ./scripts/fetch-data.sh data

COPY lib/ ./lib/
COPY config.ru puma.rb ./

# Pre-warm the references cache so containers boot fast.
RUN bundle exec ruby -Ilib -e "require 'references'; \
    refs, lab = References.parse_json_gz('data/references.json.gz'); \
    References.save_cache('data/references.cache', refs, lab); \
    puts \"cached \#{refs.shape[0]} vectors\""

FROM ruby:3.3.6-slim AS run

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LANG=C.UTF-8 \
    RUBY_YJIT_ENABLE=1 \
    DATA_DIR=/app/data

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends libopenblas0 liblapack3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

EXPOSE 9999

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
