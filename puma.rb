bind ENV.fetch('BIND', 'tcp://0.0.0.0:5000')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))

# RF inference releases no GVL (pure Ruby), but threads still help with
# I/O and JSON parsing. 6 = nproc on Replit; Docker uses 2 (0.4 CPU limit).
threads_count = Integer(ENV.fetch('PUMA_THREADS', '6'))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning

# No internal queue: lower P99 under high load.
queue_requests false
