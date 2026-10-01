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
