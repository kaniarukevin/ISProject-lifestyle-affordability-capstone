"""Tests for /forecast logic on the local staging data. Run: python -m pytest tests/test_forecast.py -q"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import app as svc  # noqa: E402

USER = "96ccbe38-e8e6-4761-8bf0-e5ea6844a89d"


@pytest.fixture(scope="module", autouse=True)
def data_loaded():
    svc.ensure_loading()
    assert svc.STORE["ready"].wait(timeout=60), svc.STORE["error"]


def forecast(month, year, user=USER):
    return svc.make_forecast(user, month, year)


def test_breakdown_adds_up_to_total():
    for month, year in [(9, 2026), (10, 2026), (6, 2025)]:
        r, err = forecast(month, year)
        assert err is None
        assert abs(sum(r["breakdown"].values()) - r["estimatedTotal"]) < 1.0


def test_month_with_its_own_budget_uses_the_ensemble():
    r, _ = forecast(9, 2026)
    assert r["method"] in ("blend_budget_tree_split", "blend_budget_median_split")


def test_next_month_uses_last_known_budget():
    r, _ = forecast(10, 2026)
    assert r["method"] == "blend_last_budget_median_split"


def test_risk_flag_is_a_label():
    r, _ = forecast(10, 2026)
    assert r["riskFlag"] in ("LOW", "MODERATE", "HIGH")


def test_unknown_user_is_404():
    r, err = forecast(10, 2026, user="nobody")
    assert r is None and err[1] == 404


def test_no_history_still_answers_200():
    r, err = forecast(1, 2020)
    assert err is None and r["method"] == "peer_median"


def test_unused_categories_stay_at_zero():
    r, _ = forecast(9, 2026)
    assert r["breakdown"]["Gambling"] == 0.0 and r["breakdown"]["Crypto Purchase"] == 0.0
