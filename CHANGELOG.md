# Changelog

Format follows Keep a Changelog. Dataset tags: `v0.1-data` onward.

## [Unreleased]
### Added
- Unit tests for HMM state detection (`tests/test_hmm.py`).
- Experiment log (`docs/experiments.md`).

## [v0.1.1] - 2026-10-01 - Categories aligned with the proposal (PR #22)
### Changed
- Spending categories now match the proposal's ten: `investment_vehicle` folded into `savings`, M-Pesa fees folded into `mobile_money_transfers`.
- Synthetic dataset and HMM regenerated. Held-out HMM accuracy 0.531 (majority baseline 0.378), Strained recall 0.441.

## [v0.1-data] - 2026-10-01 - Synthetic dataset v2
### Fixed
- **Wage income never loaded.** Member IDs were float strings (`916.0_7`) while the household file used `140_1`, so no rows joined and wage income was zero for every household. `total_income` was only pension, rent and investment income (about 5% of households).
- **Swapped urban labels.** KIHBS `eatype` code 2 holds all Nairobi and Mombasa households and is core urban, not peri-urban.
- **Business flag** was always False (category compared with 1).
- **Households were sampled with replacement**, producing duplicates.
- **HMM evaluation order** mismatch and wrong-household state labels (E1).
- **Normalisation leakage:** features were normalised with test-set statistics; now train households only, with one shared split (`household_split.csv`).
- **Ratio feature:** was expenditure/income with a 5.0 placeholder for zero-income months. Now income/expenditure, bounded, with `zero_income_flag`.
- **Debt-service ratio** used a household constant; now uses each month's actual repayments.

### Changed
- Incomes in 2025 KES (KNBS CPI), tiers from employer type, NSSF/NHIF and contract (`formal_salaried`, `informal_irregular`).
- 300 households (was 150), stratified 50/50 core-urban / peri-urban, 42 counties.
- Spending built bottom-up: rent, school fees, utilities and loan repayments are fixed and match the obligations and debt tables.
- M-Pesa fees use the 2025 Safaricom send-money and withdrawal tariffs.
- Debt prevalence anchored on FinAccess 2024 (64% of adults use credit); non-mortgage loans in 43% of households.
- Dependants and school-age children from KIHBS member ages.
- HMM: unsupervised KMeans initialisation, five features, state names assigned by spending ratio (not by matching true labels).

### Known limitations and items to verify
- KIHBS has no profit measure for self-employed households, so they are excluded.
- Hidden-state transitions, spending ranges, loan terms and school-fee levels are assumptions.
- 2017-2020 CPI inflation rates in `04` are from memory and need checking (issue open).
- KIHBS `has_electricity` is broken (about 1% yes) and unused.
