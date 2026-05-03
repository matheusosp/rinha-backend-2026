$LOAD_PATH.unshift(File.expand_path('lib', __dir__ + '/..'))

require 'oj'
require 'references'

data_dir  = ENV.fetch('DATA_DIR', 'data')
cache_dir = File.join(data_dir, 'cache')
ref_file  = File.join(data_dir, 'references.json.gz')

m  = Integer(ENV.fetch('HNSW_M', '16'))
ec = Integer(ENV.fetch('HNSW_EF_CONSTRUCTION', '200'))
index_path  = File.join(cache_dir, "hnsw_m#{m}_ec#{ec}.idx")
labels_path = File.join(cache_dir, 'labels.bin')

if File.exist?(index_path) && File.exist?(labels_path)
  puts "[build_cache] cache ok: #{index_path} (#{(File.size(index_path) / 1_048_576.0).round(1)} MB)"
  exit 0
end

unless File.exist?(ref_file)
  abort "[build_cache] ERROR: #{ref_file} not found. Run scripts/fetch-data.sh first."
end

puts "[build_cache] building HNSW index from #{ref_file}"
puts "[build_cache] params: M=#{m}, ef_construction=#{ec}"
puts "[build_cache] this may take several minutes for 3M vectors..."
STDOUT.flush

t = Time.now
_idx, labels = References.load(ref_file, cache_dir)
elapsed = (Time.now - t).round(1)

puts "[build_cache] done in #{elapsed}s — #{labels.size} vectors indexed"
puts "[build_cache] index: #{(File.size(index_path) / 1_048_576.0).round(1)} MB"
STDOUT.flush
