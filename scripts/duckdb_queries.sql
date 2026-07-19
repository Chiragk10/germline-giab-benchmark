-- Same SQL as scripts/athena_query.sh runs against Glue tables, run here directly
-- against the committed CSVs. No AWS account needed - this is the reviewer-friendly path.
--
-- Usage:
--   duckdb < scripts/duckdb_queries.sql
-- (grab the duckdb CLI: https://duckdb.org/docs/installation - single static binary, no install)

-- F1 by indel-size stratum (PASS-filtered) - accuracy degrades as indels get longer,
-- the classic variant-calling failure mode: alignment/assembly gets harder around longer
-- insertions and deletions, so both recall and precision fall off for 16bp+ indels.
SELECT indel_size_stratum, truth_total, metric_recall, metric_precision, metric_f1_score
FROM read_csv_auto('results/sql/happy_extended_stratified.csv')
WHERE variant_type = 'INDEL' AND filter = 'PASS' AND truth_total > 0 AND indel_size_stratum <> '*'
ORDER BY truth_total DESC;

-- QUAL threshold at which SNP recall first drops below 99% - a real precision/recall
-- trade-off computed from the ROC curve hap.py generates internally, not from a
-- single fixed threshold.
SELECT variant_type, qual_threshold, metric_recall, metric_precision, metric_f1_score
FROM read_csv_auto('results/sql/roc_curve_pass.csv')
WHERE variant_type = 'SNP' AND metric_recall < 0.99
ORDER BY qual_threshold ASC
LIMIT 5;
