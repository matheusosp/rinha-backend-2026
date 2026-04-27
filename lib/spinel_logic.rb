class SpinelLogic
  def initialize(labels, mcc_risk, max_amount, max_inst, avg_ratio_limit, max_min, max_km, max_tx, max_m_avg)
    @labels = labels
    @mcc_risk = mcc_risk
    @max_amount = max_amount
    @max_inst = max_inst
    @avg_ratio_limit = avg_ratio_limit
    @max_min = max_min
    @max_km = max_km
    @max_tx = max_tx
    @max_m_avg = max_m_avg

    @inv_max_amount = 1.0 / (max_amount > 0.0 ? max_amount : 1.0)
    @inv_max_inst = 1.0 / (max_inst > 0.0 ? max_inst : 1.0)
    @inv_avg_ratio_limit = 1.0 / (avg_ratio_limit > 0.0 ? avg_ratio_limit : 1.0)
    @inv_max_min = 1.0 / (max_min > 0.0 ? max_min : 1.0)
    @inv_max_km = 1.0 / (max_km > 0.0 ? max_km : 1.0)
    @inv_max_tx = 1.0 / (max_tx > 0.0 ? max_tx : 1.0)
    @inv_max_m_avg = 1.0 / (max_m_avg > 0.0 ? max_m_avg : 1.0)
  end

  def build_vector(amount, inst, cust_avg, hour, wday, last_tx_mins, last_tx_km, km_home, tx_c, is_online, card_present, known_merch, mcc, m_avg)
    avg_ratio = cust_avg > 0.0 ? (amount / cust_avg) * @inv_avg_ratio_limit : 1.0
    
    v = Array.new(14, 0.0)
    v[0] = amount > @max_amount ? 1.0 : amount * @inv_max_amount
    v[1] = inst > @max_inst ? 1.0 : inst * @inv_max_inst
    v[2] = avg_ratio > 1.0 ? 1.0 : (avg_ratio < 0.0 ? 0.0 : avg_ratio)
    v[3] = hour.to_f * (1.0 / 23.0)
    v[4] = wday.to_f * (1.0 / 6.0)
    
    if last_tx_mins >= 0.0
      v[5] = last_tx_mins > @max_min ? 1.0 : last_tx_mins * @inv_max_min
      v[6] = last_tx_km > @max_km ? 1.0 : last_tx_km * @inv_max_km
    else
      v[5] = -1.0
      v[6] = -1.0
    end

    v[7] = km_home > @max_km ? 1.0 : km_home * @inv_max_km
    v[8] = tx_c > @max_tx ? 1.0 : tx_c * @inv_max_tx
    v[9] = is_online ? 1.0 : 0.0
    v[10] = card_present ? 1.0 : 0.0
    v[11] = known_merch ? 0.0 : 1.0
    
    risk_int = @mcc_risk[mcc]
    v[12] = risk_int > 0 ? risk_int.to_f * 0.001 : 0.5
    
    v[13] = m_avg > @max_m_avg ? 1.0 : m_avg * @inv_max_m_avg
    v
  end

  def calculate_score(indices)
    frauds = 0
    i = 0
    len = indices.length
    while i < len
      frauds += @labels[indices[i]]
      i += 1
    end
    frauds.to_f / len.to_f
  end
end

labels = [0]
mcc_risk = { "5411" => 150 }
obj = SpinelLogic.new(labels, mcc_risk, 10000.0, 12.0, 10.0, 1440.0, 1000.0, 20.0, 10000.0)
obj.build_vector(100.0, 1.0, 50.0, 12, 1, 10.0, 1.0, 5.0, 1.0, true, true, true, "5411", 100.0)
obj.calculate_score([0])
