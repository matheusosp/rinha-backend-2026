#!/usr/bin/env ruby
# Delegates to the Python training script.
# Kept for backward-compat; scripts/start.sh calls train_model.py directly now.

data_dir   = ENV.fetch('DATA_DIR', 'data')
model_path = File.join(data_dir, 'cache', 'rf_model.json')

if File.exist?(model_path)
  puts "[build_cache] RF model found (#{(File.size(model_path) / 1_048_576.0).round(2)} MB) — skipping."
  exit 0
end

puts "[build_cache] training RF model via Python..."
STDOUT.flush
exec "python3 scripts/train_model.py"
