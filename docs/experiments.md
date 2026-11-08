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

## 2026-10-22: Making the forecast deployable (only use what is known at request time)

Notebook: notebooks/04_model_comparison.ipynb (last cells). Problem: the blend and the boosted tree used the budget of the month being forecast. For "next month" requests that budget usually does not exist yet (the bundled snapshot ends in Sep 2026), so the service would silently fall back to the median.

| Method (months 16-18) | Total MAE (KES) | Total WAPE | Category WAPE |
|---|---|---|---|
| Median 12m (service until now) | 9,618 | 0.129 | 0.259 |
| Blend with this month's budget | 7,931 | 0.106 | 0.226 |
| Blend with last month's budget | 8,402 | 0.112 | 0.261 |
| Hybrid, last month's budget, tree trained with this month's budget | 8,402 | 0.112 | 0.224 |
| Hybrid, last month's budget, tree retrained on known inputs only | 8,402 | 0.112 | 0.264 |
| Last month's budget for the total, median proportions for the split | 8,402 | 0.112 | 0.269 |

Validation months 13-15 showed the same pattern (median 8,742; lagged blend 7,789).

Findings:
- Using last month's budget still cuts total error by about 13% against the median, on both validation and test months. This works for real next-month requests.
- The boosted tree's category advantage came from this month's budget. Retrained on inputs known in advance, its split is no better than the median's. This was a leakage-style trap caught before deployment.
- Scaling any split up to the larger blended total raises per-category error slightly (0.259 to 0.261-0.269), a small cost accepted for the better total, which is the headline number and drives riskFlag.
- Months 16-18 have now been looked at several times, so these figures are indicative rather than a clean final test.

Deployed rule (backend/app.py, make_forecast):
- This month's budget exists and the last 3 months are present: total = 0.75 x budget + 0.25 x 12-month median, split by the boosted tree (method blend_budget_tree_split). Tree trained by scripts/train_forecast_tree.py on all staging months.
- Only last month's budget exists: total = 0.75 x last month's budget + 0.25 x median, split by median proportions (blend_last_budget_median_split).
- No budget: trailing 12-month median. Fallbacks for thin or no history unchanged.

## 2026-10-28: Dynamic budget

Notebook: notebooks/07_dynamic_budget.ipynb. Data: KIHBS-informed synthetic dataset v2, same household split. Learned from 974 Stable household-months (train), tested on 215 (held out).

Design: commitments (housing, loan repayment, school fees) set aside exactly; savings 10% of income or the goal's monthly amount; everyday money (food, transport, utilities, airtime/data, mobile-money transfers, entertainment) split across categories; dynamic rules for state and last month's overspending.

Everyday split, average KES error per category on held-out Stable households:

| Category | One-size (average Stable split) | Random Forest | Half and half |
|---|---|---|---|
| food_groceries | 1,845 | 1,806 | 1,721 |
| transport | 1,405 | 1,476 | 1,413 |
| utilities | 858 | 518 | 643 |
| airtime_data | 638 | 528 | 575 |
| mobile_money_transfers | 1,540 | 1,939 | 1,728 |
| entertainment | 1,009 | 888 | 941 |
| **Total** | 7,295 | 7,155 | **7,021** |

Random Forest features: income, money available after commitments and savings, household size, dependants, formal job, urban/peri-urban. Personalising helps where costs depend on circumstances (utilities, airtime) and hurts for transfers to family, which depend on personal obligations. Decision rule fixed before the test: lowest total wins, so the budget uses half personalised, half average (shrinkage), 4% better than one-size.

Design fix found in review: a first version lowered the savings rate for Strained (7%) and Critical (5%) households, which gave a Strained household more entertainment money than a Stable one. Corrected: savings stays at 10% for all; Strained moves 25% and Critical 50% of entertainment into savings. Family example (KES 25,300): entertainment 1,162 / 872 / 581 and savings 2,530 / 2,821 / 3,111 for Stable / Strained / Critical. Overspend rule: a category overspent last month loses half the overspend this month, moved to savings (student example: entertainment 605 to 305 after a KES 600 overspend).

Does following the budget help? 44 held-out households that are Strained or Critical in their last month were given the budget and assumed to follow it for 3 months, then rescored with the deployed affordability and state models:
- Average affordability score 30 now, 70 following the budget; 91% of households improve.
- State seen by the model: of 27 Critical, 20 move to Strained and 4 to Stable; of 15 Strained, 4 move to Stable and 11 stay.
- Caveat: following the budget means spending within income by construction, so this shows the budget is sound if followed, not that people will follow it. Real-user testing is the check for that. Student airtime/data limits (about KES 460) look low for students because the model learned from KIHBS households; to be checked with friends.

Saved as backend/models/budget_split.joblib (1.8 MB); served by POST /budget.

## 2026-11-04: Forecast for app users, model vs median (KIHBS-informed data)
Script: scripts/kihbs_forecast_experiment.py. Data: KIHBS-informed synthetic dataset v2 (data/processed/engineered_features_raw.csv), 10 app categories, same 240 train / 60 test households. 48 train households held back as validation to choose; test scored once (one extra split method was then added and re-scored, so the test split figures are indicative).

Question: the app's own forecast used a statistical rule (median of monthly totals, split by average shares). Does a learned model do better for a user with 1, 3, 6 or 11 months of history (manual records, estimates or an M-Pesa statement)? Only inputs known before the month: past months, income, household size, dependants, formal job, and the calendar month being forecast. The data has real seasonality: school fees in January, May and September (KES 8,870 vs 710 average), and a December spike (KES 54,851 vs about 43,000).

| Method | Val MAE (KES) | Test MAE | Test WAPE | Test cat. WAPE | Test MAE, 1 / 3 / 6 / 11 months of history |
|---|---|---|---|---|---|
| Median of totals, split by shares (app until now) | 12,254 | 10,719 | 0.247 | 0.370 | 11,581 / 10,366 / 9,460 / 17,219 |
| Last month | 13,224 | 11,676 | 0.269 | 0.400 | |
| Mean | 12,384 | 11,004 | 0.254 | 0.370 | |
| Per-category median | 12,316 | 10,706 | 0.247 | **0.342** | |
| Boosted tree, history only | 11,365 | 10,571 | 0.244 | 0.369 | 11,047 / 10,501 / 9,959 / 15,032 |
| **Boosted tree, history + calendar, fee-aware split** | **10,741** | **9,794** | **0.226** | 0.376 | **10,106 / 9,818 / 8,949 / 14,697** |

The tree predicts next month's total as a multiple of the household's median (absolute-error loss, 300 iterations, min leaf 40). Fee-aware split: in a fee month, school fees get the amount paid in past fee months; other categories share the rest by the household's average shares.

Decision: the app forecast now uses the boosted tree with the calendar (chosen on validation). On the test households it cuts total error by 8.6% against the median and is better at every history length. Its category split is slightly worse than the median's (0.376 vs 0.370) and the per-category median is best on categories alone (0.342) but no better on the total; the total is the headline number shown to users and used for warnings, so the trade is accepted, as in the staging forecast.
Calendar features help only because the data has term-time fees and a December peak; those are real Kenyan patterns, but the size of the gain should be checked on real statements. Saved as backend/models/user_forecast.joblib; the median remains the fallback.

## 2026-11-04: Forecast for app users, part 2 - what makes it more accurate?
Script: scripts/forecast_improvements.py (same data and households; choices made on the 48 validation households, test scored at the end). It trains and saves the deployed backend/models/user_forecast.joblib.

| Idea | Validation MAE (KES) | Test MAE | Kept? |
|---|---|---|---|
| Tree on the whole total, with the calendar (deployed earlier today) | 10,741 | **9,794** | yes |
| Rent and loans as known, fees fee-aware, tree on everyday spending only | 11,819 | - | no |
| Rent only as known (synthetic loans start and stop: 103% month-to-month variation; rent: 0%) | 12,010 | 10,671 | no |
| Tuning (learning rate, leaf size, iterations, trend feature; 36 settings) | best 10,634 (-1%) | - | no: under the 2% bar set in advance, kept the simpler default |
| Personal bias correction (adjust by the household's recent misses, shrink 0.25-0.75) | 11,942 to 13,452 | 11,112 | no: misses are random, not a steady personal bias, in this data |
| 80% range: 10th/90th percentile trees, widened x1.35 on validation | 80% of months inside | **81% inside**, average width KES 30,633 around an average forecast of KES 40,702 | yes |

Findings: the whole-total tree already learns rent and fee timing from history; splitting the forecast into parts lost more than it gained. The range is wide (about +/-38%) because month-to-month spending in this data is noisy; it is honest, and should narrow on real statements.
Deployed (backend/store.py, forecast_for_user): total from the tree (median fallback), fee-aware split, 80% range, budget blend applied to the range ends too. One rule needs no model and is not testable on this data (no household changes rent): rent or loan repayments entered under Commitments that differ from history are added as known (for example after "I'm doing this" on a move).

## 2026-11-04: Forecast for app users, part 3 - where does the model's gain come from?
Same model, data and households; inputs switched on one group at a time (test MAE, KES): median rule 10,719; past spending only 10,615; + income and household 10,571; + December flag and month 9,949; + school-fee timing only (no month or December) 9,844; all inputs (deployed) 9,794.
By month type (test MAE, median rule vs model): fee months (Jan/May/Sep) 11,791 vs 9,292 (-21%); other months 9,697 vs 9,077 (-6%); December 16,753 vs 16,529 (-1%).
Permutation importance: household median 0.37, fee month 0.19, usual fee amount 0.16, income 0.07, average income 0.06.
Reading: about three quarters of the gain comes from knowing when school fees fall and how much this household pays; the rest from income and household size. December is not learnt (one December per household, so few examples). Households without termly fees get only the ordinary-month gain (about 6%). December remains under-forecast for everyone.

## 2026-11-04: Forecast for app users, part 4 - fixes found by walking through the app as three users
Simulated a new user, a student (day one with estimates, then real months, then "I'm doing this" on a laptop) and a family of four (rent, termly fees, chama, SACCO loan). Every automatic check passed (budgets add up, screens agree, ranges contain forecasts), but reading the answers showed:
- January was forecast below a normal month for the fee-paying family. Cause: the data has 12 months per household, so month 1 is never a target in training and the raw month number was untrained there. Fix: fee-month and December flags only (validation 10,912 vs 10,741 with the month number; test 9,967, still 7% better than the median's 10,719).
- Even then, the tree gave this family a fee month 0.92 x its median (fee payers in the data average 1.25 x): a sparse region (high income, long history). Tested a no-fee tree plus fees added separately: worse (validation 11,795). Kept the tree and added a floor in fee months for fee payers (usual non-fee spending plus last term's fees): validation 10,923 vs 10,912, test 9,936 vs 9,967, active in 4% of forecasts. Neutral on accuracy, prevents implausible answers.
- The 80% range ignored how steady a household is (a family spending the same each month got 31,000-73,000). Fix: with 3+ months, half the model's spread and half the household's own spread, widened x1.3 on validation. Test: 83% inside overall; steadiest quarter 74% inside (width 26,196); most variable quarter 92% (width 38,242).
- Wording: a one-off payment was described as a loan; a one-month cost showed "score 54 -> 2" with no explanation (now "the score after is for the month(s) you pay"); "No budget for money sent: you have not spent on it" appeared for a family whose chama is set aside under commitments; unclear "months to keep it within reach" advice. All reworded; tests added.

## 2026-11-04: M-PESA statement reader (backend/mpesa.py)
Tested on one real 52-page Safaricom statement (12 months, the developer's own; not stored in the repo).
- Reading: pypdf text, 1.3-1.7 s; table extraction with pdfplumber gave the same rows in 12.3 s, too slow for the free server's 30 s request limit, so rejected.
- Completeness: 1,739 transactions; paid in and paid out equal the statement's own summary to the cent (KES 938,350.00 / 938,387.32). Running balance: 6 breaks at first, all pairs of transactions in the same second listed in swapped order; ordering same-second rows by balance gives 0 breaks. Import is refused if totals or balances do not match.
- Understanding (rules, not a model: no labelled Kenyan transactions exist): of 1,739 rows, 1,232 spending, 25 salary, 204 money received, 278 moves between the user's own bank and fund accounts. If every shilling had been counted as spending, a year would show about KES 930,000 out; own-account moves are left out and net money put into funds counts as savings.
- Questions: bank and unknown paybills are counted as paying someone until the user answers (a user confirmed Equity paybill is usually a payment, 4 Nov; hiding real spending is the dangerous error for affordability). First upload: 4 important questions (2 Equity accounts, SBM Bank, cash) settle 45% of spending by value; rules settle 41%; 13% is a best guess the user can change. Answers are remembered: a second upload asks 0 questions and imports 0 repeats.
- One-offs: payments of at least max(KES 10,000, half a usual month) are suggested as one-off purchases (found: a KES 179,000 phone and a KES 55,000 payment); kept out of usual spending they leave October at KES 13,948 instead of about 193,000. A one-off can complete a matching goal (name in the payee or target within 15%).
- To do for the report: category accuracy needs ground truth (the user labelling about 100 transactions); other statements (friends) to test other layouts.
- Follow-ups after the developer tried it (4 Nov): (1) users do not remember paybill account numbers, so each question now lists the payments' dates, times and amounts, adds clues (a goal or an earlier "Can I afford it?" check of about the same amount in the 60 days before), and offers "I'm not sure" (counted as spending, never remembered, asked again next time). (2) Overlapping statements import nothing twice (receipt + amount + charge/transfer). Hand-entered records in the statement's months are replaced by default (they would be counted twice), with an option to keep them for cash spending.
- Speed (1,234 imported records, local SQLite): dashboard 78 ms, budget 217 ms, transactions list 139 ms, "Can I afford it?" 739 ms; the first screen after start-up took 2.2 s while the models loaded, so they now load at start-up. Each screen makes about 7 database queries; from a laptop in Nairobi to the cloud database each costs a round trip, which explains slow screens when running the backend locally. On Render, the server is much closer to the database.

## 2026-11-04: M-PESA reader, version 2 - exact types, a Kenyan business directory, nothing guessed
Why: on the developer's own statement the first version guessed (unknown tills and Pochi as food; M-PESA charges inside "money sent"). A statement only gives a name and a number, so "Jane Mwangi" could be a grocer or a cousin and a bank paybill could be a business or the user's own account. Guessing is worse than saying "not sorted".
Design (backend/mpesa.py, backend/kenya_directory.py):
- Layer 1, always right: M-PESA's own transaction types (sent to people, Pochi la Biashara, buy goods, pay bill, cash, airtime and bundles, M-PESA charges, loans, savings, money in). Charges get their own label.
- Layer 2, only when certain: a directory of 365 patterns in 27 groups (well-known Kenyan brands: supermarkets, fast food, fuel, utilities, internet and TV, betting, loans, funds, transport, hospitals; then descriptive words in business names: butchery, caterers, chemist, salon...). Labels with no place in the models' 10 categories (Health, Shopping, Personal care, Government) are shown to the user but count as unsorted for the models. Banks and payment gateways are never guessed.
- Everything else is "Not sorted yet": counted in every total, spread across everyday categories in the household's own sorted proportions for the engines, shown as unsorted to the user.
- "Who you pay": one tap per person or business, remembered for every past and future payment; suggestions from Kenyan patterns (same amount early every month for 3+ months suggests rent; many small payments to one till suggests food), never applied without the user. Tagging rent or school fees offers to add a commitment, so the budget sets it aside. Any payment can be corrected (just this one, or always for this payee) and a payee tag can be undone.
- Real-statement check: one mistake found and fixed (a chips outlet "at Two Rivers Mall" was called parking because of "mall"; a mall's own paybill is parking, a till in a mall is not).
Results on the developer's statement (1,739 rows, 12 months): sorted for certain before any tag 41% of spending by value (M-PESA type 22%, directory 13%, word patterns 7%); the rest is mostly two large Equity paybill payments only the user can identify. After tagging the top 10 payees: 89%. Accuracy of the directory needs the user's labels (to do; corrections are stored with the reader's original category so this can be computed).
State detection with unsorted money (scripts/train_statement_safe_state.py): a Random Forest on figures a statement gives exactly (totals, income, savings, loans, their ratios and 3/6-month versions) scores 0.750 on the 60 held-out households (Stable<->Critical mix-ups 0.028) against 0.799 (0.007) for the deployed model that uses category shares. When 30% of everyday money is mis-sorted as entertainment, the deployed model's state changes for 27 of 60 households, the statement-safe model's for 0. The app uses the statement-safe model when more than 10% of usual spending is unsorted. The affordability score uses no category shares and is unaffected.
- Overfitting check (4 Nov): three directory entries had come from the developer's own statement (Mexican Food House, Kola Entertainment, Safeway Hypermarket), not well-known chains. Removed. Coverage on that statement is unchanged (41.5% sorted for certain), because the word rules ("food house", "hypermarket") catch two of them and the third becomes unsorted. All rules are now generic; the real test of generalisation is statements from other users, scored without changing the rules (planned: 3-5 friends with consent; report totals-check pass rate, unrecognised types, share auto-sorted, and owner corrections as directory precision).
- Developer trying the payee screen (4 Nov): "Virginia" is a phone-accessories seller paid by send money, but the tags had no Shopping; a barber (MANLY MANE GROOMERS, labelled Personal care by the directory) was suggested "food"; every regular send was suggested "family, friends or a chama". Fixes: new categories shopping, health, personal care and other, shown by name (and in the budget as "Other spending"), treated like unsorted money by the models; only the strong rent pattern is suggested, and never for a payee the directory already labelled. Sorted for certain on that statement: 42.8% (health, shopping and personal care now count as known).
- Money in and the timeline (4 Nov). Bank transfers into M-PESA are the user's own money or someone paying them from a bank (an allowance, a salary); on the developer's statement all 72 Standard Chartered transfers carry a reference with his own number, so the statement cannot tell the two apart. Money in is now stored and taggable: all pay or allowance, a mix of pay and own money, own money, or someone paying back. Statement income replaces the profile figure only after the user tags a source (salary lines alone would ignore an allowance paid by bank). Tagging the developer's bank as "all allowance" gave months of KES 267,000 and 188,300 (own money moved to pay for a phone), so "a mix" was added: the profile income stays the plan and a month where less arrived uses the lower amount. With "a mix": 2 Stable, 2 Strained, 8 Critical over 12 months, "improving lately"; profile income only: 5 Stable, 2 Strained, 5 Critical. Dashboard timeline scores each month with only the data up to then; a note appears when the latest records are two or more months old. M-PESA charges are their own category; the original statement line is kept with every imported payment; suggestions are back as hints (rent; small frequent payments at one shop: food?), never for a payee the directory labelled, and the current category is shown highlighted.

## 2026-11-04: The whole app on the developer's real statement (KES 30,000 allowance)
Imported 12 months (Nov 2025 - Oct 2026) through the app, one-offs kept out (KES 54,999 in July, KES 179,000 phone in October).
- Profile income only: now Stable, score 100. Month by month: 5 Stable, 2 Strained, 5 Critical; Critical in Dec, Apr, May, Jul, Aug (spending at or above the allowance). Main and statement-safe state models agreed in 11 of 12 months.
- Standard Chartered tagged "a mix" (allowance and own money): income per month is what arrived, capped at the profile figure (August KES 7,050, September 11,300). Result: 2 Stable, 2 Strained, 8 Critical, "improving lately"; still Stable 100 now.
- Finding: the headline score is generous. It reflects the last few months (Sept and Oct well under the allowance) and barely reacts to having almost no savings, while the year was fragile. The timeline now shows the year; the score itself is to be reviewed (planned with SHAP).
- Price level: the synthetic dataset's incomes are in 2025 KES (KNBS CPI, see CHANGELOG v0.1-data), so amounts are close to current prices.

## 2026-11-05: Why this score (SHAP) and the score review

Script: scripts/add_score_explainer.py. Code: backend/affordability.py (`shapley`, `explain`, `track_record`).

Method. Exact interventional Shapley values of the score the user sees, 100 x (P(Stable) + max(P(not Critical), P(Stable))) / 2, not of each model separately. The 14 score features are grouped into six parts a user can read: income; spending against income in the latest month; the last 3 to 6 months; saving rate; loan repayments; household size and dependants. With six groups there are 2^6 = 64 coalitions, so the values are exact (no sampling) and need no extra library on the server. Reference: 200 training household-months (random, seed 0), stored in affordability_engine.joblib.

Checks:
- Correctness: with each of the 14 features on its own, the values match the shap library's ExactExplainer (v0.54.1, same background) to 2.8e-13 score points on 5 held-out households.
- Additivity: typical score (47.9) + the six parts = the score, within 2.8e-14 points, for all 60 held-out households.
- Background size: against 200 rows, 100 rows move a part by up to 4.0 points (mean 3.1) and 50 rows by up to 10.3 (mean 7.5). Kept 200 rows; about 0.4 s per explanation (two 300-tree models score 12,800 rows), so explanations are computed on request (POST /me/explain), not on every dashboard load.

What drives the score on held-out households (mean absolute points): latest month's spending against income 14.4, saving rate 10.1, last 3 to 6 months 9.2, household size and dependants 8.4, income 3.4, loan repayments 1.1. Critical households lose most from the latest month (-16.5) and saving (-10.5); Stable households gain from the latest month (+9.7) and recent months (+8.4).

Score review: why the developer's statement scored Stable 100 in a year with 5 Critical months. Student-like households (one person, KES 30,000 a month, nothing saved):

| Pattern | Score | Largest parts |
|---|---|---|
| spends 15k every month | 100 | latest month +39, recent months +22, saving -6 |
| spends 31k for 9 months, then 15k for 3 | 100 | identical to the line above |
| spends 25k every month | 83 | latest month +32, recent months +19, saving -12 |
| spends 29k every month | 50 | recent months +15, saving -14 |
| spends 31k every month | 15 | saving -20, latest month -5 |

- The score has no memory beyond 6 months. Retraining cannot add it: the generator's states do not depend on longer history. Adding 12-month features (overspend share, average ratio) changed held-out 3-state accuracy from 0.728 to 0.735, and households whose last 3 months were calm are labelled Stable 90% of the time after a fragile year (21 cases) and 86% after a steady one (134 cases). The model learned the labels correctly; the labels only describe recent months.
- Saving nothing costs only 6 points when half the income is left over. That is defensible: the left-over money is in effect saved.
- For the developer's own case a third cause is coverage: the M-PESA statement does not see card spending from the bank account, so "left over" can be money spent elsewhere. The "mix" tag (income = what arrived on M-PESA) is the fix already in the app.

Decision: keep the score as "how your recent months look" and make the year visible next to it. Track record = months in the last 12 where spending before savings was more than the money that came in; three or more is a fragile year. The dashboard adds a note when the score is 56 or more and the year was fragile. "Can I afford it?" turns Affordable into Stretch for a fragile year and says why (a stated, cautious rule, like the savings safety rule; the what-to-cut plan is not shown for this case, because cutting now cannot change the past months). Not validated against labels, because the labels do not contain history: to be checked with volunteers.

Rule refined the same day, on the developer's own data: KES 2,500 a month of family support, with about KES 16,000 left over in recent months, came back "Stretch" with "score 100 -> 100". The first rule lowered every Affordable answer in a fragile year, whatever the amount, so it carried no information. Now a fragile year lowers Affordable to Stretch only when the cost does not fit the year's average month with the budget's 10% margin left (average income minus average spending before savings over the last 12 months, minus the new monthly cost, compared with 10% of average income). Otherwise the answer stays Affordable with a caution line naming the overspent months. Test case like the developer (KES 30,000; 5 months over, 7 at about 14,000; year average about 8,500 left): +2,500 a month stays Affordable with the caution; +12,000 rent is lowered. The answer card now says when the verdict was lowered by the track record.

## 2026-11-05: Forecast one to three months ahead

Script: scripts/forecast_horizons.py. Same households and split as the 4 Nov forecast entries (choose on 48 validation households from train, score the 60 test households once).

For month 2 and 3 ahead the history ends 2 or 3 months before the target month. Options: A, reuse the deployed one-month model (its inputs are summaries of the past plus the target month's fee and December flags); B, one model per horizon trained on examples with that gap. Rule fixed before looking: keep A unless B is more than 2% better on validation.

| Months ahead | Validation: median / A / B (MAE, KES) | Choice | Range widening |
|---|---|---|---|
| 1 | 12,254 / 10,912 / 10,912 | A (deployed) | x1.30 |
| 2 | 13,078 / 11,891 / 12,046 | A | x1.35 |
| 3 | 13,551 / 12,819 / 12,789 | A (B only 0.2% better) | x1.45 |

Test (60 held-out households), the app's exact models:

| Months ahead | Median MAE | Model MAE | Better by | Inside the 80% range | Average range width |
|---|---|---|---|---|---|
| 1 | 10,719 | 9,967 | 7.0% | 83% | 31,271 |
| 2 | 11,738 | 10,354 | 11.8% | 83% | 32,554 |
| 3 | 11,791 | 11,000 | 6.7% | 85% | 35,915 |

The 1-month row reproduces the deployed numbers exactly, so the script matches the app. A first run of the script had the choice rule reversed (it picked B at 2 months although A was better); caught on reading the output and corrected before saving.

Decision: one model for all three months, with the range widened per horizon (stored as `horizon_widen` in user_forecast.joblib). The dashboard shows this month and the next two, and notes a coming month expected to cost more than income (for example a January with school fees). Months beyond 3 from the last records use the 3-month range. Limits: synthetic households with 12 months each; fees fall in fixed months (January, May, September) in the data.

## 2026-11-05: Dashboard speed

Measured on a realistic user (13 months, 1,092 transactions, a bill, a debt and a goal; SQLite, so database time excluded): GET /me/overview took 511 ms and 18 queries; every other screen 2-170 ms. A profile showed 95% of the time in the month-by-month timeline, which ran the full affordability evaluation 12 times. The features only look backwards (rolling windows, running mean and spread), so they are now built once for all months and the state and score models score every month in one call (`affordability.timeline`). Result: 100 ms, with states and scores identical to the month-by-month version (test `test_the_one_pass_timeline_matches_scoring_each_month_on_its_own`). Database queries are cheap only when the server and database are close: Render and Neon should be in the same region (from Nairobi to the database each query is a long round trip, which is why local runs felt slow).

## 2026-11-06: Budget forecast, and the budget pull in the dashboard forecast

Question from the redesign: does the app show how the budget will look in the coming months? It did not. The dashboard showed three monthly totals, and the budget covered the current month only; the two were not connected, although the proposal's pipeline has the forecast feeding the recommendation.

Finding while building it: for app users, `forecast_for_user` blends 0.75 x the month's saved budget with 0.25 x the model (the U-CS 37 result, where the budget carried most of the signal). But the app saves its own recommended budget the first time the Budget screen opens, so on the dashboard "likely spending" is mostly the app's own advice. The held-out error for app users (KES 9,967 at one month) was measured on the plain model, without any budget.

Built: `GET /me/budget-forecast`, using the plain model ("at your usual pace") for this month and the next two. For each month: money in, spending at the usual pace with its 80% range, what is left, school fees, and each everyday budget line against the usual pace. Then it follows the money month by month from the savings balance, at the usual pace and on budget, and gives one of three answers: fine, tight (one month is short but what is left before it covers it, with the amount to put aside each month), or runs out (with whether keeping to the budget gets the household through). Lines more than KES 500 and 10% over their budget are listed. It works on the setup estimates on day one and says so.

Test case (KES 30,000, rent 12,000, school fees 15,000 a term in January, 4,000 saved, three months of records spending about 29,000): at the usual pace the money runs out in December, and January is KES 14,400 short; on the recommended budget the savings path stays positive (11,140 / 16,111 / 8,283), so the answer is "keeping to your budget gets you through: about KES 7,700 a month less on everyday spending".

Also built for "Can I afford it?": the recommended budget now and after the change, side by side (proposal 3.4.6). The same recommendation runs again with the change; a new everyday cost is set aside first and shown on its own line. A first version put it under "other commitments", which the budget treats as family support and took out of "money sent", wiping that line; caught by checking every scenario's lines and fixed before saving.

Open decision for the redesign: show the plain forecast on the dashboard as well, so every screen uses the validated number, or keep the blend there and label it.

## 2026-11-06: Covering Kenyan households - plans, low months, borrowing, goals, messages, forecast check

Review against the people the app is for (students and people on allowances, employed, business owners and hustlers, young families, wider households). The single checks covered one cost at a time; most real decisions are an upfront cost plus a monthly change, some bring money in, school fees come by term, and income is often irregular. Statements also stop at their last day.

- Plan a change: one check with an upfront cost (savings or instalments), monthly costs (monthly, termly, semester or yearly), money it brings in and a duration. Test household (KES 45,000, rent 12,000, KES 60,000 saved): moving to KES 22,000 rent with a 44,000 deposit from savings: Stretch 97 -> 50, short 3,500 a month; a KES 160,000 boda boda over 18 months at 14% with KES 6,000 fuel and KES 18,000 earnings: Affordable while paying (87) and after (100); a baby with KES 35,000 delivery and KES 16,500 a month: Not affordable (49), savings cover about 5 months; boarding fees of KES 28,000 a term: Affordable (59) with "put aside about KES 7,000 a month"; a KES 900,000 car from 60,000 savings: Not affordable before scoring.
- Low month: the lowest of the last 6 months of pay that actually arrived (tagged in Who pays you), or the user's answer at setup; used only below 85% of usual. Test: pay of 45,000 with one month at 27,000; moving to KES 18,000 rent is checked again on "a month like September 2026" and leaves less each month.
- Borrowing: Fuliza is cleared by an automatic "OD Loan Repayment", so its repayments count its uses; repayments to M-Shwari and KCB M-PESA loans, Tala, Branch, Zenka, Okash, Hustler Fund and Timiza count the rest (whole words: "NATALIA" is not Tala). Found while building it: a Fuliza draw was read as money taken out of savings, lowering the month's saving; fixed.
- Goals: savings since each goal was set, counted once the user agrees, earliest deadline first, each deposit once. The app may save goals back without the new fields, so they are carried over by name (tested).
- Pasted messages: Safaricom SMS confirmations become statement-shaped rows (buy goods, send money with the number masked as on statements, Pochi, paybill, money received, airtime, agent withdrawal and deposit, M-Shwari, Fuliza repayment, transaction cost). Tills and paybills have no number in an SMS, so each name gets a stable 9-digit stand-in (real ones have at most 7 digits). A message without a date or in an unknown format is listed back, never guessed. Still to check against real messages from volunteers.
- Forecast check: the plain forecast for each month is kept before the month begins and compared with what was spent once recorded; pooled in the admin view as months, users, MAE, WAPE and the share inside the 80% range.

Speed after these: dashboard 151 ms on 13 months and 1,092 records (was 100 ms), budget forecast 81 ms.

## 2026-11-06: No fee-month bump for people who pay no school fees

Question (Kevin, as a student who does not pay his own fees): does the forecast make January more expensive for someone with no school fees? The fee-aware split and the fee-month floor already used the user's own fees (0 for a non-payer), but the model was told "fee month" for every user in January, May and September.

Check on the model as deployed: for a student spending about KES 22,000 a month with no fees, January, May and September came out about KES 1,200 (6%) above other months. On the 60 held-out test households (27 never pay fees), switching the flag off for households with no fees in their records (`scripts/fee_month_check.py`):

| | As deployed | Flag only for fee payers |
|---|---|---|
| All test forecasts (MAE) | 9,936 | 9,908 |
| Non-payers, fee months | 10,833 | 10,490 |
| Non-payers, other months | 10,329 | 10,329 |
| Fee payers, fee months | 7,744 | 7,744 |

Changed: `forecast_for_user` gives the model a fee month only when the user pays fees: school fees in their records, a school-fees bill under Plans, or "I pay my own fees" in the profile (`_pays_fees`). The model is not retrained. Test: `test_no_fee_bump_for_someone_who_pays_no_fees` (fails on the old code: January 17,291 against November 16,211 for the same student).

## 2026-11-06: Past months keep the income they were lived on

Found by Kevin: raising the profile income made earlier months look healthier. Months without statement income were all scored with today's profile income, so a raise rewrote the user's own history and the score (which looks at recent months) jumped.

Test case (KES 30,000 allowance, six months spending about 29,000): all six months Strained, score 50. Income raised to 60,000 on the old code: all six Stable, score 100. On the new code: still Strained, score 50; the new income shows in this month's figures and in months recorded from now on.

Changed: a new table `income_history` keeps "from this month the income is X" whenever incomes are saved or an income change is applied with "I'm doing this". Each past month uses the income of its time; statement months keep what actually arrived. Saving asks whether the income changed (from this month) or a mistake is being corrected (`incomeChange: correction` clears the history so every month uses the new figure). Accounts with no history behave as before. Test: `test_a_new_income_does_not_rewrite_past_months` (fails on the old code).

Also added to the profile, for the new onboarding: a first name, how money comes in (pick all that apply: salary, casual work, business, farming, support from family or HELB, pension, not earning), studying, and children in school; the email is returned with the profile. Only "salary" reaches the models, as the existing formal-job input (the formal/informal split the training data was built on), so no model was retrained or re-tested.

## 2026-11-07: A month without the tagged pay is not "no income"

Found on Kevin's own statement (new account, Nov 2025 to Nov 2026, profile income KES 27,000, one source tagged as pay or allowance). Once a source is tagged as income, statement months use only what that source paid. It paid January to July; in November and December 2025 and August to October 2026 it paid nothing, while KES 15,700-27,050 a month came in from his own accounts plus 2,500-17,000 from people. Those five months were scored with income 0, so they came out Critical and the score collapsed.

The app cannot tell an allowance paid into a bank and moved to M-PESA from living on savings. Scoring a month as "nothing came in" while 20,000-30,000 arrived is the worse error, so the rule is now: when the tagged pay is missing in a statement month but money came in from the user's own accounts or from people, that money counts as income up to the usual (profile) income. A month with no money in at all still shows 0, so a late allowance still shows. For this statement the five months become 24,002 / 27,000 / 27,000 / 18,420 / 27,000 instead of 0. Test: `test_a_month_without_the_tagged_pay_is_not_scored_as_no_income` (fails on the old rule).

Limitation to state: someone genuinely living on savings now looks as if their usual income arrived. The note on Overview and the tags in Who pays you remain the way to correct it.


## 2026-11-07: Faster screens - fewer database queries per request

**Why.** Opening Overview took several seconds against the cloud database (Neon, US East). Each query is a round trip, so the number of queries per request decides the wait more than the work done in them.

**Cause.** Two things. The SQLAlchemy session keeps loaded rows only while something holds them (a weak identity map), so `s.get()` for the same commitments row went back to the database every time a helper asked for it. And every Overview and forecast load rewrote the month snapshots, changed or not.

**Change.** Within one request: the commitments row, each month's saved budget and the user's transactions are loaded once and reused (`_commitments_row`, `_saved_budget`, `_all_txs`, kept in `s.info`, which ends with the request). Snapshots are read in one query and only changed months are written; nothing is committed when nothing changed. On the phone and web app, Overview's requests run in parallel, tabs are built the first time they are opened, the last figures are shown at once while fresh ones load (kept on the device, removed at log out), and grey placeholder cards replace the bare spinner on the first load.

**Result** (queries per request, same test account):

| Request | Before | After |
|---|---|---|
| Overview (`/me/dashboard`) | 36 | 15 |
| Budget forecast | 21 | 12 |
| Afford check | 13 | 11 |

Local times after: Overview 123 ms, budget forecast 79 ms, afford 150 ms. All tests pass unchanged; the answers are the same, only fetched fewer times.

## 2026-11-08: How much the household's own spending pattern counts in the budget

Script: scripts/own_weight_experiment.py. Data: KIHBS-informed synthetic dataset v2, held-out (test) households,
Stable months only. For month t the household's own everyday shares come from its previous months (at most 6);
the prediction is the month's actual everyday total times the blended shares, (1 - w) x households like you
(Random Forest + average Stable split, 28 Oct) + w x own shares. Error: KES off per category, summed over the six
everyday categories. Test households split in two by ID: weights chosen on one half, confirmed once on the other.
Rule fixed before running: keep 0.5 unless another weight is more than 2% better on the choosing half, and adopt
it only where the confirming half does not get worse.

| History | Choosing half: 0.5 / chosen | Chosen w | Confirming half: 0.5 / chosen | Decision |
|---|---|---|---|---|
| 1-2 months (n=34) | 7,224 / 6,424 | 0.67 | 3,927 / 3,907 | 0.67 (confirmed, small gain) |
| 3-5 months (n=51) | 5,096 / 4,944 | 0.8 | 5,562 / 5,598 | 0.5 (not confirmed) |
| 6+ months (n=111) | 5,275 / 4,824 | 0.8 | 4,846 / 4,505 | 0.8 (confirmed, 7% better) |

Finding: the household's own pattern deserves more weight as history grows; with 6+ months it should count for
80%. Not used for the decision, but noted: w = 0.67 beat 0.5 in all six cells (both halves, every bucket), so a
single 0.67 would also have been a safe choice. Caveat: the synthetic households keep fairly stable shares over
the year, which favours their own past; real households may change more, so the volunteers' months are the check.
The w = 0 column (households like you only) is the worst everywhere: personalising the split clearly helps.
