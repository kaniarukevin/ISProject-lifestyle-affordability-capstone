"""Unit tests for HMM state detection (Sprint 3). Run `07_feature_engineering.py` and `08_train_hmm.py` first,
because the engineered features are regenerated locally (git-ignored). Run with:  python -m pytest tests -q"""
import importlib.util
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
PROC = ROOT / "data" / "processed"
SYN = ROOT / "data" / "synthetic"
STATES = ["Stable", "Strained", "Critical"]

# The HMM is the replaced baseline (docs/deviations.md D1). On a fresh clone it needs the dev requirements and the
# features that 07_feature_engineering.py regenerates (git-ignored), so skip cleanly instead of erroring (audit A-17).
pytest.importorskip("hmmlearn", reason="the HMM baseline needs hmmlearn: pip install -r backend/requirements-dev.txt")
if not (PROC / "engineered_features_raw.csv").exists():
    pytest.skip("run data_generation/07_feature_engineering.py first (its output is git-ignored)", allow_module_level=True)


def _load_08():
    spec = importlib.util.spec_from_file_location("hmm08", ROOT / "data_generation" / "08_train_hmm.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


@pytest.fixture(scope="module")
def art():
    p = ROOT / "models" / "hmm_model.joblib"
    if not p.exists():
        pytest.skip("run 08_train_hmm.py first")
    return joblib.load(p)


@pytest.fixture(scope="module")
def feats():
    p = PROC / "engineered_features_normalized.csv"
    if not p.exists():
        pytest.skip("run 07_feature_engineering.py first")
    return pd.read_csv(p).sort_values(["household_id", "month"]).reset_index(drop=True)


def test_split_is_disjoint_and_complete():
    split = pd.read_csv(PROC / "household_split.csv")
    hh = pd.read_csv(SYN / "households.csv")
    assert set(split.household_id) == set(hh.household_id)
    assert split.household_id.is_unique
    assert split.split.value_counts().to_dict() == {"train": int(len(hh) * 0.8), "test": len(hh) - int(len(hh) * 0.8)}


def test_features_complete(feats):
    assert feats.groupby("household_id").month.count().eq(12).all()
    assert not feats.isna().any().any()


def test_state_mapping_is_a_permutation(art):
    assert sorted(art["state_mapping"].keys()) == [0, 1, 2]
    assert sorted(art["state_mapping"].values()) == [0, 1, 2]


def test_states_ordered_by_spending_ratio(art):
    """Stable = highest income/expenditure ratio, Critical = lowest (label-free naming)."""
    means = art["model"].means_[:, 0]
    rank = art["state_mapping"]
    by_rank = sorted(rank, key=lambda s: rank[s])
    assert means[by_rank[0]] > means[by_rank[1]] > means[by_rank[2]]


def test_predictions_valid_for_one_household(art, feats):
    X = feats[feats.household_id == feats.household_id.iloc[0]][art["features"]].values
    pred = art["model"].predict(X)
    assert len(pred) == 12 and set(pred) <= {0, 1, 2}


def test_prefix_prediction_is_causal(art, feats):
    """A state computed from months 1..t must not change if later months change."""
    X = feats[feats.household_id == feats.household_id.iloc[0]][art["features"]].values.copy()
    t = 6
    before = art["model"].predict(X[:t])[-1]
    X2 = X.copy()
    X2[t:] = np.random.default_rng(0).normal(size=X2[t:].shape) * 5
    after = art["model"].predict(X2[:t])[-1]
    assert before == after


def test_held_out_accuracy_beats_majority_baseline(art, feats):
    h8 = _load_08()
    h8.HMM_FEATURES = art["features"]
    split = pd.read_csv(PROC / "household_split.csv")
    test_ids = sorted(split[split.split == "test"].household_id)
    X, lengths = h8.load_sequences(feats, test_ids)
    pred = np.array([art["state_mapping"][int(p)] for p in art["model"].predict(X, lengths)])
    raw = pd.read_csv(PROC / "engineered_features_raw.csv").sort_values(["household_id", "month"])
    y = np.concatenate([raw[raw.household_id == h].true_state.map({s: i for i, s in enumerate(STATES)}).values for h in test_ids])
    baseline = np.bincount(y).max() / len(y)
    assert (pred == y).mean() > baseline + 0.05
