bind ENV.fetch('BIND', 'tcp://0.0.0.0:5000')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))

# 6 threads = nproc. HNSW search_knn é native C e libera o GVL,
# então threads concorrem de verdade na busca (parte mais pesada do request).
threads_count = Integer(ENV.fetch('PUMA_THREADS', '6'))
threads threads_count, threads_count

# CoW-safe: carrega o app antes de forkar workers (se WEB_CONCURRENCY > 0).
preload_app!
silence_single_worker_warning

# Sem fila no reactor — reduz latência P99 sob carga alta (k6 650+ rps).
queue_requests false
