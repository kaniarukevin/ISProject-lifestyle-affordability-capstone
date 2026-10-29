"""Tests for obligations, debts and goals. Run: python -m pytest tests/test_commitments.py -q"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import budget  # noqa: E402
import commitments as cm  # noqa: E402


def test_frequencies_become_monthly_amounts():
    assert cm.monthly_equivalent(12000, "monthly") == 12000
    assert cm.monthly_equivalent(15000, "termly") == 3750      # 3 terms a year
    assert cm.monthly_equivalent(30000, "semester") == 5000    # 2 semesters a year
    assert cm.monthly_equivalent(12000, "yearly") == 1000


def test_interest_free_loan_is_simple_division():
    r = cm.evaluate({"debts": [{"name": "Phone", "balance": 12000, "annual_rate": 0, "monthly_payment": 1000}]})
    plan = r["debts"]["as_planned"]
    assert plan["debt_free_in_months"] == 12 and plan["total_interest_KES"] == 0


def test_interest_makes_it_longer_and_costs_money():
    r = cm.evaluate({"debts": [{"name": "SACCO", "balance": 12000, "annual_rate": 24, "monthly_payment": 1000}]})
    plan = r["debts"]["as_planned"]
    assert plan["debt_free_in_months"] > 12 and plan["total_interest_KES"] > 0


def test_payment_below_interest_is_flagged():
    r = cm.evaluate({"debts": [{"name": "Bad loan", "balance": 100000, "annual_rate": 36, "monthly_payment": 2000}]})
    assert r["debts"]["as_planned"]["debt_free_by"] is None
    assert any("never be paid off" in w for w in r["warnings"])


def test_extra_payments_save_time_and_interest():
    debts = [{"name": "Fuliza", "balance": 5000, "annual_rate": 90, "monthly_payment": 1000},
             {"name": "Bank", "balance": 60000, "annual_rate": 15, "monthly_payment": 3000}]
    r = cm.evaluate({"debts": debts, "extra_per_month": 1500})
    assert r["debts"]["extra_saves"]["months"] > 0 and r["debts"]["extra_saves"]["interest_KES"] > 0
    comp = r["debts"]["strategy_comparison_interest_KES"]
    assert comp["avalanche"] <= comp["snowball"]               # most expensive first never costs more


def test_goals_become_a_monthly_amount():
    r = cm.evaluate({"goals": [{"name": "Emergency fund", "target": 50000, "saved": 10000, "months_left": 8}]})
    assert r["goals"][0]["monthly_needed_KES"] == 5000
    assert r["for_budget"]["goal_per_month"] == 5000


def test_output_feeds_the_budget():
    r = cm.evaluate({"obligations": [{"name": "Rent", "amount": 6000, "category": "housing"},
                                     {"name": "Fees", "amount": 15000, "frequency": "termly", "category": "school_fees"},
                                     {"name": "Chama", "amount": 1000}],
                     "debts": [{"name": "SACCO", "balance": 20000, "annual_rate": 12, "monthly_payment": 2000}]})
    fixed = r["for_budget"]["fixed"]
    assert fixed == {"housing": 6000, "school_fees": 3750, "other_commitments": 1000, "loan_repayment": 2000}
    b = budget.evaluate({"income": 30000, "fixed": fixed, "household": {"household_size": 3}})
    assert b["total"] == 30000 and b["budget"]["school_fees"] == 3750


@pytest.mark.parametrize("bad", [
    {"obligations": [{"amount": 100, "frequency": "daily"}]},
    {"obligations": [{"amount": 100, "category": "pets"}]},
    {"debts": [{"balance": "lots", "monthly_payment": 100}]},
    {"goals": [{"target": 1000, "months_left": 0}]},
    {"strategy": "random", "debts": []},
])
def test_bad_input_is_rejected(bad):
    with pytest.raises(cm.CommitmentsInputError):
        cm.evaluate(bad)
