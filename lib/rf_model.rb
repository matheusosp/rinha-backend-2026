require 'oj'

# Random Forest inference — pure Ruby, YJIT-friendly.
# Model is loaded from a JSON file produced by scripts/train_model.py.
#
# Memory layout per tree: 5 flat Ruby Arrays (no nested hashes in hot path):
#   f[node] = feature index (>= 0) or -1 (leaf)
#   t[node] = split threshold (float)
#   l[node] = left child node index
#   r[node] = right child node index
#   v[node] = P(fraud) at leaf (only relevant when f[node] == -1)
#
# predict_proba(vector) averages the leaf probability across all trees.
# Inference: O(depth * n_trees) — typically 800 ops, < 0.2ms with YJIT.
class RFModel
  attr_reader :threshold

  def initialize(path)
    data = Oj.load(File.read(path))
    @threshold   = data['threshold'].to_f
    @n_trees     = data['n_estimators'].to_i
    @inv_n_trees = 1.0 / @n_trees

    # Each element: [f_arr, t_arr, l_arr, r_arr, v_arr]
    # Kept as plain Ruby Arrays for YJIT inline-cache hits.
    @trees = data['trees'].map do |tr|
      [tr['f'], tr['t'], tr['l'], tr['r'], tr['v']]
    end
    @trees.freeze
  end

  # Returns P(fraud) in [0.0, 1.0].
  def predict_proba(vec)
    sum = 0.0
    @trees.each do |(f, t, l, r, v)|
      node = 0
      while f[node] >= 0
        node = vec[f[node]] <= t[node] ? l[node] : r[node]
      end
      sum += v[node]
    end
    sum * @inv_n_trees
  end
end
