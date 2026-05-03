RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable) && !RubyVM::YJIT.enabled?

bind ENV.fetch('BIND', 'tcp://0.0.0.0:9999')

workers Integer(ENV.fetch('WEB_CONCURRENCY', '0'))

# 8 threads: handles nginx keepalive bursts. GVL serializes CPU work, but at
# 97µs/request (0.4 CPU) and 450 req/s actual load, utilisation ρ=0.044 →
# queue practically always empty → P99 < 1ms.
threads_count = Integer(ENV.fetch('PUMA_THREADS', '8'))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning
