#!/usr/bin/env ruby
# Builds the compact reference index used by the C/Spinel detector.
#
# The full reference file has 3M vectors. Pure legit/fraud traffic is decided by
# fast profile gates at runtime, so the native KNN only needs vectors in the
# overlapping borderline region plus nearby fraud-boundary vectors.

require 'fileutils'
require 'oj'
require 'zlib'

DATA_DIR = ENV.fetch('DATA_DIR', 'data')
REF_PATH = ENV.fetch('REFERENCES_PATH', File.join(DATA_DIR, 'references.json.gz'))
OUT_PATH = ENV.fetch('BORDER_INDEX_PATH', File.join(DATA_DIR, 'cache', 'border_index.bin'))
MAGIC = 'RB26IDX1'.b.freeze

def candidate_vector?(v)
  amount = v[0].to_f
  inst = v[1].to_f
  avg_ratio = v[2].to_f
  hour = v[3].to_f
  mins = v[5].to_f
  last_km = v[6].to_f
  km_home = v[7].to_f
  tx_count = v[8].to_f
  merchant_avg = v[13].to_f

  return false unless amount >= 0.038 && amount <= 0.305
  return false unless inst >= 0.249 && inst <= 0.585
  return false unless hour >= (5.9 / 23.0) && hour <= (22.1 / 23.0)
  return false unless avg_ratio >= 0.075 && avg_ratio <= 1.001
  return false unless tx_count >= 0.195 && tx_count <= 0.555
  return false unless merchant_avg >= 0.0018 && merchant_avg <= 0.0305
  return false unless km_home >= 0.028 && km_home <= 0.405

  return true if mins.negative? && last_km.negative?

  mins >= 0.0005 && mins <= 0.0835 && last_km >= 0.018 && last_km <= 0.305
end

FileUtils.mkdir_p(File.dirname(OUT_PATH))

puts "[border-index] loading #{REF_PATH}..."
refs = Oj.load(Zlib::GzipReader.open(REF_PATH, &:read))

count = 0
fraud_count = 0

File.open(OUT_PATH, 'wb') do |file|
  file.write(MAGIC)
  file.write([0].pack('L<'))

  refs.each do |entry|
    vector = entry.fetch('vector')
    next unless candidate_vector?(vector)

    fraud = entry.fetch('label') == 'fraud' ? 1 : 0
    file.write(vector.map(&:to_f).pack('e14'))
    file.write([fraud].pack('C'))

    count += 1
    fraud_count += fraud
  end

  file.seek(MAGIC.bytesize)
  file.write([count].pack('L<'))
end

size_mb = File.size(OUT_PATH) / 1_048_576.0
rate = count.positive? ? (100.0 * fraud_count / count) : 0.0
puts "[border-index] wrote #{OUT_PATH} count=#{count} fraud=#{fraud_count} fraud_rate=#{rate.round(2)}% size=#{size_mb.round(2)}MB"
