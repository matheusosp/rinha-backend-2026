require 'json'
require 'zlib'
require 'fileutils'
require 'hnswlib'
require 'numo/narray'

# Loads reference vectors and labels and builds (or loads) an HNSW index
# for fast K-NN queries. HNSW reduces search from O(N) to O(log N).
# Cache avoids JSON parse (~40s) on boot.
module References
  N_FEATURES = 14

  module_function

  def load(json_gz_path, cache_dir)
    index_path  = File.join(cache_dir, 'hnsw.idx')
    labels_path = File.join(cache_dir, 'labels.bin')

    if File.exist?(index_path) && File.exist?(labels_path)
      labels = Numo::Int8.from_binary(File.binread(labels_path))
      index = Hnswlib::HierarchicalNSW.new(space: 'l2', dim: N_FEATURES)
      index.load_index(index_path)
      index.set_ef(64)
      return [index, labels]
    end

    raw     = Zlib::GzipReader.open(json_gz_path) { |gz| gz.read }
    entries = JSON.parse(raw)
    n       = entries.size

    index = Hnswlib::HierarchicalNSW.new(space: 'l2', dim: N_FEATURES)
    index.init_index(max_elements: n, m: 16, ef_construction: 200)
    
    labels = Numo::Int8.zeros(n)

    entries.each_with_index do |e, i|
      index.add_point(e['vector'], i)
      labels[i] = (e['label'] == 'fraud' ? 1 : 0)
    end

    FileUtils.mkdir_p(cache_dir)
    index.save_index(index_path)
    File.binwrite(labels_path, labels.to_binary)

    index.set_ef(64)
    [index, labels]
  end
end
