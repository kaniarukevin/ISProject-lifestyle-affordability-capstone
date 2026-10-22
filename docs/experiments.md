# Experiment log

One entry per experiment: hypothesis, setup, result, decision. Dataset versions: **v1** = original synthetic data (buggy
income join), **v2** = tag `v0.1-data`, **v2.1** = after aligning categories with the proposal (PR #22).
All HMM accuracy figures use held-out households and label-free state naming (highest income/expenditure ratio = Stable,
lowest = Critical) unless stated.

## E1 - HMM evaluation order (dataset v1)
- **Hypothesis:** the 0.450 held-out accuracy was partly an evaluation bug.
- **Setup:** `08` predicted households in shuffled order but compared against labels sorted by household ID. Fixed the order, same model and data.
- **Result:** 0.450 -> 0.708. The same mix-up also attached HMM states to the wrong households in `features_with_hmm_states.csv`.
- **Decision:** fixed in `08`. Any earlier HMM figure from v1 is invalid.

## E2 - Dataset audit (v1 -> v2)
Not a model experiment; see CHANGELOG for the bugs found (ID join, swapped urban labels, business flag, sampling with replacement,
missing debt, constant columns). After rebuilding, HMM accuracy fell to 0.522 on v2 because the new data is realistically
noisier than v1 (v1 savings/entertainment shares were almost deterministic by state).

## E3 - Feature and model selection (dataset v2)
- **Hypothesis:** trailing context features (3-month ratio, overspend rate) help, because one bad income month should not look like a state change.
- **Setup:** 4-fold cross-validation over the 240 training households only; 4 KMeans-initialised restarts per fit; test set scored once at the end.
  Feature sets: **A** ratio + savings share + entertainment share; **B** = A + 3-month ratio + 3-month overspend rate;
  **C** 3-month-smoothed A; **D** ratio + 3-month ratio + overspend rate.

| Config | CV accuracy | CV Strained recall |
|---|---|---|
| A, diag, pooled | 0.494 | 0.242 |
| A, diag, per-tier | 0.485 | 0.243 |
| A, full, pooled | 0.491 | 0.242 |
| A, full, per-tier | 0.454 | 0.242 |
| **B, diag, pooled** | **0.562** | **0.489** |
| B, diag, per-tier | 0.540 | 0.270 |
| B, full, pooled | 0.509 | 0.472 |
| C, diag, pooled | 0.467 | 0.301 |
| D, diag, pooled | 0.557 | 0.484 |

- **Test (scored once):** B 0.532 accuracy / Strained recall 0.386; A 0.522 / 0.201; majority baseline 0.353.
- **Decision:** adopt B (diagonal covariance, pooled model). The accuracy gain is within noise on 60 test households; the benefit is Strained recall (0.20 -> 0.39).
- **Not helpful:** per-tier models and full covariance.

### E3a - Exploratory diagnostics (not used for decisions)
Run on the test split before the cross-validation discipline above was in place, so treat as diagnostic only:
supervised per-month classifier (QDA) ceiling 0.668 with 3 features and 0.618 with 6 features; log-scaled ratio variants scored 0.41-0.54
with no consistent gain, so were not adopted.

## E4 - Category alignment re-check (dataset v2.1)
- **Change:** `investment_vehicle` folded into `savings`, transaction fees into `mobile_money_transfers` (proposal's ten spending categories).
- **Result (held-out, 60 households):** accuracy 0.531 vs 0.378 majority baseline; Strained recall 0.441.
  Confusion matrix (rows true Stable/Strained/Critical): [[83, 88, 44], [27, 120, 125], [2, 52, 179]].
- **Decision:** accepted as the HMM baseline for the LSTM stage.

## Open questions
- Does the detected state predict next-month overspending? (issue: HMM downstream check)
- Causal (filtered) vs full-sequence states for forecasting. Full-sequence states use future months and must not feed the LSTM.

## 2026-10-07: Baseline forecasts and HMM confusion analysis (dataset v2)

Baseline (#13). Backtest as in proposal 3.2.4: months 1-9 as history, forecast months 10-12, 60 held-out households (notebooks/01_baseline.ipynb).
- Total spend MAE: last month 14,967 KES; 3-month mean 11,717 KES (average actual total spend 45,384 KES).
- housing and loan_repayment are constant per household, so error is 0 by construction.
- school_fees: last-month MAE 7,395 vs 2,465 for the 3-month mean (term-based lumpiness).
- Target: the LSTM must beat total-spend MAE 11,717 KES on the same households.

HMM, held-out causal states (720 household-months).
- Exact accuracy 0.531; within one state 0.936; Stable<->Critical confusions 0.064.
- Recall: Stable 0.39, Strained 0.44, Critical 0.77.
- 257 of 338 errors are pessimistic (household labelled worse than the generator state).
- Predicted mix 16/36/48 vs true 30/38/32 (Stable/Strained/Critical).
- Interpretation: Strained overlaps both neighbours by construction (median income/expenditure ratio 1.19 / 0.93 / 0.73). The HMM recovers the ordering but leans pessimistic.
- Next: downstream check (#10), then LSTM (#12).

## 2026-10-14: Staging-data baselines, budget blend and the riskFlag finding

Data: Web Masters staging dataset (notebooks/03_staging_explore.ipynb). 500 households x 18 months (Apr 2025 to Sep 2026) x 17 categories; about 20% of budget rows PENDING; average actual total 74,433 KES per household-month. Backtest: forecast months 13-18 from the months before them (rolling, one step ahead), so no future data leaks into a forecast.

Trailing baselines (total spend, six forecast months):
- last month: MAE 11,621 KES, WAPE 0.156, category WAPE 0.350
- median 3 months: MAE 9,556, WAPE 0.128, category WAPE 0.287
- median 6 months: MAE 9,024, WAPE 0.121, category WAPE 0.266
- median 12 months: MAE 9,180, WAPE 0.123, category WAPE 0.255 (best by category)
- mean 12 months: MAE 8,779, WAPE 0.118, category WAPE 0.277 (best by total)
- same month last year: MAE 12,428, WAPE 0.167
- Decision: the service uses the 12-month median because the response includes a per-category breakdown and this has the lowest category WAPE.

Budget as a clue. Forecasting with the month's own budget alone gives MAE 7,853 KES, WAPE 0.106, category WAPE 0.222, better than any history-only baseline. Blending budget weight w with the 12-month median:
- w 0.00: MAE 9,180, WAPE 0.123, category 0.255
- w 0.25: MAE 8,302, WAPE 0.112, category 0.241
- w 0.50: MAE 7,788, WAPE 0.105, category 0.230
- w 0.75: MAE 7,635, WAPE 0.103, category 0.222 (best)
- w 1.00: MAE 7,853, WAPE 0.106, category 0.222
- Caveat: this assumes the month's budget exists when the forecast is requested. Not yet confirmed with Web Masters. The service falls back to history when it does not.

riskFlag. Overspending (actual above budget) happens in about 34% of budget lines and is almost flat across segments: APPROVED 0.34 vs PENDING 0.35; recurring 0.34 vs not 0.34; by category 0.33 to 0.37. Actual divided by budget has median 0.91, mean 0.99, 90th percentile 1.36. Nothing simple predicts which lines overspend, so riskFlag stays a transparent rule: forecast over 120% of budget is HIGH, over 100% MODERATE, otherwise LOW.

Targets for the model comparison: beat total MAE 7,635 KES (WAPE 0.103) and category WAPE 0.222 on the same rolling backtest, or ship the blend and say so.

Open: HMM downstream check (#10); boosted-tree and LSTM against these numbers.
