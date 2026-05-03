require 'json'
require 'time'
require 'rf_model'

# Fraud detector backed by a pre-trained Random Forest (lib/rf_model.rb).
#
# Memory: ~15 MB for the model (vs 930 MB HNSW for 3M vectors).
# Latency: ~0.2 ms per prediction (vs ~50 ms HNSW) — easily meets P99 < 10 ms.
class Detector
  EPOCH       = Time.at(0).utc.freeze
  EMPTY_HASH  = {}.freeze

  HOUR_MUL = 1.0 / 23.0
  WDAY_MUL = 1.0 / 6.0
  INV_60   = 1.0 / 60.0

  def initialize(data_dir:)
    norm = Oj.load(File.read(File.join(data_dir, 'normalization.json')))
    @max_amount          = norm.fetch('max_amount').to_f
    @max_installments    = norm.fetch('max_installments').to_f
    @amount_vs_avg_ratio = norm.fetch('amount_vs_avg_ratio').to_f
    @max_minutes         = norm.fetch('max_minutes').to_f
    @max_km              = norm.fetch('max_km').to_f
    @max_tx_count_24h    = norm.fetch('max_tx_count_24h').to_f
    @max_merchant_avg    = norm.fetch('max_merchant_avg_amount').to_f

    @inv_max_amount          = 1.0 / (@max_amount          > 0 ? @max_amount          : 1.0)
    @inv_max_installments    = 1.0 / (@max_installments    > 0 ? @max_installments    : 1.0)
    @inv_amount_vs_avg_ratio = 1.0 / (@amount_vs_avg_ratio > 0 ? @amount_vs_avg_ratio : 1.0)
    @inv_max_minutes         = 1.0 / (@max_minutes         > 0 ? @max_minutes         : 1.0)
    @inv_max_km              = 1.0 / (@max_km              > 0 ? @max_km              : 1.0)
    @inv_max_tx_count_24h    = 1.0 / (@max_tx_count_24h    > 0 ? @max_tx_count_24h    : 1.0)
    @inv_max_merchant_avg    = 1.0 / (@max_merchant_avg    > 0 ? @max_merchant_avg    : 1.0)

    @mcc_risk = Oj.load(File.read(File.join(data_dir, 'mcc_risk.json')))
    @mcc_risk.transform_values!(&:to_f)
    @mcc_risk.default = 0.5

    model_path = File.join(data_dir, 'cache', 'rf_model.json')
    @model = RFModel.new(model_path)

    # Allow ENV override; otherwise use threshold tuned during training.
    env_t = ENV['FRAUD_SCORE_THRESHOLD']
    @threshold = env_t ? env_t.to_f : @model.threshold
  end

  def score(req)
    vec = build_vector(req)
    s   = @model.predict_proba(vec)
    [s < @threshold, s]
  end

  private

  def build_vector(req)
    tx     = req['transaction']  || EMPTY_HASH
    cust   = req['customer']     || EMPTY_HASH
    merch  = req['merchant']     || EMPTY_HASH
    term   = req['terminal']     || EMPTY_HASH
    last   = req['last_transaction']

    t_str = tx['requested_at']
    t = if t_str && t_str.length >= 19
          Time.utc(t_str[0,4].to_i, t_str[5,2].to_i, t_str[8,2].to_i,
                   t_str[11,2].to_i, t_str[14,2].to_i, t_str[17,2].to_i)
        else
          EPOCH
        end

    amount = tx['amount'].to_f
    inst   = tx['installments'].to_f

    cust_avg  = cust['avg_amount'].to_f
    avg_ratio = if cust_avg > 0
                  (amount / cust_avg) * @inv_amount_vs_avg_ratio
                else
                  1.0
                end

    if last
      ta_str = last['timestamp']
      ta = if ta_str && ta_str.length >= 19
             Time.utc(ta_str[0,4].to_i, ta_str[5,2].to_i, ta_str[8,2].to_i,
                      ta_str[11,2].to_i, ta_str[14,2].to_i, ta_str[17,2].to_i)
           else
             EPOCH
           end
      mins = (t.to_i - ta.to_i).abs * INV_60
      d5 = mins > @max_minutes ? 1.0 : mins * @inv_max_minutes
      km = last['km_from_current'].to_f
      d6 = km > @max_km ? 1.0 : km * @inv_max_km
    else
      d5 = -1.0
      d6 = -1.0
    end

    km_home = term['km_from_home'].to_f
    tx_c    = cust['tx_count_24h'].to_f
    known   = cust['known_merchants']
    mcc     = merch['mcc']

    [
      amount > @max_amount ? 1.0 : amount * @inv_max_amount,
      inst   > @max_installments ? 1.0 : inst * @inv_max_installments,
      avg_ratio > 1.0 ? 1.0 : (avg_ratio < 0 ? 0.0 : avg_ratio),
      t.hour * HOUR_MUL,
      ((t.wday + 6) % 7) * WDAY_MUL,
      d5,
      d6,
      km_home > @max_km ? 1.0 : km_home * @inv_max_km,
      tx_c > @max_tx_count_24h ? 1.0 : tx_c * @inv_max_tx_count_24h,
      term['is_online']    ? 1.0 : 0.0,
      term['card_present'] ? 1.0 : 0.0,
      (known && known.include?(merch['id'])) ? 0.0 : 1.0,
      @mcc_risk[mcc],
      (m_avg = merch['avg_amount'].to_f) > @max_merchant_avg ? 1.0 : m_avg * @inv_max_merchant_avg,
    ]
  end
end
