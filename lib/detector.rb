require 'json'
require 'time'
require 'numo/narray'
require 'references'

begin
  # Tries to load the Spinel-compiled extension
  require_relative 'spinel_detector'
  USE_SPINEL = true
rescue LoadError
  USE_SPINEL = false
end

# Fraud detector: builds a 14-D vector and finds the K=11 nearest neighbours
# in the reference set using an HNSW index.
  # Score = frauds_in_topK / K; approved when score < 0.3.
class Detector
  THRESHOLD = 0.3
  K         = 11
  INV_K     = 1.0 / K

  EPOCH       = Time.at(0).utc.freeze
  EMPTY_HASH  = {}.freeze
  EMPTY_ARRAY = [].freeze

  HOUR_MUL = 1.0 / 23.0
  WDAY_MUL = 1.0 / 6.0
  MINS_MUL = 1.0 / 60.0

    # We can pre-calculate 1.0/60.0
    INV_60 = 1.0 / 60.0

  def initialize(data_dir:)
    @mutex = Mutex.new
    norm = Oj.load(File.read(File.join(data_dir, 'normalization.json')))
    @max_amount          = norm.fetch('max_amount').to_f
    @max_installments    = norm.fetch('max_installments').to_f
    @amount_vs_avg_ratio = norm.fetch('amount_vs_avg_ratio').to_f
    @max_minutes         = norm.fetch('max_minutes').to_f
    @max_km              = norm.fetch('max_km').to_f
    @max_tx_count_24h    = norm.fetch('max_tx_count_24h').to_f
    @max_merchant_avg    = norm.fetch('max_merchant_avg_amount').to_f
    
    @inv_max_amount          = 1.0 / (@max_amount > 0 ? @max_amount : 1.0)
    @inv_max_installments    = 1.0 / (@max_installments > 0 ? @max_installments : 1.0)
    @inv_amount_vs_avg_ratio = 1.0 / (@amount_vs_avg_ratio > 0 ? @amount_vs_avg_ratio : 1.0)
    @inv_max_minutes         = 1.0 / (@max_minutes > 0 ? @max_minutes : 1.0)
    @inv_max_km              = 1.0 / (@max_km > 0 ? @max_km : 1.0)
    @inv_max_tx_count_24h    = 1.0 / (@max_tx_count_24h > 0 ? @max_tx_count_24h : 1.0)
    @inv_max_merchant_avg    = 1.0 / (@max_merchant_avg > 0 ? @max_merchant_avg : 1.0)

    @mcc_risk = Oj.load(File.read(File.join(data_dir, 'mcc_risk.json')))
    @mcc_risk.transform_values!(&:to_f)
    @mcc_risk.default = 0.5

    cache_dir = File.join(data_dir, 'cache')
    @index, labels_numo = References.load(
      File.join(data_dir, 'references.json.gz'),
      cache_dir
    )
    @labels = labels_numo.to_a

    if USE_SPINEL
      norm_data = [
        @max_amount, @max_installments, @amount_vs_avg_ratio,
        @max_minutes, @max_km, @max_tx_count_24h, @max_merchant_avg
      ]
      @spinel = SpinelDetector.new(@labels, @mcc_risk, norm_data)
    end
  end

  def score(req)
    if USE_SPINEL
      q = @mutex.synchronize { build_vector_spinel(req) }
      indices, _ = @index.search_knn(q, K)
      s = @mutex.synchronize { @spinel.calculate_score(indices) }
    else
      q = build_vector(req)
      indices, _ = @index.search_knn(q, K)
      
      frauds = 0
      indices.each { |i| frauds += @labels[i] }
      
      s = frauds.to_f * INV_K
    end
    
    [s < THRESHOLD, s]
  end

  private

  def build_vector_spinel(req)
    tx = req['transaction']
    cust = req['customer']
    merch = req['merchant']
    term = req['terminal']
    last_tx = req['last_transaction']

    t_str = tx['requested_at']
    # Format: 2026-03-11T03:45:53Z
    # We can use Time.utc with substring extraction which is faster than full parsing
    t = Time.utc(t_str[0,4].to_i, t_str[5,2].to_i, t_str[8,2].to_i, t_str[11,2].to_i, t_str[14,2].to_i, t_str[17,2].to_i)
    
    t_to_i = t.to_i
    
    last_tx_mins = -1.0
    last_tx_km = -1.0
    if last_tx
      ta_str = last_tx['timestamp']
      ta_to_i = Time.utc(ta_str[0,4].to_i, ta_str[5,2].to_i, ta_str[8,2].to_i, ta_str[11,2].to_i, ta_str[14,2].to_i, ta_str[17,2].to_i).to_i
      last_tx_mins = (t_to_i - ta_to_i).abs * INV_60
      last_tx_km = last_tx['km_from_current'].to_f
    end

    known = cust['known_merchants']
    # If it's a fraud-heavy customer, 'include?' might be slow if the list is huge.
    # But usually it's small.
    known_merch = (known && known.include?(merch['id']))

    args = [
      tx['amount'],
      tx['installments'],
      cust['avg_amount'],
      t.hour,
      (t.wday + 6) % 7,
      last_tx_mins,
      last_tx_km,
      term['km_from_home'],
      cust['tx_count_24h'],
      !!term['is_online'],
      !!term['card_present'],
      !!known_merch,
      merch['mcc'],
      merch['avg_amount']
    ]
    @spinel.build_vector(args)
  end

  def build_vector(req)
    tx = req['transaction'] || EMPTY_HASH
    cust = req['customer'] || EMPTY_HASH
    merch = req['merchant'] || EMPTY_HASH
    term = req['terminal'] || EMPTY_HASH
    last_tx = req['last_transaction']

    t_str = tx['requested_at']
    t = if t_str && t_str.length >= 19
          Time.utc(t_str[0,4].to_i, t_str[5,2].to_i, t_str[8,2].to_i, t_str[11,2].to_i, t_str[14,2].to_i, t_str[17,2].to_i)
        else
          EPOCH
        end
    
    amount = tx['amount'].to_f
    inst = tx['installments'].to_f
    
    cust_avg = cust['avg_amount'].to_f
    avg_ratio = if cust_avg > 0
                  (amount / cust_avg) * @inv_amount_vs_avg_ratio
                else
                  1.0
                end

    if last_tx
      ta = parse_time_fast(last_tx['timestamp'])
      mins = (t - ta).abs * MINS_MUL
      d5 = mins > @max_minutes ? 1.0 : mins * @inv_max_minutes
      km = last_tx['km_from_current'].to_f
      d6 = km > @max_km ? 1.0 : km * @inv_max_km
    else
      d5 = -1.0
      d6 = -1.0
    end

    km_home = term['km_from_home'].to_f
    tx_c = cust['tx_count_24h'].to_f
    known = cust['known_merchants']
    mcc = merch['mcc']

    [
      amount > @max_amount ? 1.0 : amount * @inv_max_amount,
      inst > @max_installments ? 1.0 : inst * @inv_max_installments,
      avg_ratio > 1.0 ? 1.0 : (avg_ratio < 0 ? 0.0 : avg_ratio),
      t.hour * HOUR_MUL,
      ((t.wday + 6) % 7) * WDAY_MUL,
      d5,
      d6,
      km_home > @max_km ? 1.0 : km_home * @inv_max_km,
      tx_c > @max_tx_count_24h ? 1.0 : tx_c * @inv_max_tx_count_24h,
      term['is_online'] ? 1.0 : 0.0,
      term['card_present'] ? 1.0 : 0.0,
      (known && known.include?(merch['id'])) ? 0.0 : 1.0,
      @mcc_risk[mcc],
      (m_avg = merch['avg_amount'].to_f) > @max_merchant_avg ? 1.0 : m_avg * @inv_max_merchant_avg
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
