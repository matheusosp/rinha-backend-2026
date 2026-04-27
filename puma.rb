bind ENV.fetch('BIND', 'tcp://0.0.0.0:9999')

workers Integer(ENV.fetch('WEB_CONCURRENCY', 0))
threads_count = Integer(ENV.fetch('PUMA_THREADS', 8))
threads threads_count, threads_count

preload_app!
silence_single_worker_warning

queue_requests false

# Pre-warm YJIT and the BLAS path with a few synthetic requests so that the
# first real burst from k6 doesn't pay the cold-start cost on every worker.
on_worker_boot do
  begin
    require 'detector'
    detector = Detector.new(data_dir: ENV.fetch('DATA_DIR', 'data'))
    sample = {
      'transaction' => { 'amount' => 100.0, 'installments' => 1, 'requested_at' => '2026-03-11T03:45:53Z' },
      'customer'    => { 'avg_amount' => 50.0, 'tx_count_24h' => 5, 'known_merchants' => ['MERC-001'] },
      'merchant'    => { 'id' => 'MERC-001', 'mcc' => '5411', 'avg_amount' => 100.0 },
      'terminal'    => { 'is_online' => true, 'card_present' => true, 'km_from_home' => 1.0 },
      'last_transaction' => nil
    }
    200.times { detector.score(sample) }
  rescue StandardError => e
    warn "[warmup] #{e.class}: #{e.message}"
  end
end
