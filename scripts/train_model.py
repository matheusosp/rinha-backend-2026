#!/usr/bin/env python3
"""
Train a Random Forest classifier on the 3M reference vectors.

Output: data/cache/rf_model.json
  - 200 trees, max_depth=8, min_samples_leaf=200
  - class_weight {legit:1, fraud:3} mirrors Rinha FN penalty (FN costs 3×, errors 5×)
  - Threshold optimised on a held-out 20% validation split
  - Model fits easily in ~30MB Ruby heap (150MB Docker limit per instance)
"""
import gzip, json, os, time, math
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split

DATA_DIR  = os.environ.get('DATA_DIR', 'data')
REF_PATH  = os.path.join(DATA_DIR, 'references.json.gz')
OUT_DIR   = os.path.join(DATA_DIR, 'cache')
OUT_PATH  = os.path.join(OUT_DIR, 'rf_model.json')

SEED           = 42
N_ESTIMATORS   = 200
MAX_DEPTH      = 8
MIN_LEAF       = 200    # less aggressive pruning → better boundaries
MAX_FEATURES   = 'sqrt' # ~4 of 14 features per split
FN_WEIGHT      = 3      # FN costs 3× in Rinha (errors 5×, avoid them!)
VAL_FRAC       = 0.20   # held-out fraction for threshold search

t0 = time.time()

# ── Load ─────────────────────────────────────────────────────────────────────
print(f"[train] loading {REF_PATH}...", flush=True)
with gzip.open(REF_PATH, 'rt', encoding='utf-8') as f:
    entries = json.load(f)

n = len(entries)
print(f"[train] {n} samples", flush=True)

X = np.array([e['vector'] for e in entries], dtype=np.float32)
y = np.array([1 if e['label'] == 'fraud' else 0 for e in entries], dtype=np.int8)
del entries

fraud_n = int(y.sum())
legit_n = n - fraud_n
print(f"[train] fraud={fraud_n} ({100*fraud_n/n:.1f}%)  legit={legit_n}", flush=True)

# ── Train/validation split ────────────────────────────────────────────────────
X_tr, X_val, y_tr, y_val = train_test_split(
    X, y, test_size=VAL_FRAC, random_state=SEED, stratify=y
)
print(f"[train] train={len(y_tr)}  val={len(y_val)}", flush=True)

# ── Train ─────────────────────────────────────────────────────────────────────
print(f"[train] fitting RF n={N_ESTIMATORS} depth={MAX_DEPTH} min_leaf={MIN_LEAF} ...", flush=True)
clf = RandomForestClassifier(
    n_estimators     = N_ESTIMATORS,
    max_depth        = MAX_DEPTH,
    min_samples_leaf = MIN_LEAF,
    max_features     = MAX_FEATURES,
    class_weight     = {0: 1, 1: FN_WEIGHT},
    n_jobs           = -1,
    random_state     = SEED,
    verbose          = 0,
)
clf.fit(X_tr, y_tr)
print(f"[train] fitted in {time.time()-t0:.1f}s", flush=True)

# ── Optimal threshold on held-out validation set ──────────────────────────────
proba_val = clf.predict_proba(X_val)[:, 1]  # P(fraud)

best_t, best_cost = 0.5, float('inf')
for t in np.arange(0.05, 0.80, 0.005):
    pred = (proba_val >= t).astype(np.int8)
    fn   = int(((pred == 0) & (y_val == 1)).sum())
    fp   = int(((pred == 1) & (y_val == 0)).sum())
    cost = FN_WEIGHT * fn + fp
    if cost < best_cost:
        best_cost = cost
        best_t    = float(t)

best_t = round(best_t, 3)
print(f"[train] optimal threshold={best_t:.3f}  cost(3FN+FP)={best_cost}", flush=True)

# Accuracy report on validation set
pred_v = (proba_val >= best_t).astype(np.int8)
tp = int(((pred_v == 1) & (y_val == 1)).sum())
tn = int(((pred_v == 0) & (y_val == 0)).sum())
fp = int(((pred_v == 1) & (y_val == 0)).sum())
fn = int(((pred_v == 0) & (y_val == 1)).sum())
total_v = len(y_val)

E       = fp + FN_WEIGHT * fn
epsilon = E / total_v
r_comp  = 1000 * math.log10(1.0 / max(epsilon, 0.001))
abs_pen = -300 * math.log10(1 + E)
det     = r_comp + abs_pen

print(f"[train] val  TP={tp} TN={tn} FP={fp} FN={fn}", flush=True)
print(f"[train] accuracy={100*(tp+tn)/total_v:.2f}%  FNR={100*fn/(tp+fn+1e-9):.3f}%  FPR={100*fp/(tn+fp+1e-9):.3f}%", flush=True)
print(f"[train] E={E}  epsilon={epsilon:.5f}  det_score_est={det:.1f}", flush=True)

# ── Export trees ──────────────────────────────────────────────────────────────
print("[train] exporting trees...", flush=True)

def export_tree(tree):
    features   = tree.feature.tolist()
    thresholds = tree.threshold.tolist()
    lefts      = tree.children_left.tolist()
    rights     = tree.children_right.tolist()
    vals       = tree.value[:, 0, :]            # (n_nodes, n_classes)
    totals     = vals.sum(axis=1)
    proba      = np.where(totals > 0, vals[:, 1] / totals, 0.0)
    # Convert sklearn TREE_UNDEFINED (-2) to -1 so Ruby uses `f[node] >= 0` check
    features = [-1 if f < 0 else f for f in features]
    return {
        'f': features,
        't': [round(float(x), 6) for x in thresholds],
        'l': lefts,
        'r': rights,
        'v': [round(float(x), 6) for x in proba.tolist()],
    }

trees_out   = [export_tree(est.tree_) for est in clf.estimators_]
total_nodes = sum(len(t['f']) for t in trees_out)
print(f"[train] {total_nodes} total nodes across {N_ESTIMATORS} trees (avg {total_nodes//N_ESTIMATORS}/tree)", flush=True)

model = {
    'threshold':    best_t,
    'n_estimators': N_ESTIMATORS,
    'trees':        trees_out,
}

os.makedirs(OUT_DIR, exist_ok=True)
with open(OUT_PATH, 'w') as f:
    json.dump(model, f, separators=(',', ':'))

sz = os.path.getsize(OUT_PATH)
print(f"[train] saved {OUT_PATH}  ({sz/1024/1024:.2f} MB)  total={time.time()-t0:.1f}s", flush=True)
