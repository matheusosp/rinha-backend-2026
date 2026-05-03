require 'oj'
require 'detector'

Oj.default_options = { mode: :strict }

class App
  JSON_HEADERS  = { 'content-type' => 'application/json' }.freeze
  EMPTY_HEADERS = {}.freeze

  READY_OK     = [200, JSON_HEADERS, ['{"ok":true}']].freeze
  NOT_FOUND    = [404, EMPTY_HEADERS, ['']].freeze
  BAD_REQUEST  = [400, EMPTY_HEADERS, ['']].freeze
  SERVER_ERROR = [500, EMPTY_HEADERS, ['']].freeze

  def initialize(detector: Detector.new(data_dir: ENV.fetch('DATA_DIR', 'data')))
    @detector = detector
    warmup
  end

  private

  def warmup
    sample = {
      'transaction' => { 'amount' => 100.0, 'installments' => 1, 'requested_at' => '2026-03-11T03:45:53Z' },
      'customer'    => { 'avg_amount' => 50.0, 'tx_count_24h' => 5, 'known_merchants' => ['MERC-001'] },
      'merchant'    => { 'id' => 'MERC-001', 'mcc' => '5411', 'avg_amount' => 100.0 },
      'terminal'    => { 'is_online' => true, 'card_present' => true, 'km_from_home' => 1.0 },
      'last_transaction' => nil
    }
    # 2000 iterações: aquece YJIT, caches do HNSW e branch-predictor da CPU.
    2_000.times { @detector.score(sample) }
  rescue StandardError => e
    warn "[warmup] #{e.class}: #{e.message}"
  end

  public

  def call(env)
    path   = env['PATH_INFO']
    method = env['REQUEST_METHOD']

    return READY_OK if method == 'GET' && path == '/ready'

    if method == 'POST' && path == '/fraud-score'
      req  = Oj.load(env['rack.input'])
      approved, score = @detector.score(req)
      return [200, JSON_HEADERS, ["{\"approved\":#{approved},\"fraud_score\":#{score}}"]]
    end

    NOT_FOUND
  rescue Oj::ParseError
    BAD_REQUEST
  rescue StandardError => e
    warn "[error] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    SERVER_ERROR
  end
end
