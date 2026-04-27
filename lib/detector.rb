require 'json'
require 'time'
require 'numo/narray'
require 'references'

# Fraud detector: builds a 14-D vector and finds the K=5 nearest neighbours
# in the reference set using an HNSW index.
# Score = frauds_in_topK / K; approved when score < 0.6.
class Detector
  THRESHOLD = 0.6
  K         = 5

  EPOCH       = Time.at(0).utc.freeze
  EMPTY_HASH  = {}.freeze
  EMPTY_ARRAY = [].freeze

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
    @index, @labels_int = References.load(
      File.join(data_dir, 'references.json.gz'),
      cache_dir
    )
  end

  def score(req)
    q = build_vector(req)
    indices, _ = @index.search_knn(q, K)
    
    frauds = 0
    indices.each { |idx| frauds += @labels_int[idx] }
    
    s = frauds.to_f / K
    [s < THRESHOLD, s]
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

    t = parse_time_fast(requested_at)

    if last_tx
      lt_ts = last_tx['timestamp']
      ta = parse_time_fast(lt_ts)
      mins = (t - ta).abs / 60.0
      d5 = mins > @max_minutes ? 1.0 : mins / @max_minutes
      km = (last_tx['km_from_current'] || 0).to_f
      d6 = km > @max_km ? 1.0 : km / @max_km
    else
      d5 = -1.0
      d6 = -1.0
    end

    avg_ratio = cust_avg > 0 ? (amount / cust_avg) / @amount_vs_avg_ratio : 1.0

    [
      amount > @max_amount ? 1.0 : amount / @max_amount,
      installments > @max_installments ? 1.0 : installments / @max_installments,
      avg_ratio > 1.0 ? 1.0 : (avg_ratio < 0 ? 0.0 : avg_ratio),
      t.hour / 23.0,
      ((t.wday + 6) % 7) / 6.0,
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

  def parse_time_fast(s)
    return EPOCH unless s && s.length >= 19
    # YYYY-MM-DDTHH:MM:SSZ
    Time.utc(s[0,4].to_i, s[5,2].to_i, s[8,2].to_i, s[11,2].to_i, s[14,2].to_i, s[17,2].to_i)
  rescue
    EPOCH
  end

end
