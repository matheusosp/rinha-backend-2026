bind ENV.fetch('BIND', 'tcp://0.0.0.0:9999')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 1))
threads_count = Integer(ENV.fetch('PUMA_THREADS', 4))
threads threads_count, threads_count

preload_app!

queue_requests false
