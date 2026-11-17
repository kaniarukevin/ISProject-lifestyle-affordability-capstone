# Tosha: Personalised Household Lifestyle Affordability and Budget Recommendation System

Final-year project, BSc Computer Science, Strathmore University.
Student: Kevin Kaniaru (164806). Supervisor: Eunice Manyasi.

Tosha helps a Kenyan household answer one question: **can we afford this lifestyle change before we commit to it?**
It reads an M-PESA statement, pasted M-PESA messages or typed-in spending. From that it:

- works out the household's financial state (Stable, Strained or Critical);
- forecasts spending one to three months ahead;
- recommends a monthly budget;
- scores a planned change, such as moving house, a loan, a new baby or a purchase, before it happens.

| | Link |
|---|---|
| Web app | https://tosha-ke.netlify.app |
| API (backend and Web Masters forecast service) | https://budget-forecast-cdc0.onrender.com |

---

## Contents

1. [For Web Masters (U-CS 37): the forecast service](#1-for-web-masters-u-cs-37-the-forecast-service)
2. [How the system fits together](#2-how-the-system-fits-together)
3. [Models and results](#3-models-and-results)
4. [Repository map](#4-repository-map)
5. [Run it locally](#5-run-it-locally)
6. [Deploy](#6-deploy)
7. [API reference (the app)](#7-api-reference-the-app)
8. [Data, privacy and limitations](#8-data-privacy-and-limitations)
9. [Further documents](#9-further-documents)

---

## 1. For Web Masters (U-CS 37): the forecast service

The U-CS 37 deliverable is the budget-forecast API. Only two routes are part of the contract, and neither needs a login.

```
GET  https://budget-forecast-cdc0.onrender.com/health
POST https://budget-forecast-cdc0.onrender.com/forecast
```

Example request:

```bash
curl -X POST https://budget-forecast-cdc0.onrender.com/forecast \
  -H "Content-Type: application/json" \
  -d '{"userId": "4019964b-c175-41b5-8b80-56513094ec46", "month": 4, "year": 2026}'
```

The response always contains the four agreed fields: `estimatedTotal`, `breakdown`, `confidence` and `riskFlag`.
It also carries three extra fields, `note`, `method` and `monthsOfHistory`.
`userId` may be either the staging `user_id` or the `user_profile_id`.

**Full contract** (fields, how the forecast is made, `riskFlag` rules, errors, accuracy and limitations):
[`backend/README.md`](backend/README.md).

Everything else in this repository (accounts, statements, budgets, affordability) is the capstone app.
It is not part of U-CS 37, and Web Masters does not need it.

---

## 2. How the system fits together

```
M-PESA PDF / pasted SMS / typed entry ──> backend/mpesa.py (verified reading, Kenyan business directory, payee tags)
                                               │
                                               ▼
                              PostgreSQL (Neon) via backend/store.py
                                               │  household_picture(): one view shared by every screen
         ┌─────────────────────┬───────────────┼──────────────────────┬──────────────────────────┐
         ▼                     ▼               ▼                      ▼                          ▼
  Financial state       Spending forecast   Budget              Affordability score        Commitments
  Random Forest         boosted tree,       Random Forest       monotonic gradient         bills, debts, goals
  classifier            1-3 months, ranges  split + rules       boosting + SHAP            (commitments.py)
  (affordability.py)                        (budget.py)         (affordability.py)
         └─────────────────────┴───────────────┬──────────────────────┴──────────────────────────┘
                                               ▼
                             Flask JSON API (backend/app.py + store.py)
                                    │                        │
                                    ▼                        ▼
                 Flutter app (frontend/), web on Netlify     /forecast + /health for Web Masters,
                                                             served from a staging-data snapshot (backend/data/)
```

**Stack:**
- Flutter 3 for the app;
- Python 3.13, Flask and gunicorn for the API;
- scikit-learn for the models;
- PostgreSQL on Neon (SQLite locally and in tests);
- Render hosts the API and Netlify hosts the web app;
- Brevo sends password-reset emails.

---

## 3. Models and results

Every model replaced or kept on the basis of held-out results. The full log, including the experiments that failed, is in
[`docs/experiments.md`](docs/experiments.md). Why each model differs from the proposal is in [`docs/deviations.md`](docs/deviations.md).

| Task | Model in use | Compared with | Held-out result |
|---|---|---|---|
| Financial state | Random Forest classifier | HMM (proposal) | Accuracy 0.799 vs 0.531 |
| Forecast for app users | Gradient-boosted tree with fee-month and December flags | Trailing median | MAE (KES) 9,967 / 10,354 / 11,000 vs 10,719 / 11,738 / 11,791 at 1 / 2 / 3 months; 80% ranges cover 83–85% |
| Web Masters forecast | 75% budget + 25% 12-month median for the total, split by a boosted tree | Median, boosted tree alone, LSTM | MAE 7,931 KES, WAPE 0.106 (median 9,618; LSTM 10,586) |
| Budget (everyday split) | Half Random Forest, half the average Stable split | One-size average split | Error 7,021 vs 7,295 KES per category |
| Affordability score | Monotonic gradient boosting, explained with SHAP | Random Forest (proposal) | 100% monotonic: more income never lowers the score; SHAP values add up to the score |

The LSTM in the proposal was built and tested. It did not beat the boosted tree or the budget blend on 12–18 monthly points per household,
so it is reported in Chapter 5 and is not deployed.

All accuracy figures come from synthetic households (see section 8).

---

## 4. Repository map

| Path | What is there |
|---|---|
| `backend/app.py` | Flask app, the Web Masters `/forecast` and `/health`, the engine endpoints |
| `backend/store.py` | Database models, authentication and every `/me/*` and `/admin/*` route |
| `backend/affordability.py`, `budget.py`, `commitments.py` | The score, budget and commitments engines |
| `backend/mpesa.py`, `kenya_directory.py` | M-PESA statement and SMS reader; Kenyan business directory |
| `backend/model_register.py`, `monitor.py` | Model register shown to admins; request timing and logs |
| `backend/models/` | Trained models the API loads |
| `backend/data/` | Staging-data snapshot used by `/forecast` |
| `frontend/` | Flutter app (screens in `lib/screens`, API client in `lib/services/api.dart`) |
| `data_generation/` | Scripts 01–09 that build the KIHBS-informed synthetic dataset and train the HMM |
| `notebooks/` | Exploration, model comparison and state detection |
| `scripts/` | Experiments behind `docs/experiments.md`, model training, `pull_staging_data.py` |
| `models/` | Earlier models (HMM, state classifier), kept for the report |
| `tests/` | Backend tests (pytest) |
| `docs/` | `experiments.md` and `deviations.md` |
| `CHANGELOG.md` | Changes by pull request |

---

## 5. Run it locally

**Backend** (Python 3.13 or newer):

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
python app.py
```

- It listens on http://localhost:8000.
- It uses a local SQLite file unless `DATABASE_URL` is set.
- Local settings can go in `backend/.env.local`, which is git-ignored.
- Restart it after any code change, because it does not reload.

**App** (Flutter 3):

```bash
cd frontend
flutter pub get
flutter run -d web-server --web-port 5050 --dart-define=API_URL=http://localhost:8000
```

Then open http://localhost:5050. Without `API_URL` the app talks to the live API on Render.
On macOS, avoid port 5000, which the AirPlay Receiver uses.

**Tests:**

```bash
python3 -m pytest -q          # backend, from the repository root
cd frontend && flutter test   # app
cd frontend && flutter analyze
```

As of 17 Nov 2026: 214 backend tests and 21 Flutter tests pass, and `flutter analyze` is clean.
The GitHub Actions workflow (`.github/workflows/tests.yml`) runs the backend tests on pushes to `main` and on pull requests.

---

## 6. Deploy

**API on Render:**
- root directory `backend`;
- start command `gunicorn app:app --workers 1 --timeout 60`.

Render redeploys `main` automatically, so every merge reaches Web Masters' consumers. Merge only tested changes.

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | PostgreSQL connection string (Neon). Never commit it |
| `SECRET_KEY` | At least 32 random characters. The server refuses to start without it |
| `ADMIN_EMAILS` | Comma-separated emails that may open the admin console |
| `ALLOWED_ORIGINS` | The web app's address(es), for CORS. Server-to-server callers such as Web Masters are not affected |
| `BREVO_API_KEY`, `MAIL_FROM` | Password-reset emails |
| `GOOGLE_CLIENT_ID` | Google sign-in. Leave unset to switch it off |
| `WASAA_EMAIL`, `WASAA_PASSWORD` | Staging API login. Only used if the bundled snapshot is missing |
| `APP_ENV` | Set to `production` on a host other than Render |

**Web app on Netlify:**

```bash
cd frontend
flutter build web --release --pwa-strategy=none
```

Then upload `frontend/build/web` to Netlify. `--pwa-strategy=none` stops browsers from serving testers an old cached version.

---

## 7. API reference (the app)

Everything under `/me` and `/admin` needs `Authorization: Bearer <token>`. The token comes from `/auth/login`,
`/auth/register` or `/auth/google`. Errors are always JSON with a plain `error` message.

| Area | Endpoints |
|---|---|
| Account | `POST /auth/register`, `POST /auth/login`, `POST /auth/google`, `POST /auth/logout` (`{"everywhere": true}` for every device), `POST /auth/forgot`, `POST /auth/reset`, `POST /me/password`, `DELETE /me`, `GET /me/export`, `GET/POST /me/consent`, `GET /privacy`, `GET /me/role` |
| Household and income | `GET/PUT /me/profile`, `POST /me/outside-money`, `POST /me/income-gap/dismiss`, `POST /me/savings`, `PUT/DELETE /me/months/<year>/<month>/income` |
| Spending | `GET/POST /me/transactions`, `PATCH/DELETE /me/transactions/<id>`, `GET /me/transactions/summary`, `GET /me/records`, `GET /me/months` |
| Statements and messages | `POST /me/statements/preview` (PDF in, nothing saved), `POST /me/messages/preview`, `POST /me/statements/import`, `DELETE /me/statements` |
| Payees and money in | `GET/PUT/DELETE /me/payees`, `POST /me/payees/commitment`, `GET /me/money-in`, `PATCH /me/money-in/<id>` |
| Dashboard | `GET /me/overview` (state, score, timeline, outlook, bills due, goals at risk), `POST /me/explain` (why this score), `POST /me/ratings` |
| Budget | `GET /me/budget-plan`, `POST /me/budget-plan/edit`, `POST /me/budget-plan/reset`, `GET /me/budget-forecast`, `GET /me/budgets/history`, `GET/PUT /me/budgets/<year>/<month>` |
| Can I afford it? | `POST /me/afford`, `GET/POST /me/scenarios`, `DELETE /me/scenarios/<id>`, `POST /me/scenarios/<id>/apply` |
| Commitments | `GET/PUT /me/commitments`, `POST /me/commitments/paid`, `POST /me/goals/track` |
| Admin | `GET /admin/overview`, `GET /admin/reports`, `GET /admin/validation`, `GET /admin/performance`, `POST /admin/users/<id>/block`, `DELETE /admin/users/<id>` |
| Engines (login, 60 calls a minute) | `POST /affordability`, `POST /budget`, `POST /commitments`, for trying the models with your own figures |
| Web Masters (U-CS 37) | `GET /health`, `POST /forecast`, see [`backend/README.md`](backend/README.md) |

---

## 8. Data, privacy and limitations

**Data:**
- **The KIHBS-informed synthetic dataset** has 300 households over 12 months and 10 categories. It is built from KIHBS 2015/16
  distributions scaled to 2025 shillings (`data_generation/`), and it trains the app's models. The KIHBS microdata is not redistributed.
- **Web Masters staging data** has 500 households over 18 months and 17 categories. It is synthetic, provided by Web Masters, and
  trains and serves the U-CS 37 forecast. The credentials are kept out of git.
- **Real use:** volunteers' own statements, used with consent, for usability testing only (Chapter 5).

**Privacy:**
- Statements are read in memory and the PDF is never stored.
- Users can download or delete all their data.
- Passwords are salted hashes, and session tokens can be revoked.
- Admins see masked emails and never see amounts.

**Limitations:**
- The accuracy figures are measured on synthetic households, so they show that the models recover the generator's patterns.
  They do not prove accuracy on real households.
- Statement reading supports M-PESA only.
- Tosha gives guidance and is not financial advice.

---

## 9. Further documents

- [`docs/experiments.md`](docs/experiments.md): every experiment, dated, with numbers.
- [`docs/deviations.md`](docs/deviations.md): changes from the proposal, with a requirements traceability table.
- [`backend/README.md`](backend/README.md): the U-CS 37 forecast service contract.
- [`CHANGELOG.md`](CHANGELOG.md): changes by pull request.
