"""Tests for the dynamic budget. Run: python -m pytest tests/test_budget.py -q"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import budget  # noqa: E402

FAMILY = {"income": 25300, "fixed": {"housing": 6000},
          "household": {"household_size": 4, "num_dependants": 2, "urban_rural": "peri_urban"}}


def test_every_shilling_has_a_job():
    for income in (8000, 12000, 25300, 90000):
        r = budget.evaluate({**FAMILY, "income": income})
        assert r["total"] == income


def test_strain_moves_fun_money_into_savings():
    b = {s: budget.evaluate({**FAMILY, "state": s})["budget"] for s in budget.STATES}
    assert b["Stable"]["entertainment"] > b["Strained"]["entertainment"] > b["Critical"]["entertainment"]
    assert b["Stable"]["savings"] < b["Strained"]["savings"] < b["Critical"]["savings"]


def test_overspend_last_month_lowers_this_month():
    first = budget.evaluate({**FAMILY})["budget"]
    spent = dict(first, transport=first["transport"] + 1000)
    nxt = budget.evaluate({**FAMILY, "last_month": {"limits": first, "spent": spent}})
    assert nxt["budget"]["transport"] == first["transport"] - 500
    assert any("transport" in n for n in nxt["notes"])


def test_commitments_bigger_than_income_are_flagged():
    r = budget.evaluate({**FAMILY, "fixed": {"housing": 30000}})
    assert any("more than your income" in n for n in r["notes"])


def test_state_can_come_from_months():
    month = {"housing": 6000, "food_groceries": 9000, "transport": 3000, "income_primary": 25300}
    r = budget.evaluate({**FAMILY, "months": [month] * 6})
    assert r["state"] in budget.STATES


@pytest.mark.parametrize("bad", [
    {"income": 0},
    {"income": "abc"},
    {"income": 20000, "fixed": {"pets": 100}},
    {"income": 20000, "state": "Rich"},
    {"income": 20000, "household": {"urban_rural": "moon"}},
])
def test_bad_input_is_rejected(bad):
    with pytest.raises(budget.BudgetInputError):
        budget.evaluate(bad)


def test_own_spending_pattern_shapes_the_split():
    own = {"food_groceries": 6000, "transport": 3000, "utilities": 1000, "airtime_data": 500,
           "mobile_money_transfers": 0, "entertainment": 0}
    plain = budget.evaluate({**FAMILY})
    mine = budget.evaluate({**FAMILY, "own_spending": own})
    assert mine["budget"]["mobile_money_transfers"] == 0 and mine["budget"]["entertainment"] == 0
    assert mine["budget"]["food_groceries"] > plain["budget"]["food_groceries"]
    assert mine["total"] == plain["total"]                       # still every shilling has a job


def test_the_budget_follows_the_household_not_a_fixed_rule():
    """8 Nov: with 2+ months of history a line the household never uses gets nothing (here utilities, e.g. power
    included in rent), and a household that already saves 20% is not told to save 10%."""
    own = {"food_groceries": 6000, "transport": 2500, "utilities": 0, "airtime_data": 800,
           "mobile_money_transfers": 1500, "entertainment": 1200}
    b = budget.recommend_budget(30000, {"housing": 9000}, own_spending=own, own_months=3, own_savings=6000)
    assert b["budget"]["utilities"] == 0
    assert b["budget"]["savings"] >= 6000
    assert sum(b["budget"].values()) == 30000
    first_month = budget.recommend_budget(30000, {"housing": 9000}, own_spending=own, own_months=1)
    assert first_month["budget"]["utilities"] > 0            # one month is too little to drop a core line
