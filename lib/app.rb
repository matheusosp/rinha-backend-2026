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
  end

  def call(env)
    path   = env['PATH_INFO']
    method = env['REQUEST_METHOD']

    return READY_OK if method == 'GET' && path == '/ready'

    if method == 'POST' && path == '/fraud-score'
      req  = Oj.load(env['rack.input'])
      approved, score = @detector.score(req)
      payload = Oj.dump({ 'approved' => approved, 'fraud_score' => score }, mode: :strict)
      return [200, JSON_HEADERS, [payload]]
    end

    NOT_FOUND
  rescue Oj::ParseError
    BAD_REQUEST
  rescue StandardError => e
    warn "[error] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    SERVER_ERROR
  end
end
