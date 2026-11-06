# Personalised Household Lifestyle Affordability and Budget Recommendation System

Final-year project, Strathmore University. Student: Kevin Kaniaru (164806). Supervisor: Eunice Manyasi.

The app answers one question for a Kenyan household: **can we afford this lifestyle change before we commit to it?**
It reads an M-PESA statement (or typed-in spending), finds the household's financial state, forecasts the next
three months, recommends a budget, and scores a planned change (moving house, a loan, a new baby, a purchase)
before it happens.

## How it fits together

```
M-PESA PDF / manual entry ──> backend/mpesa.py (verified reading, Kenyan directory, payee tags)
                                   │
                                   ▼
                      PostgreSQL (Neon) via backend/store.py
                                   │  household_picture(): one view used by every screen
             ┌─────────────────────┼──────────────────────┬─────────────────────────┐
             ▼                     ▼                      ▼                         ▼
   Financial state          Spending forecast       Budget recommendation     Affordability score
   Random Forest            boosted tree, 1-3       Random Forest split       monotonic gradient
   (affordability.py)       months with ranges      (budget.py)               boosting + SHAP
             └─────────────────────┴──────────┬───────────┴─────────────────────────┘
                                              ▼
                              Flask JSON API (backend/app.py)
                                              ▼
                              Flutter app (frontend/), web, Android, iOS
```

Why each model replaced the one in the proposal, with the held-out numbers: `docs/deviations.md`.
Every experiment, including the ones that failed: `docs/experiments.md`.

## Run it locally

Backend (Python 3.13 or newer):

```
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
python app.py
```

It listens on http://localhost:8000 and uses a local SQLite file unless `DATABASE_URL` is set.

App (Flutter 3):

```
cd frontend
flutter pub get
flutter run -d chrome
```

Tests, from the repository root:

```
python3 -m pytest -q
```

GitHub Actions runs the same tests on every push and pull request (`.github/workflows/tests.yml`).

## Settings on the server (Render)

| Variable | What it is |
|---|---|
| `DATABASE_URL` | The PostgreSQL connection string (Neon). Never commit it |
| `SECRET_KEY` | At least 32 random characters; the server refuses to start without it |
| `ADMIN_EMAILS` | Comma-separated emails that may open the admin view |
| `ALLOWED_ORIGINS` | The web app's address(es), for CORS |

## API

Everything under `/me` needs `Authorization: Bearer <token>` from `/auth/login` or `/auth/register`.

| Area | Endpoints |
|---|---|
| Account | `POST /auth/register`, `POST /auth/login`, `POST /auth/logout` (`{"everywhere": true}` for every device), `POST /me/password`, `DELETE /me`, `GET /me/export`, `GET/POST /me/consent`, `GET /privacy`, `GET /me/role` |
| Household | `GET/PUT /me/profile` (incomes, household, savings balance, setup estimates) |
| Spending | `GET/POST /me/transactions`, `PATCH/DELETE /me/transactions/<id>`, `GET /me/transactions/summary`, `GET /me/months` |
| Statements | `POST /me/statements/preview` (PDF in, nothing saved), `POST /me/statements/import`, `DELETE /me/statements`, `GET/PUT/DELETE /me/payees`, `POST /me/payees/commitment` |
| Dashboard | `GET /me/overview` (state, score, timeline, outlook, bills due, goals at risk, lifestyle), `POST /me/explain` (why this score) |
| Budget | `GET /me/budget-plan`, `GET /me/budget-forecast` (next three months against the budget), `GET/PUT /me/budgets/<year>/<month>` |
| Can I afford it? | `POST /me/afford`, `GET/POST /me/scenarios`, `DELETE /me/scenarios/<id>`, `POST /me/scenarios/<id>/apply` |
| Commitments | `GET/PUT /me/commitments`, `POST /me/commitments/paid` |
| Admin | `GET /admin/overview` (service health, model register, masked user list) |
| Engines (login needed) | `POST /affordability`, `POST /budget`, `POST /commitments`, for trying the models with your own figures |
| Web Masters (U-CS 37) | `GET /health`, `POST /forecast`, described in `backend/README.md` |

## Data and privacy

- Statements are read in memory and never stored.
- Users can download or delete all their data.
- The synthetic training households are built from KIHBS 2015/16 distributions, scaled to 2025 shillings (`data_generation/`). KIHBS microdata is not redistributed.
- Accuracy figures are on synthetic households generated from stated assumptions. Real-user validation is described in `docs/deviations.md` (D15).
