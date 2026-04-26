require 'json'
require 'zlib'
require 'numo/narray'

# Loads reference vectors and labels from disk. Prefers a Marshal cache
# to skip JSON parsing of 100k entries on every container start.
module References
  module_function

  def load(json_gz_path, cache_path)
    if cache_path && File.exist?(cache_path) && File.mtime(cache_path) >= File.mtime(json_gz_path)
      return load_cache(cache_path)
    end

    refs, labels = parse_json_gz(json_gz_path)
    save_cache(cache_path, refs, labels) if cache_path
    [refs, labels]
  end

  def parse_json_gz(path)
    raw = Zlib::GzipReader.open(path) { |gz| gz.read }
    entries = JSON.parse(raw)
    n = entries.size

    flat = Array.new(n * 14)
    labels = Numo::UInt8.zeros(n)

    entries.each_with_index do |e, i|
      v = e['vector']
      base = i * 14
      14.times { |k| flat[base + k] = v[k] }
      labels[i] = 1 if e['label'] == 'fraud'
    end

    refs = Numo::SFloat.cast(flat).reshape(n, 14)
    [refs, labels]
  end

  def save_cache(path, refs, labels)
    File.binwrite(path, Marshal.dump([refs, labels]))
  rescue StandardError
    # Cache is an optimization; ignore failures.
  end

  def load_cache(path)
    Marshal.load(File.binread(path))
  end
end
