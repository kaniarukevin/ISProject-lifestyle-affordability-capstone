"""Tests for the data layer, on an in-memory SQLite database. Run: python -m pytest tests/test_store.py -q"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import app as svc  # noqa: E402
import store  # noqa: E402


@pytest.fixture()
def client():
    store.init("sqlite://")
    store._ATTEMPTS.clear()
    return svc.app.test_client()


def signup(client, email="kevin@example.com"):
    r = client.post("/auth/register", json={"email": email, "password": "strong-pass-1"})
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
    r = client.post("/affordability", json={"household": {"household_size": 1}, "months": months})
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
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    o = client.get("/me/overview", headers=h).get_json()
    assert o["has_data"] and o["state"] in ("Stable", "Strained", "Critical") and 0 <= o["score"] <= 100
    assert (o["forecast"]["year"], o["forecast"]["month"]) == (2026, 11)
    assert o["forecast"]["method"] == "trailing_median"
    assert abs(o["forecast"]["total"] - 8490) <= 3                    # median of 8480, 8490, 8500
    assert abs(o["forecast"]["breakdown"]["food_groceries"] - 3590) <= 3
    assert o["latest"]["left_over"] == 12000 - (4000 + 3600 + 900) and not o["latest"]["partial"]


def test_sparse_categories_do_not_collapse_the_forecast(client, monkeypatch):
    """Found in testing: one big month and categories used only now and then gave a forecast of KES 0."""
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
    monkeypatch.setattr(store, "_today", lambda: store.date(2026, 11, 15))
    h = _student(client)
    budget = {"housing": 4000, "food_groceries": 3000, "transport": 800}
    client.put("/me/budgets/2026/11", headers=h, json={"budget": budget})
    fc = client.get("/me/overview", headers=h).get_json()["forecast"]
    assert fc["method"] == "blend_budget_median"
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
