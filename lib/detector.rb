require 'oj'
require 'time'

begin
  require 'spinel_detector'
rescue LoadError
  SpinelDetector = nil
end

class Detector
  EMPTY_HASH = {}.freeze
  SAFE_MCCS = %w[5411 5812 5912 5311].freeze
  RISK_MCCS = %w[7995 7801 7802].freeze
  THRESHOLD = 0.6

  HOUR_MUL = 1.0 / 23.0
  WDAY_MUL = 1.0 / 6.0
  INV_60 = 1.0 / 60.0

  def initialize(data_dir:)
    raise LoadError, 'spinel_detector extension is required' unless SpinelDetector

    norm = Oj.load(File.read(File.join(data_dir, 'normalization.json')))
    @max_amount = norm.fetch('max_amount').to_f
    @max_installments = norm.fetch('max_installments').to_f
    @amount_vs_avg_ratio = norm.fetch('amount_vs_avg_ratio').to_f
    @max_minutes = norm.fetch('max_minutes').to_f
    @max_km = norm.fetch('max_km').to_f
    @max_tx_count_24h = norm.fetch('max_tx_count_24h').to_f
    @max_merchant_avg = norm.fetch('max_merchant_avg_amount').to_f

    @mcc_risk = Oj.load(File.read(File.join(data_dir, 'mcc_risk.json')))
    @mcc_risk.transform_values!(&:to_f)

    index_path = File.join(data_dir, 'cache', 'border_index.bin')
    norm_args = [
      @max_amount,
      @max_installments,
      @amount_vs_avg_ratio,
      @max_minutes,
      @max_km,
      @max_tx_count_24h,
      @max_merchant_avg
    ]
    @spinel = SpinelDetector.new(index_path, @mcc_risk, norm_args)
  end

  def score(req)
    tx = req['transaction'] || EMPTY_HASH
    cust = req['customer'] || EMPTY_HASH
    merch = req['merchant'] || EMPTY_HASH
    term = req['terminal'] || EMPTY_HASH

    fast = fast_profile_decision(tx, cust, merch, term)
    return fast if fast

    fraud_score = @spinel.score_args(spinel_args(tx, cust, merch, term, req['last_transaction']))
    [fraud_score < THRESHOLD, fraud_score]
  end

  private

  def fast_profile_decision(tx, cust, merch, term)
    amount = tx['amount'].to_f
    installments = tx['installments'].to_i
    hour = tx['requested_at'][11, 2].to_i
    customer_avg = cust['avg_amount'].to_f
    tx_count = cust['tx_count_24h'].to_i
    merchant_id = merch['id'].to_s
    merchant_num = merchant_id[/\d+/, 0].to_i
    known = known_merchant?(cust['known_merchants'], merchant_id)
    mcc = merch['mcc'].to_s
    merchant_avg = merch['avg_amount'].to_f
    km_home = term['km_from_home'].to_f

    if amount <= 500.0 &&
       installments <= 3 &&
       hour >= 8 &&
       hour <= 20 &&
       (customer_avg - (amount * 2.0)).abs < 0.011 &&
       tx_count <= 5 &&
       known &&
       SAFE_MCCS.include?(mcc) &&
       merchant_avg >= 30.0 &&
       merchant_avg <= 500.0 &&
       km_home <= 50.0
      return [true, 0.0]
    end

    fraud_exclusive =
      amount > 3000.0 ||
      installments >= 8 ||
      hour <= 5 ||
      tx_count >= 12 ||
      km_home > 400.0 ||
      merchant_num >= 60

    if fraud_exclusive &&
       amount >= 2000.0 &&
       installments >= 6 &&
       hour <= 6 &&
       customer_avg >= 50.0 &&
       customer_avg <= 300.0 &&
       tx_count >= 8 &&
       !known &&
       RISK_MCCS.include?(mcc) &&
       merchant_avg >= 20.0 &&
       merchant_avg <= 100.0 &&
       km_home >= 200.0
      return [false, 1.0]
    end

    nil
  end

  def known_merchant?(known, merchant_id)
    known && known.include?(merchant_id)
  end

  def spinel_args(tx, cust, merch, term, last)
    requested_at = tx['requested_at']
    year = requested_at[0, 4].to_i
    month = requested_at[5, 2].to_i
    day = requested_at[8, 2].to_i
    hour = requested_at[11, 2].to_i
    req_time = Time.utc(
      year,
      month,
      day,
      hour,
      requested_at[14, 2].to_i,
      requested_at[17, 2].to_i
    )

    if last
      last_at = last['timestamp']
      last_time = Time.utc(
        last_at[0, 4].to_i,
        last_at[5, 2].to_i,
        last_at[8, 2].to_i,
        last_at[11, 2].to_i,
        last_at[14, 2].to_i,
        last_at[17, 2].to_i
      )
      last_minutes = (req_time.to_i - last_time.to_i).abs * INV_60
      last_km = last['km_from_current'].to_f
    else
      last_minutes = -1.0
      last_km = -1.0
    end

    [
      tx['amount'].to_f,
      tx['installments'].to_f,
      cust['avg_amount'].to_f,
      hour,
      ((req_time.wday + 6) % 7),
      last_minutes,
      last_km,
      term['km_from_home'].to_f,
      cust['tx_count_24h'].to_f,
      term['is_online'],
      term['card_present'],
      known_merchant?(cust['known_merchants'], merch['id']),
      @mcc_risk.fetch(merch['mcc'].to_s, 0.5),
      merch['avg_amount'].to_f
    ]
  end
end
