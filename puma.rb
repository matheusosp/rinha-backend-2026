bind ENV.fetch('BIND', 'tcp://0.0.0.0:9999')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))
threads_count = Integer(ENV.fetch('PUMA_THREADS', '2'))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning

# Menos fila no reactor sob carga alta (k6 650 rps); reduz latência vs queue_requests true.
queue_requests false
