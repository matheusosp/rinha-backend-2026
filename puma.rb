RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable) && !RubyVM::YJIT.enabled?

bind ENV.fetch('BIND', 'tcp://0.0.0.0:5000')

workers Integer(ENV.fetch('WEB_CONCURRENCY', '0'))

# Two threads per API keep enough socket concurrency without adding scheduler
# contention under the 1 CPU aggregate Rinha limit.
threads_count = Integer(ENV.fetch('PUMA_THREADS', '2'))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning
