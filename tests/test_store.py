"""Tests for the data layer, on an in-memory SQLite database. Run: python -m pytest tests/test_store.py -q"""
import io
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import app as svc  # noqa: E402
import store  # noqa: E402


@pytest.fixture()
def client():
    store.init("sqlite://")
    store._ATTEMPTS.clear()
    return svc.app.test_client()


def signup(client, email="kevin@example.com"):
    r = client.post("/auth/register", json={"email": email, "password": "strong-pass-1", "consent": True})
    assert r.status_code == 201
    return {"Authorization": f"Bearer {r.get_json()['token']}"}


def test_register_login_and_bad_password(client):
    signup(client)
    assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "strong-pass-1"}).status_code == 200
    assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "wrong"}).status_code == 401
    assert client.post("/auth/register", json={"email": "kevin@example.com", "password": "strong-pass-1"}).status_code == 409


def test_passwords_are_not_stored_in_plain_text(client):
    signup(client)
    with store.session() as s:
        user = s.scalar(store.select(store.User))
        assert "strong-pass-1" not in user.password_hash


def test_everything_needs_a_login(client):
    assert client.get("/me/profile").status_code == 401
    assert client.get("/me/transactions", headers={"Authorization": "Bearer forged"}).status_code == 401


def test_profile_round_trip(client):
    h = signup(client)
    profile = {"householdSize": 1, "dependants": 0, "urbanRural": "urban", "formalJob": False, "paysOwnFees": False,
               "incomes": [{"name": "HELB", "amount": 30000, "frequency": "semester"}]}
    assert client.put("/me/profile", json=profile, headers=h).status_code == 200
    assert client.get("/me/profile", headers=h).get_json()["incomes"][0]["frequency"] == "semester"


def test_users_cannot_see_each_others_data(client):
    a, b = signup(client, "a@example.com"), signup(client, "b@example.com")
    client.post("/me/transactions", json={"date": "2026-10-01", "amount": 500, "category": "transport"}, headers=a)
    assert client.get("/me/transactions", headers=b).get_json()["transactions"] == []


def test_monthly_summary_feeds_the_engines(client):
    h = signup(client)
    client.put("/me/profile", json={"householdSize": 1, "incomes": [{"name": "Allowance", "amount": 12000}]}, headers=h)
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-09-03", "amount": 4000, "category": "housing"},
        {"date": "2026-10-03", "amount": 4000, "category": "housing"},
        {"date": "2026-10-10", "amount": 900, "category": "transport"}])
    months = client.get("/me/months", headers=h).get_json()["months"]
    assert [(m["year"], m["month"]) for m in months] == [(2026, 9), (2026, 10)]
    assert months[1]["transport"] == 900 and months[1]["income_primary"] == 12000
    r = client.post("/affordability", headers=h, json={"household": {"household_size": 1}, "months": months})
    assert r.status_code == 200 and "score_before" in r.get_json()


def test_budget_and_commitments_and_scenarios_are_saved(client):
    h = signup(client)
    assert client.put("/me/budgets/2026/11", json={"budget": {"housing": 4000}}, headers=h).status_code == 200
    assert client.get("/me/budgets/2026/11", headers=h).get_json()["budget"]["housing"] == 4000
    assert client.put("/me/commitments", headers=h, json={"goals": [{"name": "Phone", "target": 30000,
                                                                   "saved": 5000, "months_left": 5}]}).status_code == 200
    assert client.get("/me/commitments", headers=h).get_json()["goals"][0]["name"] == "Phone"
    assert client.post("/me/scenarios", headers=h, json={"request": {"x": 1}, "result": {"verdict": "Stretch"}}).status_code == 201
    assert len(client.get("/me/scenarios", headers=h).get_json()["scenarios"]) == 1


def test_bad_input_is_rejected(client):
    h = signup(client)
    assert client.post("/me/transactions", json={"date": "yesterday", "amount": 1, "category": "transport"}, headers=h).status_code == 400
    assert client.post("/me/transactions", json={"date": "2026-10-01", "amount": 1, "category": "pets"}, headers=h).status_code == 400
    assert client.put("/me/profile", json={"householdSize": 2, "dependants": 2}, headers=h).status_code == 400
    assert client.post("/auth/register", json={"email": "nope", "password": "12345678"}).status_code == 400


def test_delete_account_removes_everything(client):
    h = signup(client)
    client.post("/me/transactions", json={"date": "2026-10-01", "amount": 500, "category": "transport"}, headers=h)
    assert client.delete("/me", headers=h).status_code == 200
    assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "strong-pass-1"}).status_code == 401


def test_repeated_wrong_passwords_lock_the_account_for_a_while(client):
    signup(client)
    for _ in range(5):
        assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "wrong"}).status_code == 401
    r = client.post("/auth/login", json={"email": "kevin@example.com", "password": "strong-pass-1"})
    assert r.status_code == 429                      # even the right password waits now


def test_sign_ups_from_one_network_are_limited(client):
    codes = [client.post("/auth/register", json={"email": f"u{i}@example.com", "password": "strong-pass-1"}).status_code
             for i in range(6)]
    assert codes[:5] == [201] * 5 and codes[5] == 429


def test_only_known_websites_may_call_from_a_browser(client):
    ok = client.get("/health", headers={"Origin": "http://localhost:5173"})
    bad = client.get("/health", headers={"Origin": "https://evil.example.com"})
    assert ok.headers.get("Access-Control-Allow-Origin") == "http://localhost:5173"
    assert "Access-Control-Allow-Origin" not in bad.headers


def test_overview_needs_a_household_first(client):
    h = signup(client)
    assert client.get("/me/overview", headers=h).status_code == 400


def _student(client):
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Allowance", "amount": 12000}]})
    for m in (8, 9, 10):
        client.post("/me/transactions", headers=h, json=[
            {"date": f"2026-{m:02d}-02", "amount": 4000, "category": "housing"},
            {"date": f"2026-{m:02d}-05", "amount": 3500 + m * 10, "category": "food_groceries"},
            {"date": f"2026-{m:02d}-09", "amount": 900, "category": "transport"}])
    return h


def test_overview_gives_state_score_and_this_months_forecast(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    o = client.get("/me/overview", headers=h).get_json()
    assert o["has_data"] and o["state"] in ("Stable", "Strained", "Critical") and 0 <= o["score"] <= 100
    assert (o["forecast"]["year"], o["forecast"]["month"]) == (2026, 11)
    assert o["forecast"]["method"] == "trailing_median"               # model switched off: the fallback
    assert abs(o["forecast"]["total"] - 8490) <= 3                    # median of 8480, 8490, 8500
    assert abs(o["forecast"]["breakdown"]["food_groceries"] - 3590) <= 3
    assert o["latest"]["left_over"] == 12000 - (4000 + 3600 + 900) and not o["latest"]["partial"]


def test_sparse_categories_do_not_collapse_the_forecast(client, monkeypatch):
    """Found in testing: one big month and categories used only now and then gave a forecast of KES 0."""
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)   # checks the median/blend logic
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 12, 2))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 50000}]})
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-09-03", "amount": 20000, "category": "housing"},
        {"date": "2026-10-03", "amount": 1000000, "category": "entertainment"},
        {"date": "2026-11-03", "amount": 4000, "category": "utilities"},
        {"date": "2026-11-04", "amount": 300, "category": "transport"}])
    fc = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert abs(fc["total"] - 20000) <= 3                              # median of 20,000 / 1,000,000 / 4,300


def test_the_month_in_progress_is_shown_but_not_used_for_the_forecast(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    before = client.get("/me/overview", headers=h).get_json()["forecast"]["total"]
    client.post("/me/transactions", headers=h, json={"date": "2026-11-02", "amount": 100000, "category": "entertainment"})
    o = client.get("/me/overview", headers=h).get_json()
    assert o["forecast"]["total"] == before and o["latest"]["partial"] and o["latest"]["spent"] == 100000


def test_saved_budget_steers_the_forecast(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)   # checks the median/blend logic
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    budget = {"housing": 4000, "food_groceries": 3000, "transport": 800}
    client.put("/me/budgets/2026/11", headers=h, json={"budget": budget})
    fc = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert fc["method"] in ("blend_budget_model", "blend_budget_median")
    assert abs(fc["breakdown"]["food_groceries"] - (0.75 * 3000 + 0.25 * 3590)) <= 3


def test_one_off_purchases_stay_out_of_usual_spending(client, monkeypatch):
    """Found in testing: a KES 1,000,000 apartment made October look like reckless overspending."""
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    before = client.get("/me/overview", headers=h).get_json()
    client.post("/me/transactions", headers=h, json={"date": "2026-10-20", "amount": 1000000,
                                                     "category": "housing", "one_off": True,
                                                     "description": "Apartment deposit"})
    after = client.get("/me/overview", headers=h).get_json()
    assert after["forecast"]["total"] == before["forecast"]["total"]
    assert (after["state"], after["score"]) == (before["state"], before["score"])
    assert after["latest"]["one_off"] == 1000000 and after["latest"]["spent"] == before["latest"]["spent"]
    listed = client.get("/me/transactions", headers=h).get_json()["transactions"]
    assert any(t["one_off"] for t in listed)


def test_old_database_gets_the_new_column_without_losing_data(tmp_path):
    db = tmp_path / "old.db"
    from sqlalchemy import create_engine as ce, text as tx
    with ce(f"sqlite:///{db}").begin() as c:
        c.execute(tx("CREATE TABLE transactions (id INTEGER PRIMARY KEY, user_id INTEGER, day DATE, amount FLOAT, "
                     "category VARCHAR(40), description VARCHAR(200), source VARCHAR(20))"))
        c.execute(tx("INSERT INTO transactions VALUES (1, 1, '2026-10-01', 500, 'transport', '', 'manual')"))
    engine = store.init(f"sqlite:///{db}")
    with engine.connect() as c:
        assert c.execute(tx("SELECT amount, one_off FROM transactions")).fetchall() == [(500.0, 0)]
        assert "savings_balance" in {col["name"] for col in store.inspect(engine).get_columns("profiles")}


def test_budget_plan_uses_profile_commitments_and_history(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                                   # income 12,000; rent 4,000 recorded as spending
    r = client.get("/me/budget-plan", headers=h).get_json()
    plan = r["plan"]
    assert (r["year"], r["month"]) == (2026, 11)
    assert plan["total"] == 12000 and plan["budget"]["housing"] == 4000          # usual rent set aside
    assert any("usual rent" in n for n in plan["notes"])
    client.put("/me/commitments", headers=h, json={"obligations": [{"name": "Hostel", "amount": 4500, "category": "housing"}],
                                                  "goals": [{"name": "Phone", "target": 6000, "months_left": 3}]})
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]
    assert plan["budget"]["housing"] == 4500 and plan["budget"]["savings"] >= 2000   # commitment and goal win


def test_budget_plan_applies_last_months_overspend(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    october = {"housing": 4000, "food_groceries": 3000, "transport": 400, "savings": 1200}
    client.put("/me/budgets/2026/10", headers=h, json={"budget": october})      # transport actual was 900
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]
    assert any("transport" in n for n in plan["notes"])


def test_budget_plan_shows_spending_so_far_and_saved_budget(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.post("/me/transactions", headers=h, json={"date": "2026-11-03", "amount": 700, "category": "transport"})
    r = client.get("/me/budget-plan", headers=h).get_json()
    assert r["spent_so_far"] == {"transport": 700}
    assert r["auto_saved"] and r["saved"]["total"] == 12000          # saved the first time it is opened
    again = client.get("/me/budget-plan", headers=h).get_json()
    assert not again["auto_saved"] and again["saved"] == r["saved"]
    assert again["days_left"] == 16 and again["safe_per_day"] == round(again["everyday_left"] / 16)


def test_afford_needs_some_spending_first(client):
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 12000}]})
    r = client.post("/me/afford", headers=h, json={"preset": "savings_goal", "target": 3000, "months": 3})
    assert r.status_code == 400 and "spending" in r.get_json()["error"]


def test_moving_house_uses_the_difference_from_current_rent(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                                           # usual rent 4,000, income 12,000
    cheaper = client.post("/me/afford", headers=h, json={"preset": "move_house", "new_rent": 3500}).get_json()
    pricier = client.post("/me/afford", headers=h, json={"preset": "move_house", "new_rent": 9000}).get_json()
    assert cheaper["score_after"] >= cheaper["score_before"]
    assert pricier["after"]["spending_KES"] - pricier["before"]["spending_KES"] == 5000
    assert pricier["verdict"] == "Not affordable" and pricier["advice"]
    assert pricier["title"] == "Move to a place with rent of KES 9,000"


def test_every_preset_answers_and_is_kept_in_history(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    presets = [
        {"preset": "new_expense", "category": "entertainment", "amount": 1500, "label": "Gym"},
        {"preset": "new_baby"},
        {"preset": "purchase", "price": 45000, "months": 12, "label": "Laptop"},
        {"preset": "loan", "amount": 50000, "months": 12, "annual_rate": 14},
        {"preset": "savings_goal", "target": 3000, "months": 3, "label": "Trip"},
        {"preset": "income_change", "amount": -2000},
        {"preset": "income_change", "amount": 5000},
    ]
    for p in presets:
        r = client.post("/me/afford", headers=h, json=p)
        assert r.status_code == 200, (p, r.get_json())
        assert r.get_json()["verdict"]
    assert len(client.get("/me/scenarios", headers=h).get_json()["scenarios"]) == len(presets)


def test_a_raise_helps_and_a_pay_cut_hurts(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    up = client.post("/me/afford", headers=h, json={"preset": "income_change", "amount": 5000}).get_json()
    down = client.post("/me/afford", headers=h, json={"preset": "income_change", "amount": -3000}).get_json()
    assert up["score_after"] >= up["score_before"] >= down["score_after"]


def test_commitments_count_even_if_not_recorded_as_spending(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    base = client.post("/me/afford", headers=h, json={"preset": "income_change", "amount": 0}).get_json()
    client.put("/me/commitments", headers=h, json={"debts": [{"name": "SACCO", "balance": 20000,
                                                             "annual_rate": 12, "monthly_payment": 2000}]})
    with_debt = client.post("/me/afford", headers=h, json={"preset": "income_change", "amount": 0}).get_json()
    assert with_debt["before"]["spending_KES"] == base["before"]["spending_KES"] + 2000


@pytest.mark.parametrize("bad", [{"preset": "lottery"}, {"preset": "new_expense", "category": "pets", "amount": 5},
                                 {"preset": "purchase", "price": 0}, {"preset": "income_change", "amount": "lots"}])
def test_afford_rejects_bad_choices(client, monkeypatch, bad):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    assert client.post("/me/afford", headers=h, json=bad).status_code == 400


def test_savings_balance_is_saved_and_shown(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "savingsBalance": 15000,
                                               "incomes": [{"name": "Allowance", "amount": 12000}]})
    assert client.get("/me/profile", headers=h).get_json()["savingsBalance"] == 15000
    o = client.get("/me/overview", headers=h).get_json()
    assert o["savings_balance"] == 15000 and o["score_explained"]


def test_dashboard_and_afford_agree_on_the_household(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.put("/me/commitments", headers=h, json={"debts": [{"name": "SACCO", "balance": 20000,
                                                             "annual_rate": 12, "monthly_payment": 2000}]})
    o = client.get("/me/overview", headers=h).get_json()
    a = client.post("/me/afford", headers=h, json={"preset": "income_change", "amount": 0}).get_json()
    assert o["score"] == a["score_before"] and o["state"] == a["state_now"]


def test_a_one_month_purchase_can_be_carried_by_savings(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                                         # about 3,000 left a month
    phone = {"preset": "purchase", "price": 15000, "months": 1, "label": "Phone"}
    assert client.post("/me/afford", headers=h, json=phone).get_json()["verdict"] == "Not affordable"
    client.put("/me/profile", headers=h, json={"householdSize": 1, "savingsBalance": 20000,
                                               "incomes": [{"name": "Allowance", "amount": 12000}]})
    r = client.post("/me/afford", headers=h, json=phone).get_json()
    assert r["verdict"] == "Stretch" and len(r["cash_flow"]) == 1


def test_a_temporary_new_cost_is_labelled(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    r = client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "school_fees",
                                                   "amount": 2000, "months": 3, "label": "Course"}).get_json()
    assert r["lasts_months"] == 3 and r["title"].endswith("for 3 month(s)")


def _check(client, h, choice):
    r = client.post("/me/afford", headers=h, json=choice)
    assert r.status_code == 200, r.get_json()
    return r.get_json()["id"]


def test_going_ahead_with_a_purchase_adds_a_debt_and_changes_the_budget(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    before = client.get("/me/budget-plan", headers=h).get_json()["plan"]["budget"]
    sid = _check(client, h, {"preset": "purchase", "price": 12000, "months": 6, "label": "Laptop"})
    r = client.post(f"/me/scenarios/{sid}/apply", headers=h, json={"how": "instalments"})
    assert r.status_code == 200 and "debt" in r.get_json()["notes"][0]
    debts = client.get("/me/commitments", headers=h).get_json()["debts"]
    assert debts[0]["name"] == "Laptop" and debts[0]["monthly_payment"] == 2000
    after = client.get("/me/budget-plan", headers=h).get_json()["plan"]["budget"]
    assert after["loan_repayment"] == before.get("loan_repayment", 0) + 2000
    assert client.post(f"/me/scenarios/{sid}/apply", headers=h, json={}).status_code == 409   # only once


def test_paying_from_savings_lowers_the_balance(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "savingsBalance": 20000,
                                               "incomes": [{"name": "Allowance", "amount": 12000}]})
    sid = _check(client, h, {"preset": "purchase", "price": 15000, "months": 1, "label": "Phone"})
    assert client.post(f"/me/scenarios/{sid}/apply", headers=h, json={"how": "from_savings"}).status_code == 200
    assert client.get("/me/profile", headers=h).get_json()["savingsBalance"] == 5000


def test_moving_house_replaces_the_rent_and_a_goal_is_added(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    for _ in range(2):                                           # moving twice keeps one rent
        sid = _check(client, h, {"preset": "move_house", "new_rent": 5000})
        client.post(f"/me/scenarios/{sid}/apply", headers=h, json={})
    sid = _check(client, h, {"preset": "savings_goal", "target": 6000, "months": 3, "label": "Trip"})
    client.post(f"/me/scenarios/{sid}/apply", headers=h, json={})
    c = client.get("/me/commitments", headers=h).get_json()
    assert [o["amount"] for o in c["obligations"] if o["category"] == "housing"] == [5000]
    assert c["goals"][0]["name"] == "Trip"


def test_income_changes_update_the_profile(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    sid = _check(client, h, {"preset": "income_change", "amount": -2000})
    client.post(f"/me/scenarios/{sid}/apply", headers=h, json={})
    incomes = client.get("/me/profile", headers=h).get_json()["incomes"]
    assert sum(i["amount"] for i in incomes) == 10000


def test_past_checks_can_be_deleted_only_by_their_owner(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    other = signup(client, "other@example.com")
    sid = _check(client, h, {"preset": "income_change", "amount": 1000})
    assert client.delete(f"/me/scenarios/{sid}", headers=other).status_code == 404
    assert client.post(f"/me/scenarios/{sid}/apply", headers=other, json={}).status_code == 404
    assert client.delete(f"/me/scenarios/{sid}", headers=h).status_code == 200
    assert client.get("/me/scenarios", headers=h).get_json()["scenarios"] == []


def test_budget_leaves_out_lines_the_user_never_uses(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                       # spends on rent, food and transport only
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]
    for unused in ("mobile_money_transfers", "entertainment", "airtime_data"):
        assert plan["budget"].get(unused, 0) == 0
    assert plan["budget"]["food_groceries"] > 0 and plan["total"] == 12000
    assert any("No budget for" in n for n in plan["notes"])


def test_chama_in_commitments_is_not_budgeted_twice(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    for m in (8, 9, 10):                       # the 1,000 sent each month is the chama
        client.post("/me/transactions", headers=h, json={"date": f"2026-{m:02d}-20", "amount": 1000,
                                                         "category": "mobile_money_transfers"})
    sent = client.get("/me/budget-plan", headers=h).get_json()["plan"]["budget"]["mobile_money_transfers"]
    assert sent > 0
    client.put("/me/commitments", headers=h, json={"obligations": [{"name": "Chama", "amount": 1000,
                                                                   "category": "other_commitments"}]})
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]["budget"]
    assert plan["other_commitments"] == 1000 and plan.get("mobile_money_transfers", 0) == 0


def test_saving_is_shown_apart_from_spending(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.post("/me/transactions", headers=h, json={"date": "2026-10-28", "amount": 1500, "category": "savings"})
    latest = client.get("/me/overview", headers=h).get_json()["latest"]
    assert latest["saved"] == 1500 and latest["spent"] == 4000 + 3600 + 900
    assert latest["left_over"] == 12000 - (4000 + 3600 + 900) - 1500


ROUGH = {"housing": 4000, "food_groceries": 3500, "transport": 1000, "airtime_data": 500}


def test_rough_estimates_make_the_app_work_on_day_one(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "estimates": ROUGH,
                                               "incomes": [{"name": "Allowance", "amount": 12000}]})
    assert client.get("/me/profile", headers=h).get_json()["estimates"]["food_groceries"] == 3500
    o = client.get("/me/overview", headers=h).get_json()
    assert o["has_data"] and o["estimated"] and o["latest"]["spent"] == 9000
    assert "rough figures" in o["notes"][0]
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]
    assert plan["budget"]["housing"] == 4000 and plan["budget"].get("entertainment", 0) == 0
    r = client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "entertainment", "amount": 1000})
    assert r.status_code == 200 and r.get_json()["verdict"]


def test_real_months_replace_the_estimates(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "estimates": {"food_groceries": 99999},
                                               "incomes": [{"name": "Allowance", "amount": 12000}]})
    o = client.get("/me/overview", headers=h).get_json()
    assert not o["estimated"] and o["latest"]["spent"] == 4000 + 3600 + 900


def test_estimates_must_be_known_categories(client):
    h = signup(client)
    r = client.put("/me/profile", headers=h, json={"householdSize": 1, "estimates": {"pets": 500},
                                                   "incomes": [{"name": "Pay", "amount": 1000}]})
    assert r.status_code == 400


def test_the_forecast_model_is_used_and_knows_fee_months(client, monkeypatch):
    if store.user_forecast_model() is None:
        pytest.skip("backend/models/user_forecast.joblib not trained")
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 3, "dependants": 1,
                                               "incomes": [{"name": "Pay", "amount": 40000}]})
    for m in range(1, 11):                       # fees of 15,000 in January, May and September
        rows = [{"date": f"2026-{m:02d}-02", "amount": 9000, "category": "housing"},
                {"date": f"2026-{m:02d}-05", "amount": 12000, "category": "food_groceries"},
                {"date": f"2026-{m:02d}-09", "amount": 3000, "category": "transport"}]
        if m in (1, 5, 9):
            rows.append({"date": f"2026-{m:02d}-10", "amount": 15000, "category": "school_fees"})
        client.post("/me/transactions", headers=h, json=rows)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    nov = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert nov["method"] == "forecast_model" and nov["total"] > 0
    assert nov["breakdown"].get("school_fees", 0) == 0           # November is not a fee month
    with store.session() as s:
        months, _, _ = store._user_months(s, 1)
        jan = store.forecast_for_user(s, 1, months[:10], 2027, 1)
    assert jan["breakdown"]["school_fees"] == 15000 and jan["total"] > nov["total"]


def test_forecast_gives_a_range_and_follows_a_new_rent(client, monkeypatch):
    if store.user_forecast_model() is None:
        pytest.skip("backend/models/user_forecast.joblib not trained")
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                                        # rent 4,000 in every month
    fc = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert fc["range"]["low"] <= fc["total"] <= fc["range"]["high"]
    client.put("/me/commitments", headers=h, json={"obligations": [{"name": "New place", "amount": 7000,
                                                                   "category": "housing"}]})
    moved = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert moved["breakdown"]["housing"] >= 7000 - 1 and moved["total"] > fc["total"]
    assert "rent" in moved["note"]


def test_chama_set_aside_is_explained_not_called_unused(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    for m in (8, 9, 10):
        client.post("/me/transactions", headers=h, json={"date": f"2026-{m:02d}-20", "amount": 1000,
                                                         "category": "mobile_money_transfers"})
    client.put("/me/commitments", headers=h, json={"obligations": [{"name": "Chama", "amount": 1000,
                                                                   "category": "other_commitments"}]})
    notes = client.get("/me/budget-plan", headers=h).get_json()["plan"]["notes"]
    assert any("already set aside" in n for n in notes)
    assert not any("money sent to others: you have not spent" in n for n in notes)


def _upload(client, h, monkeypatch, text=None):
    import mpesa
    from test_mpesa import SAMPLE
    monkeypatch.setattr(mpesa, "read_pdf", lambda data, password=None: text or SAMPLE)
    return client.post("/me/statements/preview", headers=h,
                       data={"file": (io.BytesIO(b"%PDF-fake"), "statement.pdf")}, content_type="multipart/form-data")


def _statement_user(client, monkeypatch, **profile):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 30000}],
                                               **profile})
    return h


def _import(client, h, prev, **extra):
    r = client.post("/me/statements/import", headers=h, json={"transactions": prev["transactions"],
                                                              "period": prev["period"], **extra})
    assert r.status_code == 200, r.get_json()
    return r.get_json()


JOHN = "person:0711***111:JOHN MWANGI"
EQUITY = "paybill:247247:000123457157"


def test_statement_preview_saves_nothing_and_import_keeps_types_and_payees(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    p = _upload(client, h, monkeypatch)
    assert p.status_code == 200, p.get_json()
    prev = p.get_json()
    assert prev["checks"]["ok"] and prev["payees"][0]["key"] == JOHN
    assert prev["payees"][0]["suggestion"]["tag"] == "housing"
    assert client.get("/me/transactions", headers=h).get_json()["transactions"] == []      # preview saves nothing
    _import(client, h, prev, tags={JOHN: "housing", EQUITY: "own_account"})
    txs = client.get("/me/transactions", headers=h).get_json()["transactions"]
    john = [t for t in txs if t["payee_key"] == JOHN]
    assert len(john) == 3 and all(t["category"] == "housing" and t["type"] == "sent" for t in john)
    assert not any(t["payee_key"] == EQUITY for t in txs)                       # own account: not spending
    charges = [t for t in txs if t["type"] == "charges"]
    assert len(charges) == 3 and all(t["label"] == "M-PESA charges" for t in charges)
    assert {t["category"] for t in txs if t["payee"] in ("Mary W", "FRANCY ENTERPRISES", "Cash")} == {"unsorted"}
    again = _upload(client, h, monkeypatch).get_json()
    assert again["new"] == 0 and JOHN not in [x["key"] for x in again["payees"]]   # remembered, nothing repeated
    _import(client, h, again)
    assert len(client.get("/me/transactions", headers=h).get_json()["transactions"]) == len(txs)


def test_unsorted_money_counts_in_totals_and_switches_to_the_statement_safe_model(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    prev = _upload(client, h, monkeypatch).get_json()
    for t in prev["transactions"]:
        t["one_off"] = False                                 # keep the 15,000 Equity payment as usual spending
    _import(client, h, prev)
    o = client.get("/me/overview", headers=h).get_json()
    assert o["statement_safe"] and o["unsorted_share"] > 0.10
    assert o["latest"]["by_category"]["unsorted"] == 15000 + 300 + 250
    assert o["latest"]["spent"] == 8100 + 15000 + 300 + 250 + 1200          # every shilling still counted
    assert any("not sorted yet" in n for n in o["notes"])
    months = client.get("/me/months", headers=h).get_json()["months"]
    oct_ = next(m for m in months if m["month"] == 10)
    spread = sum(oct_[c] for c in ("food_groceries", "transport", "utilities", "airtime_data",
                                   "mobile_money_transfers", "entertainment"))
    assert abs(spread - (1200 + 8100 + 15550)) < 1                         # unsorted spread for the engines
    plan = client.get("/me/budget-plan", headers=h).get_json()
    assert plan["plan"]["total"] == 30000 and plan["spent_so_far"] == {}


def test_correct_one_payment_or_always_for_a_payee_and_undo(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    txs = client.get("/me/transactions", headers=h).get_json()["transactions"]
    francy = next(t for t in txs if t["payee"] == "FRANCY ENTERPRISES")
    john = [t for t in txs if t["payee_key"] == JOHN]
    r = client.patch(f"/me/transactions/{john[0]['id']}", headers=h, json={"category": "food_groceries"})
    assert r.get_json()["updated"] == 1                                       # just this one, pinned
    r = client.patch(f"/me/transactions/{francy['id']}", headers=h, json={"category": "food_groceries", "scope": "payee"})
    assert r.status_code == 200 and r.get_json()["updated"] == 1
    r = client.put("/me/payees", headers=h, json={"key": JOHN, "tag": "housing"})
    body = r.get_json()
    assert body["updated"] == 2                                               # the pinned one is left alone
    assert body["offer"]["category"] == "housing" and body["offer"]["amount"] == 8000
    payees = client.get("/me/payees", headers=h).get_json()["payees"]
    assert next(p for p in payees if p["key"] == JOHN)["tag"] == "housing"
    assert client.delete(f"/me/payees?key={JOHN}", headers=h).get_json()["updated"] == 2
    txs = client.get("/me/transactions", headers=h).get_json()["transactions"]
    assert sorted(t["category"] for t in txs if t["payee_key"] == JOHN) == ["food_groceries",
                                                                            "mobile_money_transfers",
                                                                            "mobile_money_transfers"]
    assert client.patch(f"/me/transactions/{francy['id']}", headers=h, json={"category": "pets"}).status_code == 400


def test_tagging_a_landlord_offers_rent_that_the_budget_then_sets_aside(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    offer = client.put("/me/payees", headers=h, json={"key": JOHN, "tag": "housing"}).get_json()["offer"]
    assert "Add rent of KES 8,000 a month" in offer["text"]
    assert client.post("/me/payees/commitment", headers=h, json=offer).status_code == 200
    c = client.get("/me/commitments", headers=h).get_json()
    assert [o["amount"] for o in c["obligations"] if o["category"] == "housing"] == [8000]
    plan = client.get("/me/budget-plan", headers=h).get_json()["plan"]
    assert plan["budget"]["housing"] == 8000


def test_a_one_off_purchase_can_complete_a_goal(client, monkeypatch):
    h = _statement_user(client, monkeypatch, savingsBalance=20000)
    client.put("/me/commitments", headers=h, json={"goals": [{"name": "Phone", "target": 15500, "saved": 12000,
                                                             "months_left": 2}]})
    prev = _upload(client, h, monkeypatch).get_json()
    big = next(t for t in prev["transactions"] if t["amount"] == 15000 and t["direction"] == "out")
    assert big["one_off"] and big["goals"][0]["name"] == "Phone"
    eq = next(p for p in prev["payees"] if p["key"] == EQUITY)
    assert any('goal "Phone"' in hint for hint in eq["hints"])
    r = _import(client, h, prev, completed_goals=["Phone"])
    assert any("Goal reached: Phone" in n for n in r["notes"])
    assert client.get("/me/profile", headers=h).get_json()["savingsBalance"] == 8000
    summary = client.put("/me/commitments", headers=h, json=client.get("/me/commitments", headers=h).get_json()).get_json()
    assert summary["summary"]["for_budget"]["goal_per_month"] == 0 and summary["summary"]["completed_goals"]


def test_hand_entered_records_in_statement_months_are_replaced_not_doubled(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-10-20", "amount": 1200, "category": "food_groceries"},       # the same Quick Mart trip, typed
        {"date": "2026-06-10", "amount": 900, "category": "transport"}])             # a month the statement lacks
    prev = _upload(client, h, monkeypatch).get_json()
    assert prev["manual_overlap"] == {"count": 1, "months": ["2026-10"]}
    r = _import(client, h, prev)
    assert any("Replaced 1 hand-entered" in n for n in r["notes"])
    txs = client.get("/me/transactions", headers=h).get_json()["transactions"]
    assert sum(1 for t in txs if t["amount"] == 1200) == 1
    assert any(t["date"] == "2026-06-10" for t in txs)


def test_undo_statement_import(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    client.post("/me/transactions", headers=h, json={"date": "2026-06-10", "amount": 900, "category": "transport"})
    assert client.delete("/me/statements", headers=h).get_json()["removed"] > 10
    assert [t["source"] for t in client.get("/me/transactions", headers=h).get_json()["transactions"]] == ["manual"]


def test_statement_errors_are_clear(client, monkeypatch):
    h = signup(client)
    assert client.post("/me/statements/preview", headers=h, data={}, content_type="multipart/form-data").status_code == 400
    r = _upload(client, h, monkeypatch, text="not a statement at all")
    assert r.status_code == 400 and "does not look like" in r.get_json()["error"]
    assert client.post("/me/statements/import", headers=h, json={"transactions": [], "tags": {"x": "pets"}}).status_code == 400


def test_a_seller_paid_by_send_money_can_be_tagged_shopping(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    mary = "pochi:0712***345:MARY W"
    assert client.put("/me/payees", headers=h, json={"key": mary, "tag": "shopping"}).status_code == 200
    o = client.get("/me/overview", headers=h).get_json()
    assert o["latest"]["by_category"]["shopping"] == 300                  # shown by its real name
    assert "unsorted" in o["latest"]["by_category"]                       # the rest is still honestly unsorted
    plan = client.get("/me/budget-plan", headers=h).get_json()
    assert plan["plan"]["total"] == 30000


def test_timeline_scores_each_month_and_warns_when_records_are_old(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    o = client.get("/me/overview", headers=h).get_json()
    assert [(x["year"], x["month"]) for x in o["timeline"]] == [(2026, 8), (2026, 9), (2026, 10)]
    assert o["timeline"][-1]["state"] == o["state"] and o["timeline"][-1]["score"] == o["score"]
    assert o["timeline_summary"].startswith("Past 3 months:")
    monkeypatch.setattr(store, "_today", lambda: store.date(2027, 2, 10))
    o = client.get("/me/overview", headers=h).get_json()
    assert any("latest records are from October 2026" in n for n in o["notes"])


def test_tagging_a_bank_as_my_allowance_uses_what_actually_arrived(client, monkeypatch):
    h = _statement_user(client, monkeypatch)
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    before = {(x["year"], x["month"]): x["income"] for x in client.get("/me/overview", headers=h).get_json()["timeline"]}
    assert set(before.values()) == {30000}                                  # profile income until told otherwise
    payees = client.get("/me/payees", headers=h).get_json()["payees"]
    bank = next(p for p in payees if p["key"] == "in:standard chartered bank")
    assert bank["direction"] == "in" and bank["category"] == "own_account"
    assert client.put("/me/payees", headers=h, json={"key": bank["key"], "tag": "income"}).status_code == 200
    o = client.get("/me/overview", headers=h).get_json()
    after = {(x["year"], x["month"]): x["income"] for x in o["timeline"]}
    assert after[(2026, 10)] == 30000 + 15000                               # salary + the bank money that arrived
    assert after[(2026, 8)] == 30000 and all(x["income_from"] == "statement" for x in o["timeline"])
    assert client.put("/me/payees", headers=h, json={"key": bank["key"], "tag": "housing"}).status_code == 400
    client.delete("/me/payees?key=in:standard%20chartered%20bank", headers=h)
    assert {x["income"] for x in client.get("/me/overview", headers=h).get_json()["timeline"]} == {30000}


def test_a_bank_that_mixes_pay_and_own_money_never_inflates_income(client, monkeypatch):
    h = _statement_user(client, monkeypatch, incomes=[{"name": "Allowance", "amount": 40000}])
    _import(client, h, _upload(client, h, monkeypatch).get_json())
    client.put("/me/payees", headers=h, json={"key": "in:standard chartered bank", "tag": "mixed"})
    t = {(x["year"], x["month"]): x["income"] for x in client.get("/me/overview", headers=h).get_json()["timeline"]}
    assert t[(2026, 8)] == 30000                 # only the 30,000 salary arrived: less than the 40,000 plan
    assert t[(2026, 10)] == 40000                # salary 30,000 + bank 15,000 = 45,000, capped at the plan


def test_admin_page_is_for_admins_only_and_shows_no_personal_finances(client, monkeypatch):
    monkeypatch.setenv("ADMIN_EMAILS", "boss@example.com")
    user = _student(client)                                  # kevin@example.com, with spending
    assert client.get("/admin/overview", headers=user).status_code == 403
    assert client.get("/me/role", headers=user).get_json()["admin"] is False
    boss = signup(client, "boss@example.com")
    assert client.get("/me/role", headers=boss).get_json()["admin"] is True
    r = client.get("/admin/overview", headers=boss)
    assert r.status_code == 200
    d = r.get_json()
    assert d["users"]["total"] == 2 and d["users"]["with_household"] == 1 and d["users"]["records"] == 9
    assert any(m["name"].startswith("Financial state") and m["present"] for m in d["models"])
    kevin = next(u for u in d["recent_users"] if u["records"] == 9)
    assert kevin["email"] == "k***@example.com"
    assert "kevin@example.com" not in r.get_data(as_text=True)
    assert "4000" not in r.get_data(as_text=True)                # no amounts at all


def test_why_this_score_explains_the_dashboard_and_a_scenario(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    score = client.get("/me/overview", headers=h).get_json()["score"]
    now = client.post("/me/explain", headers=h, json={}).get_json()
    assert abs(now["now"]["score"] - score) <= 1 and len(now["now"]["parts"]) == 6 and "after" not in now
    loan = client.post("/me/explain", headers=h, json={"preset": "loan", "amount": 50000, "months": 12,
                                                        "annual_rate": 14}).get_json()
    assert loan["after"]["score"] <= loan["now"]["score"] and loan["moved"] and loan["title"]
    assert client.post("/me/explain", headers=h, json={"preset": "savings_goal", "target": 3000,
                                                        "months": 3}).status_code == 400


def test_dashboard_warns_when_a_good_score_follows_a_fragile_year(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Allowance", "amount": 30000}]})
    for m in range(1, 11):                                    # Jan-Jul over the allowance, Aug-Oct calm
        client.post("/me/transactions", headers=h, json=[
            {"date": f"2026-{m:02d}-03", "amount": 33000 if m <= 7 else 15000, "category": "food_groceries"}])
    o = client.get("/me/overview", headers=h).get_json()
    assert o["track_record"]["overspent_months"] == 7 and o["track_record"]["fragile"]
    assert o["score"] >= 56 and any("7 of the last 10 months" in n for n in o["notes"])


def test_the_hosted_server_refuses_to_start_without_a_real_secret_key(monkeypatch):
    monkeypatch.setenv("RENDER", "true")
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(RuntimeError):
        store.init("sqlite://")
    monkeypatch.setenv("SECRET_KEY", "dev-only-change-me")
    with pytest.raises(RuntimeError):
        store.init("sqlite://")
    monkeypatch.setenv("SECRET_KEY", "x" * 64)
    store.init("sqlite://")                                  # a real key: starts


def test_unexpected_errors_are_plain_json_and_unknown_pages_too(client, monkeypatch):
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 20000}]})
    monkeypatch.setattr(store, "household_picture", lambda *a: 1 / 0)
    r = client.get("/me/overview", headers=h)
    assert r.status_code == 500 and "went wrong on our side" in r.get_json()["error"]
    assert "Traceback" not in r.get_data(as_text=True)
    assert client.get("/no-such-page").get_json()["error"] == "that page does not exist"


def test_statements_need_consent_to_the_current_privacy_notice(client):
    r = client.post("/auth/register", json={"email": "new@example.com", "password": "strong-pass-1"})
    h = {"Authorization": f"Bearer {r.get_json()['token']}"}
    notice = client.get("/privacy").get_json()                         # public: shown before signing up
    assert notice["version"] and len(notice["sections"]) >= 6
    assert client.get("/me/consent", headers=h).get_json()["accepted"] is False
    blocked = client.post("/me/statements/preview", headers=h, data={})
    assert blocked.status_code == 403 and blocked.get_json()["consent_required"]
    assert client.post("/me/consent", headers=h, json={"accept": True, "version": "old"}).status_code == 400
    assert client.post("/me/consent", headers=h, json={"accept": True, "version": notice["version"]}).status_code == 200
    assert client.get("/me/consent", headers=h).get_json()["accepted"] is True
    assert client.post("/me/statements/preview", headers=h, data={}).status_code == 400   # past consent: no file


def test_old_users_table_gets_the_consent_columns(tmp_path):
    from sqlalchemy import create_engine, text
    url = f"sqlite:///{tmp_path / 'old.db'}"
    with create_engine(url).begin() as conn:
        conn.execute(text("CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(254), "
                          "password_hash VARCHAR(255), created_at TIMESTAMP)"))
        conn.execute(text("INSERT INTO users (email, password_hash) VALUES ('a@b.co', 'x')"))
    store.init(url)
    with store.session() as s:
        u = s.scalar(store.select(store.User))
        assert u.email == "a@b.co" and u.consent_version is None


def test_spending_comes_as_a_month_summary_and_one_month_at_a_time(client):
    h = signup(client)
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-09-03", "amount": 1000, "category": "food_groceries"},
        {"date": "2026-10-01", "amount": 500, "category": "transport"},
        {"date": "2026-10-31", "amount": 300, "category": "transport"},
        {"date": "2026-10-15", "amount": 9000, "category": "entertainment", "one_off": True}])
    s = client.get("/me/transactions/summary", headers=h).get_json()
    assert [(m["year"], m["month"]) for m in s["months"]] == [(2026, 10), (2026, 9)] and not s["has_statement"]
    oct_ = s["months"][0]
    assert oct_["count"] == 3 and oct_["total"] == 800 and oct_["one_off"] == 9000
    assert oct_["by_category"] == {"transport": 800}
    got = client.get("/me/transactions?month=2026-10", headers=h).get_json()["transactions"]
    assert len(got) == 3 and {t["date"][:7] for t in got} == {"2026-10"}
    assert client.get("/me/transactions?month=2026-12", headers=h).get_json()["transactions"] == []
    assert client.get("/me/transactions?month=oct", headers=h).status_code == 400
    assert len(client.get("/me/transactions", headers=h).get_json()["transactions"]) == 4


def test_changing_the_password_needs_the_current_one_and_logs_out_other_devices(client):
    phone = signup(client)
    laptop = {"Authorization": f"Bearer {client.post('/auth/login', json={'email': 'kevin@example.com', 'password': 'strong-pass-1'}).get_json()['token']}"}
    assert client.post("/me/password", headers=phone, json={"current": "wrong-one", "new": "another-pass-2"}).status_code == 403
    assert client.post("/me/password", headers=phone, json={"current": "strong-pass-1", "new": "short"}).status_code == 400
    assert client.post("/me/password", headers=phone, json={"current": "strong-pass-1", "new": "strong-pass-1"}).status_code == 400
    r = client.post("/me/password", headers=phone, json={"current": "strong-pass-1", "new": "another-pass-2"})
    assert r.status_code == 200
    phone = {"Authorization": f"Bearer {r.get_json()['token']}"}
    assert client.get("/me/consent", headers=phone).status_code == 200            # this device carries on
    assert client.get("/me/consent", headers=laptop).status_code == 401            # the other one is logged out
    assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "strong-pass-1"}).status_code == 401
    assert client.post("/auth/login", json={"email": "kevin@example.com", "password": "another-pass-2"}).status_code == 200


def test_a_deleted_accounts_token_stops_working(client):
    h = signup(client)
    assert client.delete("/me", headers=h).status_code == 200
    assert client.get("/me/transactions", headers=h).status_code == 401


def test_typed_in_payments_can_be_edited_but_statement_figures_cannot(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    mine, stmt = client.post("/me/transactions", headers=h, json=[
        {"date": "2026-10-03", "amount": 500, "category": "transport", "description": "matatu"},
        {"date": "2026-10-04", "amount": 179000, "category": "entertainment", "source": "mpesa"}]).get_json()["transactions"]
    r = client.patch(f"/me/transactions/{mine['id']}", headers=h,
                     json={"amount": 650, "date": "2026-10-05", "description": "matatu to town", "category": "transport"})
    assert r.status_code == 200
    got = client.get("/me/transactions?month=2026-10", headers=h).get_json()["transactions"]
    edited = next(t for t in got if t["id"] == mine["id"])
    assert (edited["amount"], edited["date"], edited["description"]) == (650, "2026-10-05", "matatu to town")
    assert client.patch(f"/me/transactions/{mine['id']}", headers=h, json={"date": "2026-12-01"}).status_code == 400
    assert client.patch(f"/me/transactions/{mine['id']}", headers=h, json={"amount": 0}).status_code == 400
    assert client.patch(f"/me/transactions/{stmt['id']}", headers=h, json={"amount": 1}).status_code == 400
    assert client.patch(f"/me/transactions/{stmt['id']}", headers=h, json={"one_off": True}).status_code == 200
    s = client.get("/me/transactions/summary", headers=h).get_json()["months"][0]
    assert s["one_off"] == 179000 and s["total"] == 650
    assert client.patch(f"/me/transactions/{mine['id']}", headers=h, json={}).status_code == 400


def test_overview_has_a_three_month_outlook_with_ranges(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)                                                  # Aug-Oct recorded, today in November
    o = client.get("/me/overview", headers=h).get_json()
    assert [(f["year"], f["month"]) for f in o["outlook"]] == [(2026, 11), (2026, 12), (2027, 1)]
    assert [f["ahead"] for f in o["outlook"]] == [1, 2, 3]
    assert o["outlook"][0]["total"] == o["forecast"]["total"]
    for f in o["outlook"]:
        assert f["total"] > 0 and f["range"]["low"] <= f["total"] <= f["range"]["high"]
    width = [f["range"]["high"] - f["range"]["low"] for f in o["outlook"]]
    assert width[2] >= width[0]                                             # further ahead, less sure


def test_old_records_count_as_further_ahead(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2027, 1, 10))
    h = _student(client)                                                  # last records October: January is 3 ahead
    o = client.get("/me/overview", headers=h).get_json()
    assert [f["ahead"] for f in o["outlook"]] == [3, 3, 3]


def test_a_costly_month_ahead_gets_a_note(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 3, "dependants": 1,
                                                "incomes": [{"name": "Pay", "amount": 30000}]})
    for m in range(1, 11):                                   # school fees of 20,000 in January, May and September
        rows = [{"date": f"2026-{m:02d}-03", "amount": 24000, "category": "food_groceries"}]
        if m in (1, 5, 9):
            rows.append({"date": f"2026-{m:02d}-05", "amount": 20000, "category": "school_fees"})
        client.post("/me/transactions", headers=h, json=rows)
    o = client.get("/me/overview", headers=h).get_json()
    jan = o["outlook"][2]
    assert (jan["year"], jan["month"]) == (2027, 1) and jan["school_fees"] >= 20000 and jan["total"] > 30000
    assert any(n.startswith("January is expected to cost") and "school fees" in n for n in o["notes"])


def test_paying_a_bill_moves_its_due_date_and_the_dashboard_lists_what_is_due(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 5))
    h = _student(client)
    client.put("/me/commitments", headers=h, json={"obligations": [
        {"name": "Rent", "amount": 4000, "category": "housing", "next_due": "2026-11-03"},
        {"name": "Fees", "amount": 15000, "frequency": "termly", "category": "school_fees", "next_due": "2027-01-06"},
        {"name": "Chama", "amount": 500, "next_due": "2026-11-09"}], "debts": [], "goals": []})
    o = client.get("/me/overview", headers=h).get_json()
    assert [(b["name"], b["status"], b["index"]) for b in o["bills_due"]] == [("Rent", "overdue", 0),
                                                                          ("Chama", "due_soon", 2)]
    r = client.post("/me/commitments/paid", headers=h, json={"index": 0}).get_json()
    assert r["next_due"] == "2026-12-03"
    saved = client.get("/me/commitments", headers=h).get_json()["obligations"][0]
    assert saved["last_paid"] == "2026-11-05" and saved["next_due"] == "2026-12-03"
    assert [b["name"] for b in client.get("/me/overview", headers=h).get_json()["bills_due"]] == ["Chama"]
    assert client.post("/me/commitments/paid", headers=h, json={"index": 9}).status_code == 400


def test_a_goal_that_cannot_be_reached_in_time_is_flagged(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 5))
    h = _student(client)                                     # income 12,000, spends about 8,500: 3,500 to put aside
    client.put("/me/commitments", headers=h, json={"obligations": [], "debts": [], "goals": [
        {"name": "Trip", "target": 6000, "deadline": "2026-12"},              # 6,000 a month: too much
        {"name": "Shoes", "target": 1000, "deadline": "2027-05"}]})
    o = client.get("/me/overview", headers=h).get_json()
    trip = o["goals_at_risk"][0]
    assert trip["name"] == "Trip" and trip["monthly_needed_KES"] == 6000 and trip["realistic_months"] == 2
    assert any(n.startswith("To reach Trip in 1 month(s)") for n in o["notes"])


def test_lifestyle_shows_shares_of_income_with_simple_guides_and_betting(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 5))
    h = _student(client)                                     # rent 4,000 of 12,000; nothing saved
    with store.session() as s:
        uid = s.scalar(store.select(store.User)).id
        for m in (8, 9, 10):
            s.add(store.Transaction(user_id=uid, day=store.date(2026, m, 20), amount=300, category="entertainment",
                                    source="mpesa", label="Betting", payee="SportPesa"))
        s.commit()
    rows = {r["key"]: r for r in client.get("/me/overview", headers=h).get_json()["lifestyle"]}
    assert rows["housing"]["share"] == pytest.approx(4000 / 12000, abs=0.001) and rows["housing"]["status"] == "high"
    assert rows["savings"]["status"] == "low" and rows["savings"]["KES"] == 0
    assert rows["betting"]["KES"] == 300 and "loan_repayment" not in rows


def test_budget_warnings_flag_lines_running_out_ahead_of_the_calendar():
    cats = ["transport", "food_groceries", "entertainment", "airtime_data"]
    limits = {"transport": 3000, "food_groceries": 10000, "entertainment": 1000, "airtime_data": 500}
    spent = {"transport": 2550, "food_groceries": 5000, "entertainment": 1200, "airtime_data": 400}
    w = store.budget_warnings(limits, spent, store.date(2026, 11, 14), cats)           # 14 of 30 days gone
    assert [x["category"] for x in w] == ["entertainment", "transport", "airtime_data"]
    assert w[0]["over"] and not w[1]["over"] and w[1]["days_left"] == 17
    assert w[1]["pace_KES"] == round(2550 / (14 / 30))
    late = store.budget_warnings(limits, spent, store.date(2026, 11, 28), cats)        # near month end: on track
    assert [x["category"] for x in late] == ["entertainment"]


def test_dashboard_and_budget_screen_show_budget_warnings(client, monkeypatch):
    monkeypatch.setattr(store, "user_forecast_model", lambda: None)
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 10))
    h = _student(client)
    client.put("/me/budgets/2026/11", headers=h, json={"budget": {"transport": 1000, "food_groceries": 4000}})
    client.post("/me/transactions", headers=h, json=[{"date": "2026-11-03", "amount": 950, "category": "transport"}])
    o = client.get("/me/overview", headers=h).get_json()
    assert [w["category"] for w in o["budget_warnings"]] == ["transport"]
    plan = client.get("/me/budget-plan", headers=h).get_json()
    assert "warnings" in plan and [w["category"] for w in plan["warnings"]] == ["transport"]


def test_download_my_data_has_everything_and_only_mine(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    other = signup(client, "someone@example.com")
    client.post("/me/transactions", headers=other, json=[{"date": "2026-10-01", "amount": 77777, "category": "transport"}])
    client.put("/me/commitments", headers=h, json={"obligations": [{"name": "Rent", "amount": 4000, "category": "housing"}],
                                                   "debts": [], "goals": []})
    client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "entertainment", "amount": 500})
    d = client.get("/me/export", headers=h).get_json()
    assert d["account"]["email"] == "kevin@example.com" and d["account"]["privacy_notice_agreed"]
    assert d["household"]["household_size"] == 1 and d["income_sources"][0]["amount"] == 12000
    assert len(d["spending"]) == 9 and all(t["amount"] != 77777 for t in d["spending"])
    assert d["commitments"]["obligations"][0]["name"] == "Rent" and len(d["affordability_checks"]) == 1
    assert "password" not in str(d).lower().replace("passwords are", "")


# ---------- bad input can never break an account (audit P0: A-01, A-02, A-03, A-07) ----------

def test_unreal_numbers_are_refused_and_the_dashboard_survives(client):
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 30000}]})
    for bad in ("Infinity", "NaN", 1e15):
        r = client.post("/me/transactions", headers=h, json={"date": "2026-10-05", "amount": bad, "category": "transport"})
        assert r.status_code == 400, bad
    raw = '{"date": "2026-10-05", "amount": Infinity, "category": "transport"}'      # a bare JSON literal
    assert client.post("/me/transactions", headers=h, data=raw, content_type="application/json").status_code == 400
    assert client.get("/me/overview", headers=h).status_code == 200


def test_spending_dates_and_batch_size_are_bounded(client):
    h = signup(client)
    for day in ("1901-01-01", "2099-01-01"):
        r = client.post("/me/transactions", headers=h, json={"date": day, "amount": 100, "category": "transport"})
        assert r.status_code == 400, day
    many = [{"date": "2026-10-05", "amount": 1, "category": "transport"}] * 2001
    assert client.post("/me/transactions", headers=h, json=many).status_code == 400


def test_a_junk_budget_is_refused(client):
    h = signup(client)
    for body in ({"budget": {"transport": "lots"}}, {"budget": {"pets": 100}}, {"budget": {"food_groceries": -5}}, {}):
        assert client.put("/me/budgets/2026/11", headers=h, json=body).status_code == 400, body


def test_a_budget_saved_before_validation_cannot_break_the_dashboard(client):
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 30000}]})
    client.post("/me/transactions", headers=h, json={"date": "2026-10-05", "amount": 9000, "category": "food_groceries"})
    with store.session() as s:                                      # an old row written straight to the database
        user = s.scalar(store.select(store.User))
        s.add(store.Budget(user_id=user.id, year=2026, month=11, data={"budget": {"transport": "lots"}}))
        s.commit()
    assert client.get("/me/overview", headers=h).status_code == 200
    assert client.get("/me/budget-plan", headers=h).status_code == 200


def test_only_rows_read_from_the_statement_can_be_imported(client, monkeypatch):
    h = signup(client)
    prev = _upload(client, h, monkeypatch).get_json()
    forged = [dict(prev["transactions"][0], amount=999999)]               # amount changed after the preview
    r = client.post("/me/statements/import", headers=h, json={"transactions": forged, "period": prev["period"]})
    assert r.status_code == 400 and "upload it again" in r.get_json()["error"]
    other = signup(client, "other@example.com")                             # another user's preview rows
    r = client.post("/me/statements/import", headers=other, json={"transactions": prev["transactions"]})
    assert r.status_code == 400
    # the user's own choices are not signed, so marking a one-off still works
    rows = [dict(t, one_off=True) if i == 0 else t for i, t in enumerate(prev["transactions"])]
    assert client.post("/me/statements/import", headers=h, json={"transactions": rows,
                                                                 "period": prev["period"]}).status_code == 200


# ---------- sessions and lockout (audit A-05, A-06, A-08) ----------

def test_logging_out_stops_that_token_and_everywhere_stops_all(client):
    phone = signup(client)
    r = client.post("/auth/login", json={"email": "kevin@example.com", "password": "strong-pass-1"})
    laptop = {"Authorization": f"Bearer {r.get_json()['token']}"}
    assert client.post("/auth/logout", headers=phone).status_code == 200
    assert client.get("/me/profile", headers=phone).status_code == 401          # this device: logged out
    assert client.get("/me/profile", headers=laptop).status_code != 401         # the other: still in
    assert client.post("/auth/logout", headers=laptop, json={"everywhere": True}).status_code == 200
    assert client.get("/me/profile", headers=laptop).status_code == 401


def test_a_stranger_cannot_lock_someone_out(client):
    signup(client)
    stranger = {"CF-Connecting-IP": "203.0.113.9"}
    for _ in range(6):
        client.post("/auth/login", headers=stranger, json={"email": "kevin@example.com", "password": "guess"})
    owner = client.post("/auth/login", headers={"CF-Connecting-IP": "198.51.100.4"},
                        json={"email": "kevin@example.com", "password": "strong-pass-1"})
    assert owner.status_code == 200


def test_engine_endpoints_need_a_login(client):
    assert client.post("/affordability", json={}).status_code == 401
    assert client.post("/budget", json={}).status_code == 401
    assert client.post("/commitments", json={}).status_code == 401


# ---------- budget forecast: the next three months against the budget ----------

def _fees_household(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 3, "dependants": 1, "savingsBalance": 4000,
                                               "incomes": [{"name": "Pay", "amount": 30000}]})
    client.put("/me/commitments", headers=h, json={"obligations": [
        {"name": "Rent", "category": "housing", "amount": 12000, "frequency": "monthly"},
        {"name": "School fees", "category": "school_fees", "amount": 15000, "frequency": "termly"}]})
    rows = [{"date": f"2026-{mo:02d}-05", "amount": amt, "category": cat} for mo in (8, 9, 10)
            for cat, amt in (("housing", 12000), ("food_groceries", 7500), ("transport", 4200),
                             ("utilities", 1800), ("entertainment", 1500))]
    client.post("/me/transactions", headers=h, json=rows + [{"date": "2026-09-03", "amount": 15000,
                                                             "category": "school_fees"}])
    return h


def test_budget_forecast_follows_the_money_for_three_months(client, monkeypatch):
    d = client.get("/me/budget-forecast", headers=_fees_household(client, monkeypatch)).get_json()
    assert [(m["year"], m["month"]) for m in d["months"]] == [(2026, 11), (2026, 12), (2027, 1)]
    assert d["months"][2]["school_fees"] > 0                    # January is a fee month
    assert d["based_on"] == "records" and d["status"] in ("fine", "tight", "runs_out")
    for m, p in zip(d["months"], d["savings_path"]):            # the path adds up month by month
        assert m["left_over"] == m["income"] - m["spending"]
    assert d["savings_path"][0]["usual_pace"] == 4000 + d["months"][0]["left_over"]
    if d["status"] == "runs_out":
        assert "runs out" in d["notes"][0]


def test_budget_forecast_works_on_day_one_and_says_so(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 45000}],
                                               "estimates": {"housing": 15000, "food_groceries": 8000}})
    d = client.get("/me/budget-forecast", headers=h).get_json()
    assert d["has_data"] and d["based_on"] == "setup" and len(d["months"]) == 3
    assert any("setup" in n for n in d["notes"])


def test_a_check_shows_the_budget_now_and_after_side_by_side(client, monkeypatch):
    h = _fees_household(client, monkeypatch)
    r = client.post("/me/afford", headers=h, json={"preset": "move_house", "new_rent": 18000}).get_json()
    lines = {x["category"]: x for x in r["budgets"]["lines"]}
    assert lines["housing"]["now"] == 12000 and lines["housing"]["after"] == 18000
    assert sum(x["now"] for x in lines.values()) == sum(x["after"] for x in lines.values()) == 30000
    r = client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "transport", "amount": 2000})
    lines = {x["category"]: x for x in r.get_json()["budgets"]["lines"]}
    assert lines["transport"]["after"] > lines["transport"]["now"] + 1000          # the new cost has its own line
    assert all(x["after"] > 0 for x in lines.values() if x["now"] > 0)            # no other line is wiped out


# ---------- plan a change: upfront + monthly + money it brings in ----------

def _earner(client, monkeypatch, savings=60000):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 2, "savingsBalance": savings,
                                               "incomes": [{"name": "Pay", "amount": 45000}]})
    client.post("/me/transactions", headers=h, json=[
        {"date": f"2026-{mo:02d}-05", "amount": amt, "category": cat} for mo in (7, 8, 9, 10)
        for cat, amt in (("housing", 12000), ("food_groceries", 8000), ("transport", 4500), ("utilities", 2000),
                         ("entertainment", 2500), ("mobile_money_transfers", 3000), ("savings", 4000))])
    return h


def test_a_plan_with_instalments_is_checked_while_paying_and_after(client, monkeypatch):
    h = _earner(client, monkeypatch)
    boda = {"preset": "plan", "label": "Boda boda", "income": 18000,
            "upfront": {"amount": 160000, "pay": "instalments", "months": 18, "annual_rate": 14},
            "costs": [{"category": "transport", "amount": 6000, "label": "Fuel and repairs"}]}
    r = client.post("/me/afford", headers=h, json=boda).get_json()
    assert [p["label"] for p in r["phases"]] == ["While you pay the instalments", "After the instalments"]
    assert r["score_after"] == min(p["score_after"] for p in r["phases"])      # the harder period decides
    assert r["instalment_per_month_KES"] > 160000 / 18                         # interest included
    sid = r["id"]
    assert client.post(f"/me/scenarios/{sid}/apply", headers=h, json={}).status_code == 200
    assert client.get("/me/commitments", headers=h).get_json()["debts"][0]["name"] == "Boda boda"


def test_a_plan_paid_from_savings_needs_the_savings(client, monkeypatch):
    h = _earner(client, monkeypatch, savings=20000)
    car = {"preset": "plan", "label": "Car", "upfront": {"amount": 900000, "pay": "savings"}}
    r = client.post("/me/afford", headers=h, json=car).get_json()
    assert r["verdict"] == "Not affordable" and r["upfront_short_KES"] == 880000
    fees = {"preset": "plan", "label": "Boarding school", "costs": [{"category": "school_fees", "amount": 28000,
                                                                     "per": "term"}]}
    r = client.post("/me/afford", headers=h, json=fees).get_json()
    assert any("each term" in x and "7,000 a month" in x for x in r["reasons"])
    assert client.post("/me/afford", headers=h, json={"preset": "plan"}).status_code == 400


# ---------- low month: income that varies ----------

def _irregular_earner(client, monkeypatch):
    h = _earner(client, monkeypatch, savings=10000)
    with store.session() as s:                    # pay that actually arrived, as a tagged statement would give
        uid = s.scalar(store.select(store.User)).id
        for mo, kes in ((7, 45000), (8, 45000), (9, 27000), (10, 45000)):
            s.add(store.MoneyIn(user_id=uid, day=store.date(2026, mo, 28), amount=kes, kind="income",
                                payee="EMPLOYER", payee_key="in:employer", label="Salary", ref=f"pay-{mo}"))
        s.add(store.StatementRule(user_id=uid, key="in:employer", choice="income"))
        s.commit()
    return h


def test_a_check_is_repeated_on_the_low_month(client, monkeypatch):
    h = _irregular_earner(client, monkeypatch)
    r = client.post("/me/afford", headers=h, json={"preset": "move_house", "new_rent": 18000}).get_json()
    assert r["income_pattern"] == "varies"
    lm = r["low_month"]
    assert lm["income_KES"] == 27000 and "September 2026" in lm["when"]
    assert lm["left_over_KES"] < r["after"]["left_over_KES"]                   # a low month is harder
    bf = client.get("/me/budget-forecast", headers=h).get_json()
    assert bf["income_pattern"] == "varies" and len(bf["low_month"]["path"]) == 3


def test_the_low_month_can_come_from_the_setup_answer(client, monkeypatch):
    h = _earner(client, monkeypatch)
    client.put("/me/profile", headers=h, json={"householdSize": 2, "incomes": [{"name": "Pay", "amount": 45000}],
                                               "incomeLow": 20000})
    assert client.get("/me/profile", headers=h).get_json()["incomeLow"] == 20000
    r = client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "entertainment",
                                                   "amount": 3000}).get_json()
    assert r["low_month"]["from"] == "you" and r["low_month"]["income_KES"] == 20000
    client.put("/me/profile", headers=h, json={"householdSize": 2, "incomes": [{"name": "Pay", "amount": 45000}]})
    assert client.get("/me/profile", headers=h).get_json()["incomeLow"] == 20000   # kept when not sent


# ---------- borrowing to get through the month ----------

def test_regular_fuliza_and_mobile_loans_are_flagged_but_do_not_change_the_score(client, monkeypatch):
    h = _earner(client, monkeypatch)
    before = client.get("/me/overview", headers=h).get_json()
    assert not (before["borrowing"] or {}).get("flag")
    od = "OD Loan Repayment to 232323 - M-PESA Overdraw"
    rows = [{"date": f"2026-{mo:02d}-{d:02d}", "amount": 600, "category": "loan_repayment", "description": od}
            for mo in (8, 9, 10) for d in (3, 9, 15)]
    rows.append({"date": "2026-10-20", "amount": 2500, "category": "loan_repayment",
                 "description": "Pay Bill to 851900 - TALA KENYA"})
    rows.append({"date": "2026-10-21", "amount": 900, "category": "loan_repayment", "description": "NATALIA SHOP"})
    client.post("/me/transactions", headers=h, json=rows)
    b = client.get("/me/overview", headers=h).get_json()["borrowing"]
    assert b["flag"] and b["fuliza_times"] == 9 and b["months_with"] == 3 and b["lenders"] == ["Tala"]
    r = client.post("/me/afford", headers=h, json={"preset": "new_expense", "category": "entertainment",
                                                   "amount": 2000}).get_json()
    assert any("Fuliza 9 time(s)" in x for x in r["reasons"])


# ---------- goals tracked from savings ----------

def test_savings_count_towards_goals_once_the_user_agrees(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 10, 2))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 40000}]})
    goals = {"goals": [{"name": "Laptop", "target": 60000, "saved": 5000, "deadline": "2027-03"},
                       {"name": "Trip", "target": 20000, "saved": 0, "deadline": "2027-08"}]}
    client.put("/me/commitments", headers=h, json=goals)                 # set on 2 October
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-09-20", "amount": 9999, "category": "savings"},           # before the goals: not counted
        {"date": "2026-10-10", "amount": 4000, "category": "savings"},
        {"date": "2026-10-25", "amount": 4500, "category": "savings"},
        {"date": "2026-10-05", "amount": 9000, "category": "food_groceries"}])
    ov = client.get("/me/overview", headers=h).get_json()
    assert "goal_suggestions" in ov, ov
    ask = ov["goal_suggestions"]
    assert [(x["name"], x["found_KES"]) for x in ask] == [("Laptop", 8500), ("Trip", 8500)]
    client.post("/me/goals/track", headers=h, json={"name": "Laptop", "count": True})
    client.post("/me/goals/track", headers=h, json={"name": "Trip", "count": True})
    got = {gl["name"]: gl for gl in client.get("/me/commitments", headers=h).get_json()["goals"]}
    assert got["Laptop"]["saved"] == 5000 and got["Laptop"]["counted_KES"] == 8500    # earliest deadline first
    assert got["Trip"]["counted_KES"] == 0                                            # each deposit counts once
    # The app saves goals back without the tracking fields: they are kept, and nothing is counted twice.
    client.put("/me/commitments", headers=h, json={"goals": [{k: v for k, v in gl.items() if k in
                                                              ("name", "target", "saved", "deadline")}
                                                             for gl in got.values()]})
    again = {gl["name"]: gl for gl in client.get("/me/commitments", headers=h).get_json()["goals"]}
    assert again["Laptop"]["counted_KES"] == 8500 and again["Laptop"]["tracking_from"] == "2026-10"


# ---------- pasted M-PESA messages ----------

SMS = ("TK51AB2C3D Confirmed. Ksh1,240.00 paid to NAIVAS SUPERMARKET. on 5/11/26 at 1:15 PM.New M-PESA balance is "
       "Ksh3,210.50. Transaction cost, Ksh0.00. "
       "TK52AB2C3E Confirmed. Ksh500.00 sent to JOHN MWANGI 0712345678 on 6/11/26 at 8:02 AM. New M-PESA balance "
       "is Ksh2,703.50. Transaction cost, Ksh7.00. "
       "TK59AB2C3M Confirmed. Ksh1,000.00 transferred to M-Shwari account on 8/11/26 at 6:00 PM. M-PESA balance is "
       "Ksh1,703.50. Your OTP is 12345.")


def test_pasted_messages_are_read_like_a_statement_and_kept_with_typed_records(client, monkeypatch):
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = signup(client)
    client.put("/me/profile", headers=h, json={"householdSize": 1, "incomes": [{"name": "Pay", "amount": 30000}]})
    client.post("/me/transactions", headers=h, json={"date": "2026-11-02", "amount": 300, "category": "transport"})
    prev = client.post("/me/messages/preview", headers=h, json={"text": SMS}).get_json()
    by = {t["label"]: t for t in prev["transactions"]}
    assert by["Food & groceries"]["amount"] == 1240 and by["Sent to John Mwangi"]["category"] == "mobile_money_transfers"
    assert by["M-PESA charges"]["amount"] == 7 and prev["origin"] == "messages"
    body = {"transactions": prev["transactions"], "origin": "messages"}
    assert client.post("/me/statements/import", headers=h, json=body).status_code == 200
    assert client.post("/me/statements/import", headers=h, json=body).get_json()["imported"] == 0   # pasted twice
    txs = client.get("/me/transactions", headers=h).get_json()["transactions"]
    assert any(t["source"] == "manual" for t in txs)                                # typed records kept
    assert sum(t["amount"] for t in txs if t["category"] == "savings") == 1000
    assert client.get("/me/overview", headers=h).get_json()["records_until"] == "2026-11-08"
    bad = client.post("/me/messages/preview", headers=h, json={"text": "hello there"})
    assert bad.status_code == 400 and "No M-PESA messages" in bad.get_json()["error"]


# ---------- forecast check: what was expected against what happened ----------

def test_a_forecast_made_before_the_month_is_checked_once_it_is_recorded(client, monkeypatch):
    h = _earner(client, monkeypatch)                                    # records July to October
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 10, 20))
    client.get("/me/overview", headers=h)                               # November is forecast in October
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 12, 3))
    client.post("/me/transactions", headers=h, json=[
        {"date": "2026-11-05", "amount": amt, "category": cat}
        for cat, amt in (("housing", 12000), ("food_groceries", 9000), ("transport", 5000), ("utilities", 2000))])
    ov = client.get("/me/overview", headers=h).get_json()
    nov = next(c for c in ov["forecast_checks"] if c["month"] == 11)
    assert nov["made_before"] and nov["actual"] == 28000 and nov["diff"] == 28000 - nov["expected"]
    assert any(n.startswith("November: we expected") for n in ov["notes"])
    with store.session() as s:                                          # pooled for the admin view
        assert s.scalar(store.select(store.ForecastSnapshot).where(store.ForecastSnapshot.month == 11)).actual == 28000
