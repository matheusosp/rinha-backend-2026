#!/usr/bin/env ruby

data_dir = ENV.fetch('DATA_DIR', 'data')
index_path = File.join(data_dir, 'cache', 'border_index.bin')

if File.exist?(index_path)
  size = File.size(index_path) / 1_048_576.0
  puts "[build_cache] border index found (#{size.round(2)} MB) - skipping."
  exit 0
end

puts '[build_cache] building border index with Ruby...'
STDOUT.flush
exec({ 'DATA_DIR' => data_dir }, 'bundle', 'exec', 'ruby', 'scripts/build_border_index.rb')
