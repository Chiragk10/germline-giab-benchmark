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

## What's here

- **[`WALKTHROUGH.md`](WALKTHROUGH.md)** — narrative, step-by-step account of how this
  was built: every command, every file explained, every problem hit and how it was fixed.
  Start here if you want to actually understand the pipeline, not just the results.
- **[`ROADMAP.md`](ROADMAP.md)** — the phase-by-phase plan and results log, with exact
  costs, scope decisions, and pitfalls documented as they were found.
- **`*.nf`** — the Nextflow entry points (`benchmark_happy.nf` for the hap.py harness;
  sarek itself is invoked directly via `nextflow run nf-core/sarek`, not vendored here).
- **`scripts/`** — reproduction scripts (FASTQ extraction, rtg-tools/JVM setup, Athena
  query helper).
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
