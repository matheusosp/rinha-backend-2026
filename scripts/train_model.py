#!/usr/bin/env python3
"""
Train a Random Forest classifier that directly approximates the Rinha KNN oracle.

Key insight: The Rinha test scores predictions using EXACT 5-NN KNN on 3M reference
vectors. Training on raw labels (fraud/legit per vector) leads to ~2.5% FNR because
some transactions look 'legit' in feature space but sit near fraud clusters.

This script computes KNN-derived labels for 150K training samples using FAISS
(exact brute-force on all 3M reference vectors) and trains the RF on those labels.
The RF then directly learns where the KNN decision boundary is.

Feature engineering (17D from original 14D):
  0-13: original features (amount_norm, inst_norm, amount_ratio, hour, wday,
        mins_since_last, km_from_last, km_home, tx_24h, is_online, card_present,
        unknown_merch, mcc_risk, merch_avg_norm)
  14: amount / merchant_avg ratio (normalized by 100)  -- fraud~82×, FP~9.6×
  15: (1 - card_present) * amount_norm                 -- card-absent high-value
  16: travel speed in km/h (normalized by 900)         -- impossible travel signal

Output: data/cache/rf_model.json
"""
import gzip, json, os, sys, time, math
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split

DATA_DIR = os.environ.get('DATA_DIR', 'data')
REF_PATH = os.path.join(DATA_DIR, 'references.json.gz')
OUT_DIR  = os.path.join(DATA_DIR, 'cache')
OUT_PATH = os.path.join(OUT_DIR, 'rf_model.json')

SEED         = 42
N_ESTIMATORS = 200   # 200 trees: good accuracy, FAISS labels compensate for fewer trees
MAX_DEPTH    = 8     # depth 8: keeps model small (~100K nodes vs 600K at depth 10)
MIN_LEAF     = 100   # finer splits than default
MAX_FEATURES = 'sqrt'
FN_WEIGHT    = 3
VAL_FRAC     = 0.20
N_KNN        = 150_000   # vectors to compute KNN labels for

# Derived-feature normalization constants (must match lib/detector.rb)
MAX_MERCH_RATIO = 100.0
MAX_SPEED_KMH   = 900.0

t0 = time.time()

# ── Load normalization constants ───────────────────────────────────────────────
norm_data = json.load(open(os.path.join(DATA_DIR, 'normalization.json')))
MAX_KM        = float(norm_data['max_km'])
MAX_MINUTES   = float(norm_data['max_minutes'])
MAX_AMOUNT    = float(norm_data['max_amount'])
MAX_MERCH_AVG = float(norm_data['max_merchant_avg_amount'])

# ── Load all reference vectors ─────────────────────────────────────────────────
print(f"[train] loading {REF_PATH}...", flush=True)
with gzip.open(REF_PATH, 'rt', encoding='utf-8') as f:
    entries = json.load(f)

n = len(entries)
print(f"[train] {n} samples", flush=True)

X = np.array([e['vector'] for e in entries], dtype=np.float32)  # (3M, 14)
y = np.array([1 if e['label'] == 'fraud' else 0 for e in entries], dtype=np.int8)
del entries

fraud_n = int(y.sum())
print(f"[train] fraud={fraud_n} ({100*fraud_n/n:.1f}%)  legit={n-fraud_n}", flush=True)


def add_derived_features(X14):
    """Augment 14D vectors with 3 derived features → 17D.

    All features are derivable from the 14D vector + normalization constants,
    so they can be computed both at inference time (Ruby) and training time (here).

    Feature 14: amount / merchant_avg ratio (normalized by MAX_MERCH_RATIO=100)
      - Computed as X[:,0]/X[:,13] since both share the same max (the 10K cancels)
      - Fraud ~82×, FP ~9.6×, legit ~1× → strong separator

    Feature 15: (1 - card_present) * amount_norm
      - High-value card-absent transactions are predominantly fraud
      - FP mean = 0.089, Fraud mean = 0.468 (5× difference)

    Feature 16: travel speed (km/h, normalized by MAX_SPEED_KMH=900)
      - FP p50=157 km/h, legit p50=1.6 km/h (RF cannot directly learn km/mins ratio)
      - Only set when last_transaction exists (feature[5] > 0 and feature[6] > 0)
    """
    n = len(X14)
    extras = np.zeros((n, 3), dtype=np.float32)

    # Feature 14: amount/merchant_avg ratio
    # Both normalized by same max (10K) so ratio cancels normalization
    merch_f = np.maximum(X14[:, 13], 1e-6)
    extras[:, 0] = np.minimum(X14[:, 0] / (merch_f * MAX_MERCH_RATIO), 1.0)

    # Feature 15: (1 - card_present) * amount_norm
    extras[:, 1] = (1.0 - X14[:, 10]) * X14[:, 0]

    # Feature 16: travel speed (km/h normalized)
    has_last   = (X14[:, 5] > 0) & (X14[:, 6] > 0)
    km         = X14[:, 6] * MAX_KM
    minutes    = np.maximum(X14[:, 5] * MAX_MINUTES, 0.001)
    speed_kmh  = km * 60.0 / minutes
    extras[:, 2] = np.where(has_last,
                            np.minimum(speed_kmh / MAX_SPEED_KMH, 1.0),
                            0.0)

    return np.hstack([X14, extras]).astype(np.float32)


# ── KNN label computation ─────────────────────────────────────────────────────
# For each of N_KNN sampled vectors, compute its exact 5-NN in the FULL 3M set
# (leave-one-out), then assign label: fraud if fraud_count >= 3 among 5 nearest.
# KNN uses the ORIGINAL 14D features (same as the Rinha oracle).
print(f"[knn] sampling {N_KNN} vectors for KNN labeling...", flush=True)
rng = np.random.default_rng(SEED)
knn_idx = rng.choice(n, size=N_KNN, replace=False)
X_knn   = X[knn_idx]   # (150K, 14) — queries (original 14D for KNN)

knn_labels_ok = False

# ── Path A: FAISS (fast, exact, preferred in Docker build) ─────────────────────
try:
    import faiss
    print("[knn] FAISS available — exact IndexFlatL2 on 3M vectors", flush=True)
    t_knn = time.time()
    index = faiss.IndexFlatL2(X.shape[1])
    faiss.omp_set_num_threads(os.cpu_count() or 4)
    index.add(X)                                    # add all 3M
    _, I = index.search(X_knn, 6)                  # (150K, 6) nearest
    del index
    print(f"[knn] FAISS search done in {time.time()-t_knn:.1f}s", flush=True)
    knn_labels_ok = True

# ── Path B: sklearn BallTree on the 150K set itself (fast fallback, ~40s) ──────
except ImportError:
    print("[knn] FAISS not available — BallTree leave-one-out on 150K subset", flush=True)
    from sklearn.neighbors import NearestNeighbors
    t_knn = time.time()
    nn = NearestNeighbors(n_neighbors=6, algorithm='ball_tree',
                          leaf_size=40, n_jobs=-1)
    nn.fit(X_knn)                                   # build on 150K
    _, I_local = nn.kneighbors(X_knn)              # (150K, 6) — self is index 0
    del nn
    # Map local BallTree indices back to global 3M indices
    I = knn_idx[I_local]                            # (150K, 6) global indices
    print(f"[knn] BallTree done in {time.time()-t_knn:.1f}s", flush=True)
    knn_labels_ok = True

if knn_labels_ok:
    # Assign KNN labels: exclude self, count fraud among 5 nearest neighbors
    y_knn = np.zeros(N_KNN, dtype=np.int8)
    for i in range(N_KNN):
        orig      = knn_idx[i]
        neighbors = I[i]
        valid     = neighbors[neighbors != orig][:5]
        y_knn[i]  = 1 if int(y[valid].sum()) >= 3 else 0

    raw_fraud = int(y[knn_idx].sum())
    knn_fraud = int(y_knn.sum())
    diff      = int((y[knn_idx] != y_knn).sum())
    print(f"[knn] raw_fraud={raw_fraud} ({100*raw_fraud/N_KNN:.1f}%)  "
          f"knn_fraud={knn_fraud} ({100*knn_fraud/N_KNN:.1f}%)  "
          f"label_changes={diff} ({100*diff/N_KNN:.2f}%)", flush=True)

    X_train_data, y_train_data = X_knn, y_knn
    print(f"[train] using KNN labels — {N_KNN} samples", flush=True)
else:
    # Last-resort fallback: raw labels on full set
    print("[train] WARNING: falling back to raw labels on full dataset", flush=True)
    X_train_data, y_train_data = X, y

# ── Augment training vectors with derived features (14D → 17D) ────────────────
print("[train] augmenting vectors: 14D → 17D "
      "(amount/merch_ratio, no_card×amount, speed)...", flush=True)
X_train_aug = add_derived_features(X_train_data)
print(f"[train] feature shape: {X_train_aug.shape}", flush=True)

# ── Train/validation split ────────────────────────────────────────────────────
X_tr, X_val, y_tr, y_val = train_test_split(
    X_train_aug, y_train_data,
    test_size=VAL_FRAC, random_state=SEED, stratify=y_train_data
)
print(f"[train] train={len(y_tr)}  val={len(y_val)}  "
      f"fraud_train={y_tr.sum()} ({100*y_tr.mean():.1f}%)", flush=True)

# ── Fit Random Forest ─────────────────────────────────────────────────────────
print(f"[train] fitting RF  n={N_ESTIMATORS}  depth={MAX_DEPTH}  "
      f"min_leaf={MIN_LEAF}  features={MAX_FEATURES}  n_features=17...", flush=True)
clf = RandomForestClassifier(
    n_estimators     = N_ESTIMATORS,
    max_depth        = MAX_DEPTH,
    min_samples_leaf = MIN_LEAF,
    max_features     = MAX_FEATURES,
    class_weight     = {0: 1, 1: FN_WEIGHT},
    n_jobs           = -1,
    random_state     = SEED,
)
clf.fit(X_tr, y_tr)
print(f"[train] fitted in {time.time()-t0:.1f}s", flush=True)

# ── Optimal threshold on KNN-labelled validation set ─────────────────────────
proba_val = clf.predict_proba(X_val)[:, 1]

best_t, best_cost = 0.05, float('inf')
for t in np.arange(0.005, 0.80, 0.005):
    pred = (proba_val >= t).astype(np.int8)
    fn   = int(((pred == 0) & (y_val == 1)).sum())
    fp   = int(((pred == 1) & (y_val == 0)).sum())
    cost = FN_WEIGHT * fn + fp
    if cost < best_cost:
        best_cost = cost
        best_t    = round(float(t), 3)

# Push threshold into the flat-minimum region (FP stays constant while FNR=0).
# Scanning upward from best_t: accept any t that keeps cost <= best_cost.
for t in np.arange(best_t + 0.005, 0.60, 0.005):
    pred = (proba_val >= t).astype(np.int8)
    fn   = int(((pred == 0) & (y_val == 1)).sum())
    fp   = int(((pred == 1) & (y_val == 0)).sum())
    cost = FN_WEIGHT * fn + fp
    if cost <= best_cost:
        best_t = round(float(t), 3)
    else:
        break

print(f"[train] optimal threshold={best_t:.3f}  cost(3FN+FP)={best_cost}", flush=True)

pred_v = (proba_val >= best_t).astype(np.int8)
tp = int(((pred_v == 1) & (y_val == 1)).sum())
tn = int(((pred_v == 0) & (y_val == 0)).sum())
fp = int(((pred_v == 1) & (y_val == 0)).sum())
fn = int(((pred_v == 0) & (y_val == 1)).sum())

E       = fp + FN_WEIGHT * fn
epsilon = E / max(len(y_val), 1)
det     = 1000 * math.log10(1.0 / max(epsilon, 0.001)) - 300 * math.log10(1 + E)
print(f"[train] val  TP={tp}  TN={tn}  FP={fp}  FN={fn}", flush=True)
print(f"[train] FNR={100*fn/(tp+fn+1e-9):.3f}%  FPR={100*fp/(tn+fp+1e-9):.3f}%  "
      f"E={E}  det_score_est={det:.1f}", flush=True)

total_nodes = sum(e.tree_.node_count for e in clf.estimators_)
print(f"[train] {total_nodes} nodes across {N_ESTIMATORS} trees "
      f"({total_nodes//N_ESTIMATORS}/tree avg)", flush=True)

# ── Export trees ──────────────────────────────────────────────────────────────
print("[train] exporting trees...", flush=True)

def export_tree(tree):
    features   = [-1 if f < 0 else f for f in tree.feature.tolist()]
    thresholds = tree.threshold.tolist()
    lefts      = tree.children_left.tolist()
    rights     = tree.children_right.tolist()
    vals       = tree.value[:, 0, :]
    totals     = vals.sum(axis=1)
    proba      = np.where(totals > 0, vals[:, 1] / totals, 0.0)
    return {
        'f': features,
        't': [round(float(x), 6) for x in thresholds],
        'l': lefts,
        'r': rights,
        'v': [round(float(x), 6) for x in proba.tolist()],
    }

trees_out = [export_tree(e.tree_) for e in clf.estimators_]

model = {
    'threshold':    best_t,
    'n_estimators': N_ESTIMATORS,
    'trees':        trees_out,
}

os.makedirs(OUT_DIR, exist_ok=True)
with open(OUT_PATH, 'w') as f:
    json.dump(model, f, separators=(',', ':'))

sz = os.path.getsize(OUT_PATH)
print(f"[train] saved {OUT_PATH}  ({sz/1024/1024:.2f} MB)  "
      f"total_time={time.time()-t0:.1f}s", flush=True)
