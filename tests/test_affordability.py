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


# ---------- why this score (SHAP) and the 12-month track record (5 Nov) ----------

def _frame(months, size=1, deps=0):
    return aff.build_features(aff.months_frame(months, size, deps)).iloc[[-1]]


def test_explanation_parts_add_up_to_the_score():
    for month in (STUDENT, EARNER):
        f = _frame([month] * 12)
        ex = aff.explain(f)
        assert {p["key"] for p in ex["parts"]} == {k for k, _, _ in aff.SCORE_GROUPS}
        assert abs(ex["typical_score"] + sum(p["points"] for p in ex["parts"]) - aff._score(f)) < 1.0


def test_shapley_matches_brute_force_on_a_known_function():
    # value = 2*a + b*c on a background of zeros: exact Shapley gives a: 2, and b, c share the product equally.
    import numpy as np
    base, phi = aff.shapley(np.array([1.0, 2.0, 3.0]), np.zeros((1, 3)), [[0], [1], [2]],
                            value=lambda r: 2 * r[:, 0] + r[:, 1] * r[:, 2])
    assert base == 0 and np.allclose(phi, [2.0, 3.0, 3.0])


def test_overspending_shows_up_as_negative_points():
    over = dict(STUDENT, entertainment=STUDENT["entertainment"] + 6000)
    parts = {p["key"]: p["points"] for p in aff.explain(_frame([over] * 12))["parts"]}
    assert parts["latest_month"] < 0 and parts["recent_months"] < 0


def test_a_fragile_year_is_seen_even_when_the_last_months_look_fine():
    calm = dict(STUDENT, entertainment=200)               # STUDENT itself spends 12,300 of 12,000 before saving
    over = dict(STUDENT, entertainment=5800)
    steady, fragile = body(calm), {**body(calm), "months": [over] * 9 + [calm] * 3}
    assert aff.evaluate(fragile)["score_before"] == aff.evaluate(steady)["score_before"]   # the score cannot tell
    rec = aff.evaluate(fragile)["track_record"]
    assert (rec["months"], rec["overspent_months"], rec["fragile"], rec["lowered_verdict"]) == (12, 9, True, False)
    assert not aff.evaluate(steady)["track_record"]["fragile"]


def test_a_fragile_year_turns_affordable_into_stretch_without_cut_advice():
    calm = dict(EARNER)
    over = dict(EARNER, entertainment=EARNER["entertainment"] + 8000)
    small = {"type": "monthly_change", "changes": {"entertainment": 300}}
    assert aff.evaluate(body(calm, small))["verdict"] == "Affordable"
    r = aff.evaluate({**body(calm, small), "months": [over] * 4 + [calm] * 8})
    assert r["verdict"] == "Stretch" and r["track_record"]["lowered_verdict"]
    assert "what_to_cut" not in r and any("4 of the last 12" in x for x in r["reasons"])


def test_explain_request_shows_what_a_new_loan_moves():
    out = aff.explain_request(body(EARNER, {"type": "monthly_change", "changes": {"loan_repayment": 6000}}))
    moved = {p["key"]: p["points"] for p in out["moved"]}
    assert out["after"]["score"] < out["now"]["score"]
    assert sum(moved.values()) == pytest.approx(out["after"]["score"] - out["now"]["score"], abs=1.5)
    assert min(moved, key=moved.get) in ("latest_month", "recent_months", "debt")



def test_a_small_cost_in_a_fragile_year_stays_affordable_when_the_average_month_has_room():
    # Like the developer: a 30,000 allowance, 5 months over it, 7 calm months at about 14,000.
    calm = {"food_groceries": 8000, "transport": 3000, "entertainment": 3000, "income_primary": 30000}
    over = {"food_groceries": 20000, "transport": 6000, "entertainment": 6000, "income_primary": 30000}
    months = [over, calm, calm, over, over, calm, over, over, calm, calm, calm, calm]
    small = aff.evaluate({**body(calm), "months": months,
                          "scenario": {"type": "monthly_change", "changes": {"mobile_money_transfers": 2500}}})
    assert small["verdict"] == "Affordable" and not small["track_record"]["lowered_verdict"]
    assert any(r.startswith("A caution: you spent more than came in during 5 of the last 12") for r in small["reasons"])
    big = aff.evaluate({**body(calm), "months": months,
                        "scenario": {"type": "monthly_change", "changes": {"housing": 12000}}})
    assert big["verdict"] in ("Stretch", "Not affordable")
    if big["verdict"] == "Stretch":
        assert big["track_record"]["lowered_verdict"]


def test_the_one_pass_timeline_matches_scoring_each_month_on_its_own():
    import random
    random.seed(3)
    months = [{c: random.choice([0, 500, 3000, 8000]) for c in aff.CATS} | {"income_primary": random.choice([9000, 25000, 40000])}
              for _ in range(12)]
    for exact in (False, True):
        fast = aff.timeline(months, 3, 1, exact)
        slow = [aff.evaluate({"household": {"household_size": 3, "num_dependants": 1}, "months": months[:i + 1],
                              "statement_safe": exact}) for i in range(12)]
        assert [(r["state"], r["score"]) for r in fast] == [(r["state_now"], r["score_before"]) for r in slow]
