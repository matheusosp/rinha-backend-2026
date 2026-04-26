require 'json'
require 'time'
require 'numo/narray'
require 'references'

# Fraud detector: transforms a transaction into a 14-D vector and finds
# the 5 nearest references. Score = frauds_in_top5 / 5; approved when < 0.6.
class Detector
  THRESHOLD = 0.6
  K         = 5

  def initialize(data_dir:)
    norm = JSON.parse(File.read(File.join(data_dir, 'normalization.json')))
    @max_amount             = norm.fetch('max_amount').to_f
    @max_installments       = norm.fetch('max_installments').to_f
    @amount_vs_avg_ratio    = norm.fetch('amount_vs_avg_ratio').to_f
    @max_minutes            = norm.fetch('max_minutes').to_f
    @max_km                 = norm.fetch('max_km').to_f
    @max_tx_count_24h       = norm.fetch('max_tx_count_24h').to_f
    @max_merchant_avg       = norm.fetch('max_merchant_avg_amount').to_f

    @mcc_risk = JSON.parse(File.read(File.join(data_dir, 'mcc_risk.json')))

    refs, labels = References.load(
      File.join(data_dir, 'references.json.gz'),
      File.join(data_dir, 'references.cache')
    )
    @refs       = refs
    @labels_int = labels                      # 1 for fraud, 0 for legit
    @ref_norms  = (refs * refs).sum(axis: 1)  # ||r||² precomputed
  end

  # request: parsed JSON Hash. Returns [approved (bool), fraud_score (Float)].
  def score(req)
    q = build_vector(req)
    qn = NMath_dot(q, q)

    # ||r||² + ||q||² - 2 r·q  →  smallest distance² ⇔ largest dot product
    # We rank by dist² (== same ranking as -dot), then partial-pick top-K.
    dots = @refs.dot(q)                  # length-N vector via BLAS gemv
    dist2 = @ref_norms - 2.0 * dots + qn

    idx = top_k_indices(dist2, K)
    frauds = 0
    idx.each { |i| frauds += @labels_int[i] }

    score = frauds.to_f / K
    [score < THRESHOLD, score]
  end

  private

  # Builds the 14-D query vector. Returns Numo::SFloat[14].
  def build_vector(req)
    tx       = req['transaction']        || EMPTY_HASH
    customer = req['customer']           || EMPTY_HASH
    merchant = req['merchant']           || EMPTY_HASH
    terminal = req['terminal']           || EMPTY_HASH
    last_tx  = req['last_transaction']   # may be nil

    amount       = (tx['amount']       || 0).to_f
    installments = (tx['installments'] || 0).to_f
    requested_at = tx['requested_at']

    cust_avg     = (customer['avg_amount']   || 0).to_f
    tx_count_24h = (customer['tx_count_24h'] || 0).to_f
    known        = customer['known_merchants'] || EMPTY_ARRAY

    merchant_id   = merchant['id']
    merchant_mcc  = merchant['mcc']
    merchant_avg  = (merchant['avg_amount'] || 0).to_f

    is_online     = terminal['is_online']    ? 1.0 : 0.0
    card_present  = terminal['card_present'] ? 1.0 : 0.0
    km_from_home  = (terminal['km_from_home'] || 0).to_f

    if last_tx
      mins  = minutes_between(last_tx['timestamp'], requested_at)
      d5    = clamp(mins / @max_minutes)
      d6    = clamp((last_tx['km_from_current'] || 0).to_f / @max_km)
    else
      d5 = -1.0
      d6 = -1.0
    end

    t  = parse_time(requested_at)
    d3 = t.hour / 23.0
    # Mon=0..Sun=6 (Time#wday is Sun=0..Sat=6)
    d4 = ((t.wday + 6) % 7) / 6.0

    avg_ratio = cust_avg.positive? ? (amount / cust_avg) / @amount_vs_avg_ratio : 1.0

    Numo::SFloat[
      clamp(amount / @max_amount),
      clamp(installments / @max_installments),
      clamp(avg_ratio),
      d3,
      d4,
      d5,
      d6,
      clamp(km_from_home / @max_km),
      clamp(tx_count_24h / @max_tx_count_24h),
      is_online,
      card_present,
      known.include?(merchant_id) ? 0.0 : 1.0,
      (@mcc_risk[merchant_mcc] || 0.5).to_f,
      clamp(merchant_avg / @max_merchant_avg)
    ]
  end

  def clamp(v)
    return 0.0 if v < 0.0
    return 1.0 if v > 1.0
    v
  end

  def parse_time(s)
    Time.iso8601(s).utc
  rescue StandardError
    Time.at(0).utc
  end

  def minutes_between(a, b)
    ta = Time.iso8601(a)
    tb = Time.iso8601(b)
    (tb - ta).abs / 60.0
  rescue StandardError
    @max_minutes
  end

  def NMath_dot(a, b) # squared norm helper
    (a * b).sum
  end

  # Partial top-K by smallest values. Numo's sort_index is C-implemented;
  # for N=100k full sort runs in well under a millisecond.
  def top_k_indices(dist2, k)
    sorted = dist2.sort_index
    sorted[0...k].to_a
  end

  EMPTY_HASH  = {}.freeze
  EMPTY_ARRAY = [].freeze
end
