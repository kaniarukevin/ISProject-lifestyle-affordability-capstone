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
