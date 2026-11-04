"""Tests for the affordability engine and endpoint. Run with: python -m pytest tests/test_affordability.py -q"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import affordability as aff  # noqa: E402

STUDENT = {"housing": 4000, "food_groceries": 4500, "transport": 1500, "utilities": 300, "airtime_data": 1000,
           "mobile_money_transfers": 200, "entertainment": 800, "savings": 300, "income_primary": 12000}
EARNER = {"housing": 6000, "food_groceries": 7000, "transport": 3000, "utilities": 1200, "airtime_data": 800,
          "mobile_money_transfers": 1000, "entertainment": 1000, "savings": 1800, "income_primary": 25300}


def body(month, scenario=None, n=12, size=1, deps=0):
    b = {"household": {"household_size": size, "num_dependants": deps}, "months": [month] * n}
    if scenario:
        b["scenario"] = scenario
    return b


def test_bigger_cost_never_raises_score():
    scores = [aff.evaluate(body(EARNER, {"type": "monthly_change", "changes": {"housing": x}}))["score_after"]
              for x in (0, 2500, 6000, 12000)]
    assert scores == sorted(scores, reverse=True)


def test_safety_rule_shortfall_bigger_than_savings():
    r = aff.evaluate(body(EARNER, {"type": "monthly_change", "changes": {"loan_repayment": 8000}}))
    assert r["after"]["left_over_KES"] < -r["before"]["savings_KES"]
    assert r["verdict"] == "Not affordable"


def test_savings_goal_fits_left_over():
    left = aff.evaluate(body(EARNER))["before"]["left_over_KES"]
    assert aff.evaluate(body(EARNER, {"type": "savings_goal", "extra_per_month": left - 100}))["verdict"] == "Affordable"
    assert aff.evaluate(body(EARNER, {"type": "savings_goal", "extra_per_month": left + 500}))["verdict"] == "Not affordable yet"


def test_purchase_reports_instalment_and_saving_time():
    r = aff.evaluate(body(EARNER, {"type": "purchase", "price": 30000, "months": 6}))
    assert r["instalment_per_month_KES"] == 5000
    assert r["months_to_save_up_first"] is not None


def test_student_profile_is_scored_without_errors():
    r = aff.evaluate(body(STUDENT, {"type": "monthly_change", "changes": {"housing": 4000}}))
    assert 0 <= r["score_after"] <= r["score_before"] <= 100
    assert r["verdict"] == "Not affordable"


def test_not_affordable_always_comes_with_advice():
    r = aff.evaluate(body(STUDENT, {"type": "purchase", "price": 45000, "months": 12}))
    assert r["verdict"] == "Not affordable"
    assert r["advice"] and "already short" in r["advice"][0]
    r = aff.evaluate(body(EARNER, {"type": "purchase", "price": 120000, "months": 6}))
    assert r["verdict"] == "Not affordable"
    assert any("price of up to" in tip for tip in r["advice"])


def test_one_month_of_data_is_enough():
    assert "score_before" in aff.evaluate(body(EARNER, n=1))


@pytest.mark.parametrize("bad", [
    {"months": []},
    {"months": [{"housing": -5}]},
    {"months": [{"housing": "abc"}]},
    {"months": [EARNER], "scenario": {"type": "lottery"}},
    {"months": [EARNER], "scenario": {"type": "monthly_change", "changes": {"pets": 100}}},
])
def test_bad_input_is_rejected(bad):
    with pytest.raises(aff.AffordabilityInputError):
        aff.evaluate(bad)


def test_a_one_month_cost_counts_for_one_month_only():
    short = aff.evaluate(body(EARNER, {"type": "purchase", "price": 6000, "months": 1}))
    longer = aff.evaluate(body(EARNER, {"type": "monthly_change", "changes": {"loan_repayment": 6000}}))
    assert short["lasts_months"] == 1 and len(short["cash_flow"]) == 1
    assert short["score_after"] >= longer["score_after"]       # 1 month of a cost hurts less than 3


def test_savings_can_carry_a_short_gap_but_not_a_long_one():
    no_savings = aff.evaluate(body(EARNER, {"type": "purchase", "price": 20000, "months": 1}))
    with_savings = aff.evaluate({**body(EARNER, {"type": "purchase", "price": 20000, "months": 1}),
                                 "savings_balance": 30000})
    assert no_savings["verdict"] == "Not affordable"
    assert with_savings["verdict"] == "Stretch"
    assert with_savings["cash_flow"][0]["from_savings_KES"] > 0
    assert with_savings["pay_from_savings"]["possible"] is True
    lasting = aff.evaluate({**body(EARNER, {"type": "monthly_change", "changes": {"housing": 9000}}),
                            "savings_balance": 30000})
    assert lasting["verdict"] == "Not affordable"               # savings run out; a lasting cost is not covered
    assert any("cover the gap for about" in r for r in lasting["reasons"])


def test_cash_flow_tracks_the_savings_balance():
    r = aff.evaluate({**body(EARNER, {"type": "purchase", "price": 30000, "months": 3}), "savings_balance": 5000})
    flow = r["cash_flow"]
    assert [row["month"] for row in flow] == [1, 2, 3]
    assert all(row["pay_KES"] == 10000 for row in flow)
    assert flow[-1]["savings_balance_KES"] == 5000 + sum(1800 - row["saving_paused_KES"] - row["from_savings_KES"]
                                                         for row in flow)


def test_savings_balance_must_be_a_sensible_number():
    with pytest.raises(aff.AffordabilityInputError):
        aff.evaluate({**body(EARNER), "savings_balance": -5})


def test_a_single_payment_is_not_called_a_loan_and_the_score_is_explained():
    r = aff.evaluate({**body(EARNER, {"type": "purchase", "price": 20000, "months": 1}), "savings_balance": 30000})
    assert not any("instalments" in x.lower() or "loan" in x.lower() for x in r["reasons"])
    assert "month(s) you pay" in r["score_note"]
    lasting = aff.evaluate(body(EARNER, {"type": "monthly_change", "changes": {"housing": 2000}}))
    assert lasting["score_note"] is None
