# Budget Forecast Service (U-CS 37)

A small HTTP service that estimates a household's spending for a given month, by category,
and flags whether that spending is likely to exceed the household's budget.

## Endpoints

### GET /health
Returns 200 when the service is up.

    {"status": "ok", "dataLoaded": true}

`dataLoaded` is false for the first few seconds after start while the data loads.

### POST /forecast
Request:

    {"userId": "96ccbe38-e8e6-4761-8bf0-e5ea6844a89d", "month": 10, "year": 2026}

`userId` is the `user_id`. The `user_profile_id` is also accepted.

Response (200):

    {
      "estimatedTotal": 60875.0,
      "breakdown": {"Groceries": 10360.0, "Rent": 21050.0, "...": 0.0},
      "confidence": 0.86,
      "riskFlag": "LOW",
      "note": null,
      "method": "trailing_median_12m",
      "monthsOfHistory": 12
    }

Fields:

| Field | Meaning |
|---|---|
| estimatedTotal | Forecast spending for the month, in KES |
| breakdown | The forecast split by category, in KES |
| confidence | 0 to 1. A heuristic from how many months of history exist and how steady the spending is. It is not a statistical probability. |
| riskFlag | LOW, MODERATE or HIGH (see below) |
| note | Plain-language reason when the forecast is a fallback or the history is short. Otherwise null. |
| method | How the forecast was made (see below) |
| monthsOfHistory | Months of history used. 0 for the fallbacks. |

## How the forecast is made

The service picks the best information it has, in this order:

1. **trailing_median_12m**: the median monthly spend per category over the 12 months before the
   requested month. If fewer than 12 months exist, it uses what there is.
2. **budget_allocation**: if the household has no spending history before the month but has a
   budget, the forecast is the budget. Confidence is 0.1.
3. **peer_median**: if there is neither history nor a budget (or the household has no rows at all),
   the forecast is the median monthly spend of all households. Confidence is 0.1.

A fallback always returns 200 with an explanatory `note`, never an error.

## riskFlag

The forecast is compared with the household's budget for the month (or its latest budget before it):

| Forecast versus budget | riskFlag |
|---|---|
| over 120% of budget | HIGH |
| over 100% and up to 120% | MODERATE |
| 100% or under | LOW |

If no budget exists, last month's actual spending is used as the reference, and the `note` says so.
If there is no reference at all, the flag is MODERATE.

## Errors

| Status | When |
|---|---|
| 400 | `userId` missing, or `month` / `year` not valid integers |
| 404 | `userId` does not exist |
| 503 | Data failed to load, or is still loading (retry shortly) |

Households with little or no history are not errors. They get a 200 and a low confidence.

## Assumptions (please correct if wrong)

- The budget for the requested month is used if it exists in the data. If it does not, the
  household's latest earlier budget is used.
- History is read once, when the service starts, and is not refreshed while it runs. If the
  data changes, the service needs a restart.

## Limitations

- The forecast is a trailing median. It does not yet model trends or seasonality.
- `riskFlag` only compares the forecast with the budget. It does not predict overspending
  from behaviour.
- `confidence` is a heuristic and should not be read as a probability.

## Running it

Environment variables:

| Variable | Purpose |
|---|---|
| WASAA_EMAIL, WASAA_PASSWORD | Staging API login. Used when no local CSVs are present. |
| WASAA_API_BASE | Optional. Defaults to the staging API. |
| STAGING_DIR | Optional. Folder holding local CSVs, for development. |
| PORT | Port to listen on. |

Locally:

    pip install -r backend/requirements.txt
    python backend/app.py

On a host (for example Render), with the root directory set to `backend`:

    gunicorn app:app --workers 1 --timeout 60
