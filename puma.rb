bind ENV.fetch('BIND', 'tcp://0.0.0.0:9999')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))
threads_count = Integer(ENV.fetch('PUMA_THREADS', 8))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning

queue_requests true

# Pre-warm YJIT and the BLAS path with a few synthetic requests so that the
# first real burst from k6 doesn't pay the cold-start cost on every worker.
# We do this in a way that doesn't reload the index if possible.
on_worker_boot do
  # The app already has a detector instance in single mode or preloaded mode.
  # We just want to exercise it.
end
