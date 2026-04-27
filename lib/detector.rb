require 'json'
require 'time'
require 'numo/narray'
require 'references'

# Fraud detector: builds a 14-D vector and finds the K=5 nearest neighbours
# in the reference set. The Euclidean ranking is order-preserved by
# r_norms - 2 * refs.dot(q), so we skip ||q||^2 entirely and avoid sqrt.
# Score = frauds_in_topK / K; approved when score < 0.6.
class Detector
  THRESHOLD = 0.6
  K         = 5

  def initialize(data_dir:)
    norm = JSON.parse(File.read(File.join(data_dir, 'normalization.json')))
    @max_amount          = norm.fetch('max_amount').to_f
    @max_installments    = norm.fetch('max_installments').to_f
    @amount_vs_avg_ratio = norm.fetch('amount_vs_avg_ratio').to_f
    @max_minutes         = norm.fetch('max_minutes').to_f
    @max_km              = norm.fetch('max_km').to_f
    @max_tx_count_24h    = norm.fetch('max_tx_count_24h').to_f
    @max_merchant_avg    = norm.fetch('max_merchant_avg_amount').to_f

    @mcc_risk = JSON.parse(File.read(File.join(data_dir, 'mcc_risk.json')))

    cache_dir = File.join(data_dir, 'cache')
    refs, r_norms, labels = References.load(
      File.join(data_dir, 'references.json.gz'),
      cache_dir
    )
    @refs       = refs
    @r_norms    = r_norms
    @labels_int = labels
  end

  # request: parsed JSON Hash. Returns [approved (Boolean), fraud_score (Float)].
  def score(req)
    q = build_vector(req)

    # scores[i] = ||r_i||^2 - 2 * r_i . q  (||q||^2 dropped — same ordering)
    scores = @r_norms - (@refs.dot(q) * 2.0)

    # Top-K via sort_index: for n=100k, Numo's sort_index is often faster than
    # repeated min_index in Ruby because it stays in C.
    top_k_indices = scores.sort_index[0...K]
    frauds = @labels_int[top_k_indices].sum

    score = frauds.to_f / K
    [score < THRESHOLD, score]
  end

  private

  def build_vector(req)
    tx       = req['transaction']  || EMPTY_HASH
    customer = req['customer']     || EMPTY_HASH
    merchant = req['merchant']     || EMPTY_HASH
    terminal = req['terminal']     || EMPTY_HASH
    last_tx  = req['last_transaction']

    amount       = (tx['amount']       || 0).to_f
    installments = (tx['installments'] || 0).to_f
    requested_at = tx['requested_at']

    cust_avg     = (customer['avg_amount']   || 0).to_f
    tx_count_24h = (customer['tx_count_24h'] || 0).to_f
    known        = customer['known_merchants'] || EMPTY_ARRAY

    merchant_id  = merchant['id']
    merchant_mcc = merchant['mcc']
    merchant_avg = (merchant['avg_amount'] || 0).to_f

    is_online    = terminal['is_online']    ? 1.0 : 0.0
    card_present = terminal['card_present'] ? 1.0 : 0.0
    km_from_home = (terminal['km_from_home'] || 0).to_f

    t = parse_time(requested_at)

    if last_tx
      lt_ts = last_tx['timestamp']
      # Fast minutes_between
      ta = parse_time(lt_ts)
      mins = (t - ta).abs / 60.0
      d5   = mins > @max_minutes ? 1.0 : mins / @max_minutes
      km   = (last_tx['km_from_current'] || 0).to_f
      d6   = km > @max_km ? 1.0 : km / @max_km
    else
      d5 = -1.0
      d6 = -1.0
    end

    d3 = t.hour / 23.0
    d4 = ((t.wday + 6) % 7) / 6.0

    avg_ratio = cust_avg > 0 ? (amount / cust_avg) / @amount_vs_avg_ratio : 1.0

    Numo::SFloat[
      amount > @max_amount ? 1.0 : amount / @max_amount,
      installments > @max_installments ? 1.0 : installments / @max_installments,
      avg_ratio > 1.0 ? 1.0 : (avg_ratio < 0 ? 0.0 : avg_ratio),
      d3,
      d4,
      d5,
      d6,
      km_from_home > @max_km ? 1.0 : km_from_home / @max_km,
      tx_count_24h > @max_tx_count_24h ? 1.0 : tx_count_24h / @max_tx_count_24h,
      is_online,
      card_present,
      known.include?(merchant_id) ? 0.0 : 1.0,
      (@mcc_risk[merchant_mcc] || 0.5).to_f,
      merchant_avg > @max_merchant_avg ? 1.0 : merchant_avg / @max_merchant_avg
    ]
  end

  def clamp(v)
    return 0.0 if v < 0.0
    return 1.0 if v > 1.0
    v
  end

  def parse_time(s)
    Time.iso8601(s).utc
  rescue
    EPOCH
  end

  def minutes_between(a, b)
    ta = Time.iso8601(a)
    tb = Time.iso8601(b)
    (tb - ta).abs / 60.0
  rescue StandardError
    @max_minutes
  end

  EPOCH       = Time.at(0).utc.freeze
  EMPTY_HASH  = {}.freeze
  EMPTY_ARRAY = [].freeze
end
