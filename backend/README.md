# Budget Forecast Service (Web Masters U-CS 37)

This service estimates a household's spending for a given month, split by category. It also flags whether that
spending is likely to exceed the household's budget.

- **Base URL:** https://budget-forecast-cdc0.onrender.com
- **Routes in the contract:** `GET /health` and `POST /forecast`. Neither needs a login or an API key.
- **Owner:** Kevin Kaniaru (Strathmore University, GitHub `kaniarukevin`). This service is part of his final-year project;
  the project overview is in the [root README](../README.md).

## Quick start

```bash
curl https://budget-forecast-cdc0.onrender.com/health

curl -X POST https://budget-forecast-cdc0.onrender.com/forecast \
  -H "Content-Type: application/json" \
  -d '{"userId": "4019964b-c175-41b5-8b80-56513094ec46", "month": 4, "year": 2026}'
```

## GET /health

It returns 200 whenever the service is up:

```json
{"status": "ok", "dataLoaded": true}
```

`dataLoaded` is `false` for the first few seconds after a start, while the data loads. During that time
`/forecast` waits up to 20 seconds and then returns 503 if the data is still loading.

## POST /forecast

**Request:**

```json
{"userId": "4019964b-c175-41b5-8b80-56513094ec46", "month": 4, "year": 2026}
```

| Field | Type | Notes |
|---|---|---|
| `userId` | string | The staging `user_id`. The `user_profile_id` is also accepted |
| `month` | integer | 1 to 12 |
| `year` | integer | Four digits |

**Response (200)**, a real response from the deployed code (categories shortened):

```json
{
  "estimatedTotal": 110435.13,
  "breakdown": {
    "Airtime and Data": 4772.28,
    "Groceries": 21842.89,
    "Household Help": 7355.79,
    "Rent": 36690.26,
    "Savings": 6013.16,
    "School Fees": 14752.43,
    "Transport": 11808.91,
    "Utilities": 7198.87,
    "Entertainment": 0.0,
    "...": 0.0
  },
  "confidence": 0.91,
  "riskFlag": "LOW",
  "note": null,
  "method": "blend_budget_tree_split",
  "monthsOfHistory": 12
}
```

| Field | Meaning |
|---|---|
| `estimatedTotal` | Forecast spending for the month, in KES. It equals the sum of `breakdown` |
| `breakdown` | Forecast per category, in KES. Every one of the 17 staging categories is always present, with 0.0 where none is expected |
| `confidence` | From 0 to 1, based on how steady the household's monthly totals are and how many of the last 12 months exist. **It is a heuristic, not a probability.** It is 0.1 for the fallbacks |
| `riskFlag` | `LOW`, `MODERATE` or `HIGH` (see below) |
| `note` | A plain-language reason when the forecast is a fallback or the history is short (under 6 months); otherwise `null` |
| `method` | How the forecast was made (see below) |
| `monthsOfHistory` | Months of history used, out of the last 12; 0 for the fallbacks |

The first four fields are the agreed contract and keep these exact names. `note`, `method` and `monthsOfHistory` are extra fields.

## How the forecast is made

The service uses the best information available for the requested month:

| `method` | When | Total | Split across categories |
|---|---|---|---|
| `blend_budget_tree_split` | The month has a budget, and the 3 months before it have history | 75% of this month's budget plus 25% of the 12-month median | Proportions from a gradient-boosted tree |
| `blend_budget_median_split` | The month has a budget, but the tree's inputs are incomplete | As above | Proportions of the 12-month median |
| `blend_last_budget_median_split` | No budget for the month, but there is one for last month | 75% of last month's budget plus 25% of the 12-month median | Proportions of the 12-month median |
| `trailing_median_12m` | History exists but no recent budget | Median monthly spend per category over the 12 months before the month | Same |
| `budget_allocation` | A budget exists but there is no history before the month | The budget | The budget |
| `peer_median` | Neither history nor a budget | Median monthly spend of all households | Same |

A household that is known but has little or no history is **not an error**. It gets a 200 with a low `confidence` and a `note`.

## riskFlag

The forecast is compared with the household's budget for the month, or its latest earlier budget:

| Forecast compared with the budget | `riskFlag` |
|---|---|
| Over 120% | `HIGH` |
| Over 100%, up to 120% | `MODERATE` |
| 100% or under | `LOW` |

- **No budget at all:** last month's actual spending is the reference, and the `note` says so.
- **No reference:** `MODERATE`.

`riskFlag` is a transparent rule, not a learned prediction. In the staging data about 34% of budget lines
are overspent, and no simple signal (status, recurring or not, category) predicts which ones. A rule that teams
38, 43 and 46 can read and explain was preferred to a model that does no better.

## Errors

| Status | When | Body |
|---|---|---|
| 400 | `userId` missing; `month` or `year` not integers or out of range; NaN or Infinity anywhere in the body | `{"error": "..."}` |
| 404 | `userId` is not in the data | `{"error": "unknown userId"}` |
| 503 | The data failed to load, or is still loading after 20 seconds (retry shortly) | `{"error": "..."}` |

## Accuracy

The forecast was measured on the staging data (500 households, 18 months, 17 categories). Methods were chosen on months 13 to 15
and confirmed once on held-out months 16 to 18:

| Method (held-out months 16 to 18) | Total MAE (KES) | Total WAPE | Category WAPE |
|---|---|---|---|
| **Deployed: budget blend, boosted-tree split** | **7,931** | **0.106** | **0.221** |
| Trailing 12-month median (the first stub) | 9,618 | 0.129 | 0.259 |
| Boosted tree alone | 8,917 | 0.119 | 0.212 |
| LSTM | 10,586 | 0.142 | 0.258 |
| Blend with last month's budget (used when the month has none) | 8,402 | 0.112 | 0.261 |

The LSTM did not beat the simpler models, so it is not deployed. Full details are in [`docs/experiments.md`](../docs/experiments.md)
(entries of 14 and 22 Oct 2026).

## Data

- The service reads a snapshot of the Web Masters staging data that ships with it in `backend/data/`
  (budget categories and households, taken on 7 Oct 2026, with months up to September 2026).
  The snapshot loads once at start-up and is not refreshed while the service runs.
- For a month after the snapshot ends, the service forecasts from the latest 12 months it has. For example, December 2026 uses
  `trailing_median_12m`.
- If the staging data changes and the service should use the new data, ask Kevin to regenerate the snapshot.
- All of this data is synthetic.

## Response time and availability

- The service is hosted on Render. An uptime monitor pings it so it stays awake.
- Once the server is up, the data loads from the snapshot in under a second. If Render has put the service to sleep, the first
  request after that waits for the server to wake up. Call `/health` first if timing matters.
- Render redeploys from `main` on every merge. After the 23 Nov 2026 defence, only bug fixes go to `main`.

## Limitations

- `confidence` is a heuristic; do not read it as a probability.
- `riskFlag` compares the forecast with the budget. It does not predict overspending from behaviour.
- The forecast relies heavily on the month's budget when one exists. Without a budget it falls back to history, which is less accurate (see Accuracy).
- Recommendations are U-CS 38's scope, not this service's. The capstone's other endpoints (`/affordability`, `/budget`,
  `/commitments`, `/me/*`) are not part of this contract. They need a login and may change.

## Running it yourself

```bash
pip install -r backend/requirements.txt
python backend/app.py      # http://localhost:8000
```

On a host, set the root directory to `backend` and use the start command `gunicorn app:app --workers 1 --timeout 60`.

| Variable | Purpose |
|---|---|
| `SECRET_KEY` | Required on a host (production): at least 32 random characters. Not needed locally |
| `WASAA_EMAIL`, `WASAA_PASSWORD` | Staging API login. Only used if the bundled snapshot is missing. Never commit them |
| `WASAA_API_BASE` | Optional. Defaults to the staging API |
| `STAGING_DIR` | Optional. A folder of local staging CSVs, for development |
| `PORT` | Port to listen on (default 8000) |
| `DATABASE_URL` | Optional for `/forecast`, which does not use the database. Without it the app uses local SQLite |
