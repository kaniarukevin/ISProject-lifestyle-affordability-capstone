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

## 2026-10-22: Model comparison on staging data (boosted tree, LSTM)

Notebook: notebooks/04_model_comparison.ipynb. Same rolling backtest as the 14 Oct entry (forecast months 13-18, each model retrained on earlier months only, scored by one shared function). The harness reproduced the earlier baselines exactly (median 9,180; blend 7,635), so the numbers are comparable.

| Method | Total MAE (KES) | Total WAPE | Category WAPE |
|---|---|---|---|
| median_12m | 9,180 | 0.123 | 0.255 |
| blend_75_25 (budget 0.75 + median 0.25) | **7,635** | **0.103** | 0.222 |
| boosted tree, absolute-error loss | 8,567 | 0.115 | **0.208** |
| boosted tree, squared-error loss | 8,155 | 0.110 | 0.237 |
| LSTM (6-month sequence of spend and budget, plus this month's budget) | 9,974 | 0.134 | 0.253 |

Features for the learned models: this month's budget, last three months, trailing median and mean, last month's budget, category. LSTM: one hidden layer of 64, MSE loss, 300 epochs, per-category scaling from training months only. All variants tried are reported; no further tuning on these test months.

Findings:
- No learned model beats the simple blend on total spend. In this dataset actual spending is close to budget times a random factor, so the budget carries most of the predictable signal and there is little left for a model to learn.
- The absolute-error boosted tree is the best on per-category accuracy (0.208 vs 0.222). Aiming for the median per category makes each category closer but the sum too low, because spending relative to budget is right-skewed (median 0.91, mean 0.99). Switching to squared error raised the total accuracy but lost the category gain.
- The LSTM is the weakest. With 500 households and 6 to 11 training months per test month it has too few examples to learn sequence patterns, and the data has little month-to-month structure to find.

Decision: the service forecasts the total with the blend when the month's budget exists, and the 12-month median otherwise. The LSTM is kept as an evaluated option, not deployed. Revisit if real (non-synthetic) data with longer histories becomes available.

## 2026-10-22: Financial-state detection, HMM vs rule vs Random Forest classifier

Data: KIHBS-informed synthetic dataset v2 (data/processed/features_with_causal_states.csv): 300 households x 12 months, same 240/60 household split as the HMM evaluation. Scored on the 60 held-out households (720 household-months) against the generator's true state. Notebook: notebooks/05_state_detection.ipynb.

| Method | Exact | Within one | Stable/Critical mix-ups |
|---|---|---|---|
| Always guess the most common (Strained) | 0.378 | 1.000 | 0.000 |
| HMM, causal states (unsupervised) | 0.531 | 0.936 | 0.064 |
| Rule: thresholds on 3-month income/spending ratio, fitted on train | 0.532 | 0.896 | 0.104 |
| Random Forest classifier (300 trees, min leaf 5), trained on train households | **0.799** | **0.993** | **0.007** |

Within-one for the majority guess is 1.0 only because the guess is the middle state.

Top features of the classifier: income_to_expenditure_ratio 0.162, savings_share 0.106, entertainment_share 0.090, ratio_roll3 0.077, overspend_flag 0.068, savings_rate 0.058, savings 0.057, overspend_roll3 0.051, entertainment 0.041, transport_share 0.022. All are plausible strain signals; no identifier or label-derived column appears, so no sign of leakage.

Decision: the Random Forest classifier replaces the HMM as the state detector for the affordability score. The HMM is kept in the report as evaluated and replaced (deviation from the proposal, allowed by the supervisor on 13 Oct).

Caveat: the classifier learns states as defined by the synthetic generator's rules, so this shows it recovers those definitions, not that it is accurate on real households. Real-user testing (friends' statements) is the check for that.

## 2026-10-22: Forecast ensembles, chosen on validation months and confirmed on held-out months

Notebook: notebooks/04_model_comparison.ipynb (last cell). Staging data, same models as the earlier comparison. To avoid choosing on the months we report, candidates were compared on months 13-15 (validation) and the choice was confirmed on months 16-18 (final test).

| Method | Val MAE (KES) | Val cat. WAPE | Test MAE (KES) | Test WAPE | Test cat. WAPE |
|---|---|---|---|---|---|
| blend_75_25 | 7,340 | 0.218 | 7,931 | 0.106 | 0.226 |
| boosted tree | 8,218 | 0.204 | 8,917 | 0.119 | 0.212 |
| LSTM | 9,363 | 0.247 | 10,586 | 0.142 | 0.258 |
| **hybrid: blend total, boosted-tree split** | **7,340** | 0.213 | **7,931** | **0.106** | 0.221 |
| average of blend and tree | 7,399 | 0.208 | 8,074 | 0.108 | 0.217 |
| average of blend, tree and LSTM | 7,450 | 0.216 | 8,262 | 0.110 | 0.225 |

Decision: the hybrid ensemble. It matches the best total (by construction it keeps the blend's total) and improves the category breakdown over the blend on both validation (0.213 vs 0.218) and the final test (0.221 vs 0.226). The averages give slightly better category accuracy but a worse total, and the total is the headline number for users and for Web Masters. Adding the LSTM to the average makes both worse.

So the deployed forecaster becomes: total = 0.75 x this month's budget + 0.25 x 12-month median; that total is split across categories in the proportions predicted by the gradient-boosted tree. Fallback when the month's budget is missing: 12-month median.

Note: the category gain is real but small (about 0.005 WAPE); the main value of the learned component is the category split, not the total.

## 2026-10-22: Affordability engine (score, scenarios, safety rule)

Notebook: notebooks/06_affordability.ipynb. Data: KIHBS-informed synthetic dataset v2, same 240/60 household split.

How it works. A scenario adds a monthly amount to a category (for example housing or loan_repayment) or changes income, applied to the household's last 3 months so the rolling features reflect it. All features are then recomputed with build_features(), which reproduces 07_feature_engineering.py (largest difference 5.8e-11). Score = 100 x (P(Stable) + 0.5 x P(Strained)).

Consistency test (60 held-out households, rent +10%, +25%, +50% of income):

| Score model | Held-out state accuracy | Households where a bigger cost never raises the score | Mean score now: Critical / Strained / Stable |
|---|---|---|---|
| Random Forest on all features | 0.799 | 0.40 | 15 / 55 / 74 |
| Monotonic gradient boosting (two binary models, direction constraints, no share features) | 0.654 | **1.00** | 20 / 46 / 66 |

The Random Forest relies on spending shares; raising one category lowers every other share, so a costlier scenario could look healthier. The monotonic model is constrained so that more spending, overspending and debt can only lower the score and more income, ratio and savings rate can only raise it, which guarantees consistent answers.

Decisions:
- Current financial state shown to the user: Random Forest (most accurate).
- "Can I afford this?" score: monotonic model (never rewards a bigger cost). Deliberate trade of accuracy for consistency, as in credit scoring.
- Verdict cut-offs set halfway between the mean scores of neighbouring states: Affordable at 56 and above, Stretch 33 to 55, Not affordable below 33.
- Safety rule: if the monthly shortfall after the change is larger than the household's current savings, the verdict is Not affordable regardless of the score.

Example (held-out household H063, income KES 25,314, score now 85): rent +10% of income gives 54 Stretch (KES 2,068 left); rent +25% gives 48 Stretch (short KES 1,729, coverable by pausing savings); a loan of 30% of income gives 46 and the safety rule makes it Not affordable (short KES 2,995, more than KES 1,772 saved; debt 30% of income).

Saved as models/affordability_engine.joblib.

Limits: trained on synthetic states; cut-offs and the scenario method should be checked against real households (friends' statements).

## 2026-10-22: Affordability engine, part 2 (purchases, savings goals, what to cut)

Notebook: notebooks/06_affordability.ipynb, cells 8 to 10. Same held-out household H063 (income KES 25,314, KES 4,599 left over per month, score now 85).

Decision types added:
- One-off purchase: shown two ways. Paying in instalments is scored as a temporary monthly repayment (optional monthly interest, standard instalment formula); saving up first is price divided by monthly left-over. Phone KES 30,000 over 6 months: KES 5,000 a month, score 49 Stretch (short KES 401, coverable by pausing savings); or 7 months of saving.
- Savings goal: saving more moves left-over money into savings, so it is compared with the left-over and not run through the score (the score counts savings as spending and would wrongly penalise it). Save KES 3,000 more: Affordable. Save KES 6,000 more: short KES 1,401.

What to cut. Only entertainment, transport and airtime/data are treated as flexible (rent, food, school fees, loans and mobile-money support to family are not). Equal percentage cuts in 5% steps up to 50%, reported at two levels:
- To break even (no monthly shortfall) and to be comfortable (verdict Affordable).
- A first version that only aimed for Affordable asked for a 50% cut (KES 2,764) to fix a KES 401 shortfall, and reported the rent case as impossible; the two-level version fixes both.

| Scenario | To break even | To be comfortable |
|---|---|---|
| Phone in instalments (KES 5,000/month) | cut 10% (KES 553), KES 152 left, score 50 | cut 50% (KES 2,764), KES 2,363 left, score 57 |
| Rent +25% of income | cut 35% (KES 1,935), KES 205 left, score 50 | not reachable by flexible cuts |
| Loan of 30% of income | not reachable | not reachable |
| Save KES 6,000 more | cut KES 1,401 split across the three categories | n/a |

When nothing is reachable, the app says so and suggests a cheaper option, a longer repayment period or saving up first.
