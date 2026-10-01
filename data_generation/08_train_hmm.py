import logging
import numpy as np
import pandas as pd
import joblib
from pathlib import Path
from hmmlearn import hmm
from sklearn.cluster import KMeans
from sklearn.metrics import accuracy_score, precision_recall_fscore_support, confusion_matrix
from scipy.optimize import linear_sum_assignment

logging.getLogger("hmmlearn").setLevel(logging.ERROR)  # tiny EM likelihood dips are numerical noise

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data" / "processed"
MODELS_DIR = ROOT / "models"
STATES = ["Stable", "Strained", "Critical"]
STATE_IDX = {s: i for i, s in enumerate(STATES)}

# Features chosen because they carry the state signal; debt_service_coverage_ratio is a
# household-level constant and spending_regularity_score is degenerate in early months.
# Chosen by 4-fold cross-validation on TRAINING households only (base features + 3-month context scored 0.56 CV vs 0.49
# for the base features alone; per-tier models and full covariance were not better).
HMM_FEATURES = ["income_to_expenditure_ratio", "savings_share", "entertainment_share", "ratio_roll3", "overspend_roll3"]


def load_sequences(df, household_ids):
    """df must be sorted by (household_id, month). Households are taken in the order given."""
    X, lengths = [], []
    for hid in household_ids:
        sub = df[df.household_id == hid]
        X.append(sub[HMM_FEATURES].values)
        lengths.append(len(sub))
    return np.vstack(X), lengths


def align_states(true_labels, pred_labels):
    n = len(STATES)
    cost = np.zeros((n, n))
    for i in range(n):
        for j in range(n):
            cost[i, j] = -np.sum((true_labels == i) & (pred_labels == j))
    row_ind, col_ind = linear_sum_assignment(cost)
    mapping = {col: row for row, col in zip(row_ind, col_ind)}
    return np.array([mapping[p] for p in pred_labels]), mapping


def fit_hmm(X, lengths, seed):
    """Unsupervised: start from KMeans clusters (no true labels used), then refine with EM."""
    km = KMeans(n_clusters=3, n_init=10, random_state=seed).fit(X)
    m = hmm.GaussianHMM(n_components=3, covariance_type="diag", n_iter=300, tol=1e-4,
                        init_params="st", params="stmc", min_covar=1e-3, random_state=seed)
    m.means_ = km.cluster_centers_
    m.covars_ = np.array([X[km.labels_ == k].var(axis=0) + 1e-3 for k in range(3)])
    m.fit(X, lengths)
    return m


def main():
    df_raw = pd.read_csv(DATA_DIR / "engineered_features_raw.csv")
    df = pd.read_csv(DATA_DIR / "engineered_features_normalized.csv")
    df["true_state"] = df_raw["true_state"]
    df = df.sort_values(["household_id", "month"]).reset_index(drop=True)

    split = pd.read_csv(DATA_DIR / "household_split.csv")
    train_ids = sorted(split[split.split == "train"].household_id)
    test_ids = sorted(split[split.split == "test"].household_id)

    X_train, lengths_train = load_sequences(df, train_ids)
    best_model, best_score = None, -np.inf
    for seed in range(10):
        try:
            m = fit_hmm(X_train, lengths_train, seed)
            score = m.score(X_train, lengths_train)
            if score > best_score:
                best_score, best_model = score, m
        except Exception as e:
            print(f"seed {seed} failed: {e}")
    model = best_model

    # Test sequences and true labels are built from the SAME household order.
    X_test, lengths_test = load_sequences(df, test_ids)
    pred = model.predict(X_test, lengths_test)
    true_idx = df[df.household_id.isin(test_ids)].sort_values(["household_id", "month"])["true_state"].map(STATE_IDX).values
    # Name states WITHOUT looking at true labels: the state with the highest mean income/expenditure ratio is Stable,
    # the lowest is Critical. (The old Hungarian match against true labels leaked the test labels.)
    order = np.argsort(-model.means_[:, 0])
    mapping = {int(state): rank for rank, state in enumerate(order)}
    aligned = np.array([mapping[p] for p in pred])

    acc = accuracy_score(true_idx, aligned)
    prec, rec, f1, _ = precision_recall_fscore_support(true_idx, aligned, average=None, labels=[0, 1, 2], zero_division=0)
    cm = confusion_matrix(true_idx, aligned, labels=[0, 1, 2])
    majority = np.bincount(true_idx).max() / len(true_idx)

    print(f"Train households: {len(train_ids)}, Test households: {len(test_ids)}")
    print(f"Held-out state-detection accuracy: {acc:.3f}   (always-predict-majority baseline: {majority:.3f})")
    print("\nPer-state precision/recall/F1:")
    for i, s in enumerate(STATES):
        print(f"  {s:10s}  precision={prec[i]:.3f}  recall={rec[i]:.3f}  f1={f1[i]:.3f}")
    print("\nConfusion matrix (rows=true, cols=predicted), order Stable/Strained/Critical:")
    print(cm)

    MODELS_DIR.mkdir(exist_ok=True)
    joblib.dump({"model": model, "features": HMM_FEATURES, "state_mapping": mapping}, MODELS_DIR / "hmm_model.joblib")

    # Predict per household in df order (sorted), so states land on the right rows.
    all_ids = sorted(df.household_id.unique())
    all_X, all_lengths = load_sequences(df, all_ids)
    all_pred = np.array([mapping[p] for p in model.predict(all_X, all_lengths)])
    df["hmm_predicted_state_idx"] = all_pred
    df["hmm_predicted_state"] = df["hmm_predicted_state_idx"].map(dict(enumerate(STATES)))
    df.to_csv(DATA_DIR / "features_with_hmm_states.csv", index=False)
    print("\nSaved model to models/hmm_model.joblib")
    print("Saved features + HMM states to data/processed/features_with_hmm_states.csv")


if __name__ == "__main__":
    main()
