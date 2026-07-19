# Clinical-Grade Germline Pipeline + GIAB Benchmark

Wraps nf-core/sarek (pinned `v3.9.0`) with a caller-agnostic hap.py/vcfeval concordance
benchmark against a GIAB truth set, targeted-panel on/off-target metrics, and VEP+snpEff
annotation — run end-to-end on AWS Batch, scored against a published truth set, not just
"the pipeline ran without crashing."

**Sample:** HG002/NA24385 (GIAB Ashkenazim son), chr20 only (cost-scoped, GA4GH's
standard benchmark-dev chromosome). **Truth:** GIAB NISTv4.2.1.

## Headline result

hap.py vs. GIAB NISTv4.2.1 truth, PASS-filtered:

| Type | Recall | Precision | F1 |
|---|---|---|---|
| SNP | 99.397% | 99.285% | 99.341% |
| INDEL | 98.943% | 99.441% | 99.191% |

Full table: [`results/happy/HG002_chr20.summary.csv`](results/happy/HG002_chr20.summary.csv)
(extended per-variant-type breakdown in
[`HG002_chr20.extended.csv`](results/happy/HG002_chr20.extended.csv)).

Panel/off-target metrics (PRNP gene as a mock panel — see caveat in
[`ROADMAP.md`](ROADMAP.md#phase-d-result-completed-2026-07-18)):
[`results/panel_metrics/HG002_chr20_PRNP_panel_summary.csv`](results/panel_metrics/HG002_chr20_PRNP_panel_summary.csv).

**F1 by indel-size stratum** (from [`results/sql/happy_extended_stratified.csv`](results/sql/happy_extended_stratified.csv)) —
accuracy degrades with indel length, the classic variant-calling failure mode:

| Indel size class | F1 |
|---|---|
| 1-5bp deletions | 99.37% |
| 1-5bp insertions | 99.12% |
| 6-15bp deletions | 98.66% |
| 6-15bp insertions | 98.52% |
| 16bp+ deletions | 98.47% |
| 16bp+ insertions | 95.49% |

Queryable two ways — both run the same SQL over the same result CSVs, byte-identical
output: **AWS Athena** (`scripts/athena_query.sh`, real SQL over S3-backed Glue tables,
see [`ROADMAP.md`](ROADMAP.md#extension-stratified--roc-data-and-a-no-aws-account-duckdb-path-2026-07-19))
or **DuckDB, locally, no AWS account needed** (`duckdb < scripts/duckdb_queries.sql`).

## What's here

- **[`WALKTHROUGH.md`](WALKTHROUGH.md)** — narrative, step-by-step account of how this
  was built: every command, every file explained, every problem hit and how it was fixed.
  Start here if you want to actually understand the pipeline, not just the results.
- **[`ROADMAP.md`](ROADMAP.md)** — the phase-by-phase plan and results log, with exact
  costs, scope decisions, and pitfalls documented as they were found.
- **`*.nf`** — the Nextflow entry points (`benchmark_happy.nf` for the hap.py harness;
  sarek itself is invoked directly via `nextflow run nf-core/sarek`, not vendored here).
- **`scripts/`** — reproduction scripts (FASTQ extraction, rtg-tools/JVM setup, Athena
  query helper, DuckDB queries).
- **`results/sql/`** — curated CSVs (indel-size-stratified F1, ROC-by-QUAL-threshold)
  queryable via either Athena or DuckDB — see below.
- **`nextflow.config.example`** — copy to `nextflow.config` and fill in your own Seqera
  token to reproduce the AWS Batch runs.

## Reproducing this

Full command-by-command detail is in `WALKTHROUGH.md`. Summary of the pipeline:

1. Pull HG002 chr20 reads (public, pre-subset — see `WALKTHROUGH.md` §1) and the GIAB
   NISTv4.2.1 truth set; verify real coverage before trusting either.
2. `nextflow run nf-core/sarek -r 3.9.0 --tools haplotypecaller --wes --intervals data/chr20.bed`
   on AWS Batch (fastp → BWA → MarkDuplicates → BQSR → HaplotypeCaller → CNN filtering).
3. Score the result against truth with hap.py + rtg-tools vcfeval
   (`nextflow run benchmark_happy.nf -profile local`).
4. Panel/off-target coverage metrics via `samtools`/`mosdepth`.
5. Annotate with VEP + snpEff: `nextflow run nf-core/sarek --step annotate --tools vep,snpeff`.

Everything is cost-scoped: single sample, single chromosome, scale-to-zero AWS Batch.
Actual costs per phase are logged in `ROADMAP.md`.

## Scope notes

- ANNOVAR was evaluated and deliberately not used — see `ROADMAP.md` Phase E for the
  reasoning (licensing friction vs. marginal value over VEP+snpEff).
- Panel/off-target metrics (Phase D) use a real gene (PRNP) as a mock panel against
  whole-genome-derived data — the on-target percentage is not a capture-efficiency claim,
  it's a mechanics demo. Documented explicitly in `ROADMAP.md`.
