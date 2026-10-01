#!/usr/bin/env bash
# One-off GitHub project setup: labels, milestones (= the 8 Scrum sprints in the proposal) and starter issues.
# Prereqs: `gh auth status` works, and this folder has a GitHub remote (see README steps in chat).
# Run ONCE. Labels use --force (safe to re-run); milestones/issues would duplicate if re-run.
set -euo pipefail
command -v gh >/dev/null || { echo "Install GitHub CLI first: brew install gh && gh auth login"; exit 1; }
gh repo view >/dev/null 2>&1 || { echo "No GitHub remote yet. Create it first (gh repo create ... --private --source=. --remote=origin)"; exit 1; }

echo "== labels"
while IFS='|' read -r name color desc; do
  gh label create "$name" --color "$color" --description "$desc" --force >/dev/null
done <<'LABELS'
type: bug|d73a4a|Something is wrong
type: feature|0e8a16|New capability
type: experiment|5319e7|Hypothesis, config, result, decision logged in docs/experiments.md
type: data|1d76db|Dataset generation or cleaning
type: docs|0075ca|Documentation or report
type: supervisor-feedback|fbca04|Raised by the supervisor
type: validation|c5def5|Testing against real or held-out data
area: ingestion|bfd4f2|PDF, CSV, API, manual entry
area: preprocessing|bfd4f2|Cleaning, categorisation, features
area: hmm|bfd4f2|Financial state detection
area: lstm|bfd4f2|Expenditure forecasting
area: rf|bfd4f2|Budget, affordability score, scenarios
area: backend|bfd4f2|Flask, PostgreSQL, auth
area: flutter|bfd4f2|Mobile interface
area: report|bfd4f2|Dissertation
LABELS

echo "== milestones"
while IFS='|' read -r title desc; do
  gh api repos/:owner/:repo/milestones -f title="$title" -f description="$desc" >/dev/null
done <<'MS'
M0 Data foundation|Synthetic dataset v2 grounded in KIHBS, split, feature pipeline
Sprint 1 Data ingestion|PDF/CSV statement parsing, sandbox API, manual entry
Sprint 2 Preprocessing|Cleaning, rule-based categorisation, feature engineering with obligations
Sprint 3 HMM|Financial state detection: training, inference, tests
Sprint 4 LSTM|Per-category 1-3 month forecast, 9-to-3 month backtest
Sprint 5 Random Forest|Rule-based scoring engine, budget recommendation, scenario simulation
Sprint 6 Obligations debt goals|Trackers and goal progress, integrated into the ML inputs
Sprint 7 Mobile interface|Flutter screens and API integration
Sprint 8 Integration and UAT|Integration tests, volunteer validation, fine-tuning, deployment
Final report|Dissertation chapters, limitations, submission
MS

mk() { gh issue create --title "$1" --label "$2" --milestone "$3" --body "$4" >/dev/null && echo "  + $1"; }

echo "== issues"
mk "Align spending categories with the proposal" "type: data" "M0 Data foundation" \
"Proposal lists 11 categories. Data adds investment_vehicle and transaction_fees.
**Acceptance:** fold investment_vehicle into savings and fees into mobile_money_transfers (or document the deviation); regenerate 06/07; update expected HMM results."
mk "Verify 2017-2020 CPI inflation figures used in 04" "type: data,type: docs" "M0 Data foundation" \
"2021-2025 were checked against KNBS/FocusEconomics; 2017-2020 (8.0, 4.7, 5.2, 5.3) are from memory.
**Acceptance:** replace with KNBS values and cite in the report."
mk "Verify school-fee levels and digital-loan cost assumptions in 06" "type: data,type: docs" "M0 Data foundation" \
"Approximate values currently. **Acceptance:** source each parameter or label it clearly as an assumption in the report."
mk "Document synthetic-data assumptions and exclusions" "type: docs" "Final report" \
"State: transition matrices, spending ranges and loan terms are assumptions; self-employed households excluded (no profit measure in KIHBS); urban + peri-urban only.
**Acceptance:** Limitations section (1.5.2) updated."

mk "M-Pesa PDF statement parser (pdfplumber)" "type: feature,area: ingestion" "Sprint 1 Data ingestion" \
"**Acceptance:** parses a real M-Pesa statement into the internal transaction schema; unit tests on at least one anonymised sample."
mk "CSV import with column mapping" "type: feature,area: ingestion" "Sprint 1 Data ingestion" "**Acceptance:** standard bank CSV exports map to the schema."
mk "Manual entry for cash and informal income" "type: feature,area: ingestion" "Sprint 1 Data ingestion" "**Acceptance:** form + API endpoint, validated input."
mk "Rule-based transaction categoriser plus text classifier" "type: feature,area: preprocessing" "Sprint 2 Preprocessing" \
"Keyword rules first, ML refinement for ambiguous cases (proposal 3.2.2). **Acceptance:** accuracy reported on a labelled sample."

mk "HMM: check causal vs full-sequence states" "type: experiment,area: hmm" "Sprint 3 HMM" \
"Full-sequence (Viterbi) states leak the future into forecasting. **Acceptance:** causal states used downstream; agreement reported."
mk "HMM: add downstream check (does state predict next-month overspend?)" "type: validation,area: hmm" "Sprint 3 HMM" \
"Supplement to agreement-with-labels. **Acceptance:** result logged in docs/experiments.md."
mk "HMM: unit tests for state assignment" "type: feature,area: hmm" "Sprint 3 HMM" "Required by the sprint plan. **Acceptance:** tests in tests/."

mk "LSTM: per-category 1-3 month forecast" "type: feature,area: lstm" "Sprint 4 LSTM" \
"Proposal: forecast category totals and total cash flow; MSE loss, Adam; RMSE/MAE.
**Acceptance:** trained on first 9 months, evaluated on last 3, per category and aggregate."
mk "LSTM: baselines (last month, 3-month mean)" "type: experiment,area: lstm" "Sprint 4 LSTM" "**Acceptance:** LSTM compared against both baselines on the same households."

mk "Scenario and affordability label generator" "type: data,area: rf" "Sprint 5 Random Forest" \
"Simulate a prospective commitment (rent, school, loan, dependant) and record the outcome. **Acceptance:** labelled dataset with risk tier and 0-100 score."
mk "Rule-based affordability scoring engine (0-100)" "type: feature,area: rf" "Sprint 5 Random Forest" "Deterministic part from guaranteed outflows and income. **Acceptance:** documented formula plus tests."
mk "Random Forest: risk tier and budget allocation" "type: feature,area: rf" "Sprint 5 Random Forest" "Cross-validated grid search. **Acceptance:** accuracy/precision/recall/F1 reported."
mk "Scenario simulation: Affordable / Marginally / Not affordable" "type: feature,area: rf" "Sprint 5 Random Forest" "**Acceptance:** side-by-side baseline vs projected budget and verdict."

mk "Class diagram: add methods to FinancialStatement" "type: supervisor-feedback,type: docs" "Final report" "Outstanding supervisor feedback."
mk "System architecture diagram: improve visual presentation" "type: supervisor-feedback,type: docs" "Final report" "Outstanding supervisor feedback."

mk "Consent form and data-protection plan for volunteers" "type: docs,type: validation" "Sprint 8 Integration and UAT" "No real statements are collected before this is approved. Real data lives only in data/real/ (git-ignored)."
mk "Collect volunteer statements and run the validation" "type: validation" "Sprint 8 Integration and UAT" "Depends on the consent issue. **Acceptance:** pipeline run on real households, results reported."
echo "Done."
