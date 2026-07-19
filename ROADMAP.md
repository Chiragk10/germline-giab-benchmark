# Project 1 — Clinical-grade Germline Pipeline + GIAB Benchmark

## Goal
Wrap the gold-standard **nf-core/sarek** germline pipeline in a thin, reproducible layer
that adds (1) a caller-agnostic **hap.py concordance benchmark** against a GIAB truth set,
(2) explicit **targeted-panel mode** with off-target metrics, (3) **ANNOVAR** annotation
alongside sarek's native VEP/snpEff, and (4) a **dual executor** (AWS Batch + Slurm) driven
from one codebase. The benchmark table (precision/recall/F1 per caller) is the deliverable;
sarek is the engine.

## Target level
Intermediate bioinformatics engineer. Everything must be reproducible end-to-end by the
user alone — pinned versions, committed configs, exact run commands.

## Scope decisions (locked 2026-07-16)
- **Build approach:** *extend/wrap* nf-core/sarek — do NOT fork/rewrite its core. Trigger
  sarek as a pinned pipeline (`-r 3.9.0`, the version already proven on this AWS account);
  add our benchmark/annotation/metrics as surrounding Nextflow processes. Inherit their
  container bumps without maintenance debt.
- **Benchmark sample:** **HG002 / NA24385** (GIAB Ashkenazim son) — the modern GIAB standard
  (more comprehensive, actively updated truth sets vs. the classic HG001/NA12878).
- **Benchmark scope:** **chr20 only** — the standard GIAB dev/benchmark convention. Honors
  the project's non-negotiable cost-discipline rule. All-in target: **< $5**.
- **Truth set:** **GIAB NISTv4.2.1** small-variant benchmark, GRCh38 (Truth VCF +
  high-confidence BED), scored with **hap.py v0.3.x + rtg-tools vcfeval**.
- **Caller order:** **GATK HaplotypeCaller first**, DeepVariant added as Phase G (phase 2).
- **Repo layout:** self-contained sibling dir `germline-benchmark/` (this folder) — kept
  clean of the PGx roadmap / DynamoDB work.
- **Reference build:** GRCh38, `chr`-prefixed. Truth VCF, Truth BED, reference FASTA, and
  extracted reads MUST all share this convention (see Pitfall #1).

## Cost discipline (inherited, non-negotiable)
- Single sample, chr20-only. No whole-genome, no cohort runs.
- Estimate cost before provisioning ANY AWS resource.
- Reuse the existing scale-to-zero Batch setup (ChiragQueue / ChiragCompute, us-east-1).
  Set a sane `maxvCpus` cap so a mis-scatter can't spike the bill.
- Flag anything with standing monthly cost before building.

## Infra reuse (already solved in the PGx project)
- AWS Batch: ChiragQueue / ChiragCompute, us-east-1, Fusion/Wave enabled (Seqera token in
  gitignored `nextflow.config`; commit `nextflow.config.example` only).
- S3: reuse `chirag-pgx-variant-pipeline-619759453039` under a new `germline-benchmark/`
  prefix (work/ with 14-day lifecycle, data/, results/), OR a dedicated bucket — decide at
  Phase A, estimate first.

---

## Phases

### Phase A — Data + truth set staging  *(target: ~free / cents, S3 egress only)*
- Pull the GIAB **HG002 30x Illumina NovaSeq CRAM** already mapped to GRCh38 from the GIAB
  FTP (`.../AshkenazimTrio/HG002_NA24385_son/`).
- Extract chr20 **mate-aware** (avoids MarkDuplicates orphaned-mate errors):
  ```
  samtools view -h -T GRCh38.fa HG002.cram chr20 \
    | samtools collate -O -u - \
    | samtools fastq -1 HG002_chr20_R1.fq.gz -2 HG002_chr20_R2.fq.gz \
                     -0 /dev/null -s /dev/null -n
  ```
  (Boundary reads whose mate is on chr19 drop out as singletons — negligible; evaluation is
  confined to the chr20 HC BED, away from the edges.)
- Pull GIAB **NISTv4.2.1** Truth VCF + high-confidence BED (GRCh38), subset both to chr20.
- **Verify before trusting anything:** `samtools depth` / mosdepth on the extracted reads to
  confirm real chr20 coverage (same discipline that caught the VKORC1 no-coverage artifact
  in the PGx project). Confirm `chr20` naming is identical across reads/ref/VCF/BED.

### Phase B — Sarek run, GATK HC path, chr20 intervals  *(target: ~$1–3)*
- Run pinned `nf-core/sarek -r 3.9.0 --tools haplotypecaller --wes --intervals chr20.bed`
  from the extracted FASTQs — full path exercised: fastp → BWA-MEM2 (re-align from scratch)
  → MarkDuplicates → BQSR → HaplotypeCaller. `--wes` + `--intervals` is exactly how panel /
  off-target behavior comes for free.
- Output: GRCh38 chr20 germline VCF.
- Reuse the existing Batch/Fusion profile; cap `maxvCpus`.

### Phase C — hap.py benchmark harness  *(the centerpiece)*
- Small Nextflow process wrapping `pkrusche/hap.py` (uses rtg-tools vcfeval for
  haplotype-aware, normalization-safe comparison — no naive line-by-line diff).
- Inputs: {query VCF, Truth VCF, HC BED, ref FASTA}. Outputs: precision / recall / F1
  **stratified by SNP vs INDEL**.
- Caller-agnostic by design — reused unchanged for DeepVariant in Phase G.
- Emit a clean concordance table + roll into the MultiQC / HTML summary.

### Phase D — Panel mode + off-target metrics
- Formalize the BED-driven interval handling from Phase B into a documented `--panel` entry.
- Compute on-target rate, mean target coverage, fold-80 penalty, off-target read fraction
  (Picard CollectHsMetrics and/or mosdepth). Demonstrates the sequencing-economics angle,
  not just variant calling.

### Phase E — ANNOVAR annotation  *(flag before wiring — licensing)*
- Add ANNOVAR as an **optional** annotation module beside sarek's VEP/snpEff (covers all
  three annotators).
- **Licensing hitch:** ANNOVAR is not open for commercial use and its DBs come via a
  registration-gated manual download — cannot pull a ready-made container with DBs baked in.
  Plan: user downloads DBs once → sync to S3 → Nextflow process consumes an S3 DB path.
  **Confirm with user before implementing.**

### Phase F — Dual executor: Slurm profile
- Add `conf/slurm.config` beside the existing AWS Batch profile so the *same codebase* runs
  via `-profile aws_batch` or `-profile slurm`.
- No real Slurm cluster on hand → validate with a single-node Slurm-in-Docker and/or
  `-stub` dry-run; document the intended cluster submit. **Honest scope note, not a fake
  "ran on HPC" claim.**

### Phase G — DeepVariant swap + head-to-head  *(phase 2)*
- Re-run Phase B with `--tools deepvariant` (CPU on Batch; Google-provided WGS model).
- Re-score through the **same** Phase C harness → publish the two-caller precision/recall/F1
  table. DeepVariant (CNN over pileup images) typically wins on INDEL recall — the
  "swappable calling module + benchmark" story lands here.

### Phase H — Reproducibility wrap
- Pin container digests; commit `nextflow.config.example`, a `README` with exact run
  commands, and a `run.sh` / `Makefile` for one-command end-to-end reproduction.
- Check the final benchmark table into the repo.
- Private GitHub under Chiragk10; keep secrets/tokens gitignored (same pattern as PGx repo).

---

## Phase A result (completed 2026-07-16)
**Deviation from the original plan, worth flagging:** rather than pulling the full-genome
GIAB HG002 CRAM (tens of GB) and extracting chr20 locally, used a pre-subset chr20 BAM that
Google's DeepVariant team already publishes for their own case studies:
`gs://deepvariant/case-study-testdata/HG002.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam`
(public, no auth, 1.09GB). Verified before trusting it: `@SQ` header carries the full
GRCh38 `chr`-prefixed dictionary (not a truncated header — the file is subset by read
content, not header rewriting), `@RG SM:HG002`, aligned with `bwa mem` against
`grch38_bwa_index` per the `@PG` line, and `samtools idxstats` confirms reads exist on
`chr20` only (19.4M) — zero reads on every other contig. Same sample, same region, same
reference build as the locked scope decision; this just skips a redundant multi-GB
download. Reads were still put back through mate-aware FASTQ extraction (not fed to sarek
as a pre-aligned BAM) so Phase B still exercises the full fastp → BWA-MEM2 → MarkDuplicates
→ BQSR → HaplotypeCaller path from raw reads, per the original plan.

Steps taken:
1. Downloaded the BAM + `.bai` above → `data/reads/`.
2. `samtools collate -O -u | samtools fastq -1 ... -2 ... -0 /dev/null -s /dev/null -n -`
   (mate-aware, avoids orphaned-mate MarkDuplicates failures) → `data/reads/HG002_chr20_R1.fq.gz`
   / `_R2.fq.gz`, 9,462,450 read pairs each (R1/R2 line counts match exactly — clean pairing).
3. Downloaded NISTv4.2.1 truth VCF (`.vcf.gz`+`.tbi`) and high-confidence BED from
   `ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/`
   (note: the actual BED filename on this release is `..._benchmark_noinconsistent.bed`,
   not `..._benchmark.bed`). Subset both to chr20 with `bcftools view -r chr20` (85,951
   records) and `awk '$1=="chr20"'` (10,192 intervals) → `data/truth/HG002_GRCh38_chr20_*`.
4. **Coverage verified before trusting anything** (same discipline that caught the VKORC1
   no-coverage artifact in the PGx project): `samtools coverage` on the chr20 BAM shows
   39.86x mean depth, 98.97% breadth, mean MAPQ 54 across chr20, and confirmed **zero**
   reads on every other contig (clean chr20-only subset, no cross-contamination).
5. **Naming consistency confirmed**: BAM (`chr20`), truth VCF (`chr20` via
   `bcftools -r chr20`), truth BED (`chr20` via awk filter) — all `chr`-prefixed GRCh38,
   satisfying pitfall #1.

Outputs: `data/reads/HG002_chr20_R{1,2}.fq.gz`, `data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark.vcf.gz(.tbi)`,
`data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark_noinconsistent.bed`, `data/chr20.bed`
(calling intervals), `samplesheet.csv` (sarek FASTQ-mode input).

**AWS/cost:** $0 — all local (GCS/NCBI downloads + local Docker samtools/bcftools).

## Phase B result (completed 2026-07-17)
Ran pinned `nf-core/sarek -r 3.9.0 -profile docker --tools haplotypecaller --wes
--intervals data/chr20.bed` on AWS Batch (ChiragQueue/ChiragCompute), full path from raw
FASTQ: fastp → BWA-MEM1 (sarek 3.9.0's actual default aligner is classic bwa-mem, not
bwa-mem2 as assumed in the original plan) → GATK4 MarkDuplicates → BaseRecalibrator/
ApplyBQSR → HaplotypeCaller → CNNScoreVariants → FilterVariantTranches → bcftools/vcftools
QC → MultiQC. Reference read directly from the existing `s3://ngi-igenomes` GATK.GRCh38
bundle (no download/indexing cost), same pattern proven in the PGx project's `pgx_call.nf`.

**Real infra issue hit and fixed:** the initial run failed with AWS Batch
`MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT` on `BWAMEM1_MEM` — the job requested 24 vCPU,
but `ChiragCompute`'s `default_x86_64` instance selection resolves to the classic AWS Batch
"optimal" family, which tops out at ~16 vCPU/instance. This is a **permanent** mismatch
(confirmed via `aws batch describe-jobs`: zero EC2 capacity ever launched, not a transient
capacity wait) — sarek's `process_high` label (12 CPU/72GB nominal) was being scaled past
what any instance in that family could ever satisfy. Fixed by adding
`process.resourceLimits = [ cpus: 15, memory: 58.GB, time: 24.h ]` to this project's own
`nextflow.config` (not the shared compute environment) — chr20-only alignment doesn't need
process_high's full-genome sizing anyway. The failed run left 11 stuck `RUNNABLE` jobs on
the shared queue (harmless — they could never launch capacity — but cleaned up after
confirming with the user, since the queue is shared with the PGx project).

**Real-time cost-safety practice established this phase:** ran a `-preview` dry-run first
(validates DAG/config with zero AWS Batch submission), then live-monitored the actual run
via CloudWatch/`aws batch describe-jobs`/`aws ec2 describe-instances` for its full duration
rather than treating pipeline launch as fire-and-forget. The run was deliberately stopped
mid-flight one evening (`aws batch terminate-job` + direct `aws ec2 terminate-instances`,
confirmed `terminated` state before ending the session) and cleanly resumed the next day
with `nextflow run ... -resume`, which skipped all 25 already-cached tasks and only
re-ran the remaining HaplotypeCaller-onward steps (8 processes) — zero wasted recompute.

**Output:** `s3://chirag-pgx-variant-pipeline-619759453039/results/germline-benchmark/variant_calling/haplotypecaller/HG002_chr20/HG002_chr20.haplotypecaller.filtered.vcf.gz`
— 132,108 variant records (110,272 SNPs, 21,950 indels) before hap.py comparison against
the GIAB truth set. MultiQC report and per-sample CSVs also under `results/germline-benchmark/`.

**AWS/cost:** within the $1–3 target (single `c7i.4xlarge` instance for the bulk of the
run, scale-to-zero before and after — final `aws ec2 describe-instances` sweep confirmed
zero running/pending instances at session end both days).

## Phase C result (completed 2026-07-18) — the centerpiece deliverable
Ran hap.py 0.3.15 (`quay.io/biocontainers/hap.py:0.3.15--py27hcb73b3d_0`) with the
**vcfeval** comparison engine (rtg-tools 3.12.1), scoring Phase B's
`HG002_chr20.haplotypecaller.filtered.vcf.gz` against the GIAB NISTv4.2.1 chr20 truth
VCF+BED from Phase A. Ran entirely **locally** (no AWS Batch — a single fast VCF
comparison doesn't justify cloud infra, same reasoning as running PharmCAT locally in
the PGx project) — genuinely $0.

**Real infra issue hit and fixed:** `docker pull pkrusche/hap.py` (the roadmap's original
choice) failed outright — that image uses a legacy Docker manifest schema (v1) no longer
supported by current containerd. Switched to the actively-maintained
`quay.io/biocontainers/hap.py` build. That image has **no bundled JVM**, but vcfeval
requires one (rtg-tools is Java-based) — running `--engine=vcfeval` inside it fails with
"rtg: not found". Fixed by extracting rtg-tools + its own bundled JVM + the specific
shared libs both need (`libz.so.1`, `libstdc++.so.6`, `libgcc_s.so.1` — none present in
the minimal hap.py image) out of the separate `quay.io/biocontainers/rtg-tools` image via
`docker cp`, then bind-mounting them into the hap.py container at the *exact* paths
`rtg.cfg` hardcodes (`/usr/local/share/rtg-tools-3.12.1-1`, overriding `RTG_JAVA`/`RTG_JAR`
resolution via `JAVA_HOME`). Scripted as `scripts/extract_rtg_tools.sh` (idempotent,
re-run to regenerate `tools/` — gitignored, ~371MB, not committed). Wrapped as a proper
Nextflow process (`benchmark_happy.nf`) per the roadmap's reusability goal for Phase G,
validated to produce **byte-identical output** to the manual `docker run` invocation.

**Second infra issue:** this project's default `nextflow.config` targets AWS Batch with
Wave/Fusion enabled — Fusion's binary can't execute outside a real Batch/cloud context, so
`benchmark_happy.nf` failed under the default profile. Added a `local` profile
(`-profile local`: `process.executor = 'local'`, Wave/Fusion off, local `workDir`) to
`nextflow.config`/`nextflow.config.example` for any step that shouldn't touch AWS.

**Results (PASS-filtered, the headline metric):**

| Type  | Recall   | Precision | F1 Score |
|-------|----------|-----------|----------|
| SNP   | 99.397%  | 99.285%   | 99.341%  |
| INDEL | 98.943%  | 99.441%   | 99.191%  |

(ALL-filter rows, including non-PASS calls, are marginally lower — see
`results/happy/HG002_chr20.summary.csv` for the full table with TP/FN/FP counts and
Ti/Tv and het/hom ratios.) These are strong, expected-range numbers for a single-sample
GATK HaplotypeCaller germline callset on a well-behaved autosome — no red flags.

Outputs: `results/happy/HG002_chr20.summary.csv` (headline table),
`HG002_chr20.extended.csv` (full stratification), `HG002_chr20.vcf.gz` (annotated
TP/FP/FN per-variant calls for manual inspection), ROC curve CSVs.

**AWS/cost:** $0 (fully local).

## Phase D result (completed 2026-07-18)
**Honest scope note up front:** this data is WGS reads computationally subset to chr20
(Phase A), not a real hybrid-capture/panel-enrichment experiment. "On-target rate" and
"off-target fraction" against a small panel therefore aren't a capture-efficiency
statement here - they're expected to be roughly the panel's geometric size fraction of
chr20, and that's exactly what was measured (see below), which is itself the correct
sanity check for a --panel entry's mechanics, not a demonstration of assay chemistry.

**Mock panel:** PRNP (prion disease gene, `chr20:4,684,730-4,702,590`, GRCh38, 1000bp
flank each side, 17,860bp - coordinates verified directly via the Ensembl REST API, not
guessed) - `data/panel_prnp.bed`. Chosen for being real, compact, and clinically
recognizable (fits the project's "clinical-grade" framing) rather than an arbitrary
coordinate range.

**Tooling change from the original plan:** the roadmap's mocked "Picard CollectHsMetrics"
choice hit a real wall - Picard enforces that the reference FASTA's sequence dictionary
exactly match the CRAM's, and sarek's CRAM carries the full 3,366-contig GATK GRCh38
dictionary (aligned against the whole genome, not just chr20). Satisfying that check would
have meant keeping a 3.25GB reference on disk for a tool that only actually needs chr20's
bases. Dropped Picard for this step; computed the same metrics directly with `samtools
view -c -L` (on/off-target read counts) and `mosdepth --by` (target coverage, threshold
breakdown) - both already work fine against just `data/ref/chr20.fa`.

**Results** (`results/panel_metrics/HG002_chr20_PRNP_panel_summary.csv`):

| Metric | Value |
|---|---|
| On-target reads | 5,203 / 18,577,986 (0.0280%) |
| Panel's geometric fraction of chr20 | 0.0277% |
| Panel mean coverage | 36.43x |
| chr20-wide mean coverage | 36.28x (ratio 1.004) |
| Panel bases ≥1x / ≥10x / ≥20x / ≥30x | 100% / 99.99% / 99.75% / 86.91% |

On-target rate tracking the panel's geometric fraction almost exactly (0.0280% vs
0.0277%), and panel coverage tracking chr20-wide coverage almost exactly (ratio 1.004),
both confirm genuinely uniform WGS-derived coverage with zero enrichment bias - the
correct, expected result for this data, not a red flag.

**AWS/cost:** $0 (fully local, all inputs already staged from Phase B's S3 output).

**Disk hygiene note (2026-07-18):** hit real friction here from guessing Docker image
names without verifying first (`staphb/mosdepth` doesn't exist; a `docker pull | tail`
also silently masked a real pull failure earlier in the session) and from reaching for a
tool (Picard) that forced an unnecessarily large reference download instead of picking a
lighter tool that already worked with what was on disk. Now standard practice for this
project: verify an image actually exists/pulls before building a step around it, and
delete large downloaded artifacts (CRAMs, whole-genome references, superseded BAMs/FASTQs)
as soon as their output has been extracted and durably stored (S3 or `results/`) - nothing
here is precious raw data, all of it is cheaply re-fetchable from its documented source
URL if ever needed again.

## Phase E result (completed 2026-07-18) — VEP + snpEff, ANNOVAR deferred
**Scope decision:** ANNOVAR is licensing-gated (individual registration + manual DB
download, no automatable path) and, on review, not technically necessary - VEP is the
modern field-standard annotator and already covers population frequency + predicted
deleteriousness; ANNOVAR's edge is mainly its historical standing in clinical diagnostic
labs, not unique capability. Ran VEP + snpEff now (zero licensing friction, sarek-native);
left ANNOVAR as a distinct, optional follow-up gated on the user doing the registration
step themselves.

Ran via `nf-core/sarek --step annotate --tools vep,snpeff` against the Phase B
`HG002_chr20.haplotypecaller.filtered.vcf.gz` output. Both `vep_cache` (115_GRCh38) and
`snpeff_cache` (GRCh38.99) resolved to sarek's own public defaults
(`s3://annotation-cache/{vep,snpeff}_cache/`) - no manual cache download, no local disk
use, read directly by the Batch job, matching what Phase B's own config dump had already
resolved.

**Real issue hit and fixed:** first attempt reused Phase B's FASTQ-based `samplesheet.csv`
with `-resume`, which failed pipeline parameter validation - Nextflow's schema check
requires the samplesheet's local input files to physically exist even under `-resume`
(resume only skips already-cached *tasks*, it doesn't bypass upfront input validation),
and the local FASTQs had just been deleted per the disk-hygiene cleanup in the Phase D
writeup. Rather than re-fetching the BAM/FASTQ just to satisfy validation, switched to
sarek's dedicated `--step annotate` mode with a VCF-based samplesheet
(`samplesheet_annotate.csv`, pointing straight at the Phase B S3 VCF) - this structurally
skips the alignment/calling stages entirely rather than relying on cache-hit luck, and
needs no local raw-read files at all. Better fix than what `-resume` would have given
even if it had worked.

**Output:** confirmed real, rich annotations in both files -
`HG002_chr20.haplotypecaller.filtered_VEP.ann.vcf.gz` (`CSQ` field: consequence, gene/
transcript, SIFT/PolyPhen, gnomAD population AFs) and
`..._snpEff.ann.vcf.gz` (`ANN` field: functional impact, HGVS.c/HGVS.p notation) under
`s3://.../results/germline-benchmark/annotation/haplotypecaller/HG002_chr20/`.

**AWS/cost:** ~$0.10-0.50 (two `process_medium` AWS Batch jobs, a few minutes each,
scale-to-zero before and after - confirmed zero running instances post-run).

## Supplementary: Athena SQL over results (completed 2026-07-18, not one of the numbered phases)
**Context:** user asked whether DynamoDB was needed going forward and wanted a SQL-query
skillset. Answer given: DynamoDB isn't actually SQL (NoSQL/key-value; PartiQL is a
bolt-on, not the general relational skillset), and isn't needed for this project anyway
(deliverable is a committed benchmark table, not a queryable service - see Phase C/D
discussion). **Athena** is the better fit: serverless real SQL directly over the CSV
result tables already sitting in S3, zero standing infrastructure, pay-per-query only.

**Setup:** uploaded `results/happy/HG002_chr20.summary.csv` and
`results/panel_metrics/HG002_chr20_PRNP_panel_summary.csv` (previously local-only, since
Phase C/D ran with the local Nextflow profile) to
`s3://chirag-pgx-variant-pipeline-619759453039/results/germline-benchmark/benchmark_tables/`.
Created Glue database `germline_benchmark` with two external tables (`happy_summary`,
`panel_metrics`) via `OpenCSVSerde` DDL - reused the existing `primary` Athena workgroup,
no new workgroup/infra needed. Query helper: `scripts/athena_query.sh`.

**Example queries run** (all real SQL, real results, sub-cent cost each):
1. Filtered SELECT — PASS-only precision/recall/F1 per variant type
2. Aggregate — pooled SNP+INDEL recall/precision from raw TP/FN/FP counts (99.34%/99.30%,
   a number that doesn't exist in any single CSV row - genuinely computed by the query)
3. Pattern-matched SELECT — coverage/on-target metrics from the panel table

**AWS/cost:** three queries scanned 851, 791, and 851 bytes respectively. Athena bills a
10MB minimum per query, so actual cost is ~$0.00005/query (~$0.00015 total for this whole
exploration) - Glue Data Catalog storage for two tiny tables is within the AWS Glue free
tier. No standing cost: Athena and Glue Data Catalog are both fully serverless, nothing to
tear down or scale to zero.

### Extension: stratified + ROC data, and a no-AWS-account DuckDB path (2026-07-19)
The first pass only queried summary-level tables (one row per variant type). Extended it
with two more tables that actually have something to stratify by:

- **`happy_extended`** - built from hap.py's `extended.csv`, filtered to `Subset='*'`
  (drops a `TS_contained` duplicate row that's identical at this truth-set scale) and
  projected to 10 columns. The real content here is the `Subtype` field, which hap.py
  uses to break INDELs down by **size/complexity class** (`D1_5`/`I1_5` = 1-5bp
  deletions/insertions, up to `D16_PLUS`/`I16_PLUS` = 16bp+, plus complex-indel classes
  `C1_5`/`C6_15`/`C16_PLUS` which are empty for this truth region - a real "doesn't occur
  here" result, not a bug). This is a genuine stratum, not a cosmetic one.
- **`roc_curve`** - built from `roc.Locations.{SNP,INDEL}.PASS.csv.gz`, filtered to
  `Subtype='*'`/`Subset='*'` and concatenated. One row per distinct QUAL score hap.py's
  vcfeval-derived ROC curve observed (7,043 rows total) - lets a query ask "at what QUAL
  threshold does precision/recall cross X", not just read off the single fixed-threshold
  PASS/ALL numbers already in `happy_summary`.

**Query 1 (F1 by indel-size stratum, PASS-filtered):**
```sql
SELECT indel_size_stratum, truth_total, metric_recall, metric_precision, metric_f1_score
FROM germline_benchmark.happy_extended
WHERE variant_type = 'INDEL' AND filter = 'PASS' AND truth_total > 0 AND indel_size_stratum <> '*'
ORDER BY truth_total DESC
```
Result: F1 degrades monotonically with indel size - 0.994 (1-5bp deletions) down to 0.955
(16bp+ insertions). This is the textbook variant-calling failure mode (longer indels are
harder to align/assemble around), and the query surfaces it directly from real per-stratum
counts, not a canned number.

**Query 2 (QUAL threshold where SNP recall first drops below 99%):** finds QUAL≈126.6 as
the crossing point, precision ~99.56% there - a real precision/recall trade-off read off
the ROC curve, not the single fixed operating point in `happy_summary`.

**Deliberately did NOT do physical Athena/Glue partitioning** ("partition by region-type"
was the original idea). Partitioning exists to let a query engine skip scanning irrelevant
S3 prefixes on datasets where that scan cost matters - at a few hundred KB total, there is
nothing to skip and no cost/latency it would save. Stratification here is done the honest
way: a `WHERE`/`GROUP BY` on a real column (`indel_size_stratum`), not a physical
partition layout that would only be doing something at 1000x+ this data volume.

**DuckDB local path (`scripts/duckdb_queries.sql`):** same two queries, run with
`duckdb < scripts/duckdb_queries.sql` directly against the committed
`results/sql/*.csv` files - no AWS account, no credentials, no server. Verified
byte-identical results to the Athena versions before committing. Closes a real
reproducibility gap: previously "reproduce the SQL layer" meant "have my AWS account,"
which nobody reviewing this repo has.

**AWS/cost:** two new tables, ~440KB total S3 storage (Glue free tier). Both queries
scanned under Athena's 10MB minimum, so ~$0.0001 total. No standing cost.

## Pitfalls to watch (from review 2026-07-16)
1. **`chr20` vs `20` naming trap** — #1 cause of silent zero-overlap failures. Reads, ref
   FASTA, Truth VCF, Truth BED must ALL use `chr`-prefixed GRCh38. Extracting from the
   already-`chr`-named CRAM closes this at the source; keep sarek's ref build matched.
2. **Subsetting artifacts** — orphaned mates from region extraction break MarkDuplicates.
   Mitigated by the `collate`-then-`fastq -n` recipe in Phase A.
3. **ANNOVAR licensing** — no baked-DB container; registration-gated DB download → S3 → path.
4. **Batch concurrency** — sarek scatter-gathers even on chr20; cap `maxvCpus` so a bad
   config can't spike the bill.
5. **Version pinning** — pin `sarek -r 3.9.0` explicitly so an upstream breaking change
   can't silently break the benchmark later.

## Data provenance
- GIAB HG002 reads + NISTv4.2.1 truth set: GIAB FTP, AshkenazimTrio release, `NISTv4.2.1/`.
- Benchmark method: hap.py + rtg-tools vcfeval, per GA4GH benchmarking-tools best practice.

## Progress checklist
- [x] Phase A: HG002 CRAM → mate-aware chr20 FASTQ + NISTv4.2.1 truth subset + coverage check
      (completed 2026-07-16 — see Phase A result below)
- [x] Phase B: sarek 3.9.0 HC path, chr20 intervals → chr20 VCF (completed 2026-07-17)
- [x] Phase C: hap.py harness → SNP/INDEL precision/recall/F1 table (completed 2026-07-18)
- [x] Phase D: panel mode + off-target metrics (completed 2026-07-18)
- [x] Phase E (partial): VEP + snpEff annotation (completed 2026-07-18) - see result below;
      ANNOVAR itself remains not-done, deliberately deferred (licensing/registration is a
      manual step only the user can do - not blocking, VEP+snpEff already deliver the
      annotation goal)
- [ ] Phase F: Slurm profile (validated via Slurm-in-Docker / -stub)
- [ ] Phase G: DeepVariant swap + two-caller head-to-head
- [ ] Phase H: reproducibility wrap (README, run.sh, pinned digests, committed table)
