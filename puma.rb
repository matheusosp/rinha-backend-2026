RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?

bind ENV.fetch('BIND', 'tcp://0.0.0.0:5000')

workers Integer(ENV.fetch('WEB_CONCURRENCY', '0'))

# 2 threads optimal for pure-CPU workload: 1 holds GVL running RF,
# 1 reads the next request from socket (releases GVL during I/O).
# Measured: 2 threads = 4795 req/s vs 4 threads = 1952 req/s locally.
threads_count = Integer(ENV.fetch('PUMA_THREADS', '2'))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning
