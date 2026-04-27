require 'json'
require 'zlib'
require 'fileutils'
require 'numo/narray'

# Loads reference vectors and labels and builds (or loads) a binary cache
# for Numo::NArray BLAS operations. ‖r - q‖² = ‖r‖² + ‖q‖² - 2·r·q.
# Cache avoids JSON parse + normalization (~40s) on boot.
module References
  N_FEATURES = 14

  module_function

  def load(json_gz_path, cache_dir)
    refs_path   = File.join(cache_dir, 'refs.bin')
    norms_path  = File.join(cache_dir, 'r_norms.bin')
    labels_path = File.join(cache_dir, 'labels.bin')

    if [refs_path, norms_path, labels_path].all? { |f| File.exist?(f) }
      refs_bin = File.binread(refs_path)
      n        = refs_bin.bytesize / (N_FEATURES * 4) # 4 bytes per SFloat
      refs     = Numo::SFloat.from_binary(refs_bin).reshape(n, N_FEATURES)
      norms    = Numo::SFloat.from_binary(File.binread(norms_path))
      labels   = Numo::Int8.from_binary(File.binread(labels_path))
      return [refs, norms, labels]
    end

    raw     = Zlib::GzipReader.open(json_gz_path) { |gz| gz.read }
    entries = JSON.parse(raw)
    n       = entries.size

    refs   = Numo::SFloat.zeros(n, N_FEATURES)
    labels = Numo::Int8.zeros(n)

    entries.each_with_index do |e, i|
      refs[i, true] = e['vector']
      labels[i]     = (e['label'] == 'fraud' ? 1 : 0)
    end

    # r_norms = ‖r‖²
    norms = (refs**2).sum(axis: 1)

    FileUtils.mkdir_p(cache_dir)
    File.binwrite(refs_path,   refs.to_binary)
    File.binwrite(norms_path,  norms.to_binary)
    File.binwrite(labels_path, labels.to_binary)

    [refs, norms, labels]
  end
end
