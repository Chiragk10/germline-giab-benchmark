# Walkthrough: how this pipeline was actually built

This is a narrative record of everything done in this project so far — what data we
pulled, what commands we ran, why each tool was chosen, what the key files actually
contain, and what broke along the way (and how). `ROADMAP.md` is the planning document;
this is the "if you came back in six months and needed to re-explain it to yourself"
document.

---

## 0. The goal, in one sentence

Take a real human genome sample (HG002), run it through the same industry-standard
pipeline (nf-core/sarek) a clinical or research lab would use, and then **prove** the
result is accurate by scoring it against a published truth set — not just "the pipeline
ran without crashing," but "here is the actual precision and recall, measured."

Everything below is in service of that: get real data → call variants → score against
truth → look at coverage economics → annotate what the variants mean.

---

## 1. Getting the data (Phase A)

### The read file

The original plan was to download NA24385/HG002's full-genome CRAM from the GIAB FTP site
(tens of gigabytes) and cut out just chromosome 20 locally. Instead, we found that
Google's DeepVariant team already publishes a **pre-subset chr20 BAM** for their own test
suite — same sample, same chr20 region, same GRCh38 reference build, just without the
other 23 chromosomes' worth of data we didn't need:

```bash
curl -s -o HG002.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam \
  "https://storage.googleapis.com/deepvariant/case-study-testdata/HG002.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam"
```

That's a 1.09GB download instead of ~50GB+. Before trusting it, we checked its header to
confirm it really was what it claimed to be:

```bash
samtools view -H HG002...chr20.bam | head -20      # confirms chr-prefixed GRCh38 contigs
samtools idxstats HG002...chr20.bam                 # confirms reads ONLY on chr20, zero elsewhere
```

### Turning the BAM back into raw reads

Sarek's whole point is to prove the pipeline can go from raw sequencer output to a final
answer — so even though this BAM was already aligned once (by DeepVariant's team, for
their own purposes), we didn't just hand it to sarek as-is. We converted it back to
**FASTQ** (the raw paired-end read format) and let sarek do its own alignment from
scratch:

```bash
samtools collate -O -u HG002...chr20.bam - \
  | samtools fastq -1 HG002_chr20_R1.fq.gz -2 HG002_chr20_R2.fq.gz -0 /dev/null -s /dev/null -n -
```

`collate` (not `sort`) matters here — sorting by coordinate scatters a read pair's two
mates apart in the file, and naively converting that to FASTQ can silently drop or
misplace one mate of a pair, which later breaks MarkDuplicates. `collate` keeps mates
adjacent, which `samtools fastq` needs.

Result: 9,462,450 read pairs (`HG002_chr20_R1.fq.gz` / `_R2.fq.gz`).

### The truth set

To eventually check our answer, we need a trusted, independently-verified set of "real"
variants for this same sample. That's GIAB's **NISTv4.2.1 benchmark** — the
gold-standard consensus call set for HG002, built by combining many different sequencing
technologies and callers, used across the whole genomics field as the reference answer
key:

```bash
curl -s -o HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  "https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
```

Plus the "high-confidence regions" BED file that comes with it — GIAB is honest that not
every part of the genome is confidently callable (repetitive regions, etc.), so the BED
says "only trust/score variants inside these regions."

Both files cover all 22 autosomes; we subset to just chr20 with `bcftools view -r chr20`
and `awk '$1=="chr20"'`, since that's all our reads cover.

### Trust, but verify

Before using any of this, we ran a direct coverage check — the same discipline that
caught a real no-coverage bug earlier in the sibling PGx project (a variant call that
turned out to be "no data here" silently mislabeled as "reference genotype"):

```bash
samtools coverage HG002...chr20.bam
# chr20: meandepth=39.86x, coverage=98.97%, meanmapq=54
```

39.86x mean depth, near-complete breadth, decent mapping quality — real, usable data, not
an artifact. Only after seeing this did we move on.

---

## 2. Running the aligner + variant caller: nf-core/sarek (Phase B)

### What `samplesheet.csv` is

Sarek needs to know: whose reads are these, and where are the FASTQ files? That's the
entire job of `samplesheet.csv`:

```csv
patient,sample,lane,fastq_1,fastq_2
HG002,HG002_chr20,L001,/root/.../data/reads/HG002_chr20_R1.fq.gz,/root/.../data/reads/HG002_chr20_R2.fq.gz
```

- `patient` / `sample` — sarek's internal identifiers (useful for real multi-sample
  cohorts; here it's just one person, one sample)
- `lane` — sequencers produce reads in physical "lanes"; sarek can merge multiple lanes
  per sample, we only have one
- `fastq_1` / `fastq_2` — the two paired-end read files from Phase A

### What `nextflow.config` is

This is the file that tells Nextflow (the workflow engine sarek is written in) **where**
and **how** to actually run each step — completely separate from *what* steps to run
(that's the command line flags). Key lines:

```groovy
process.executor = 'awsbatch'      // run each step as an AWS Batch job, not on this laptop
process.queue = 'ChiragQueue'      // the specific Batch job queue to submit to
workDir = 's3://chirag.../work/germline-benchmark'   // where intermediate files live
docker.enabled = true              // each step runs inside its own Docker container
wave.enabled = true                // Seqera Wave: builds/serves those containers on demand
fusion.enabled = true              // Seqera Fusion: lets a container read/write S3 as if it were a local disk
```

Without Fusion, every AWS Batch container would need the `aws` CLI baked in just to
manually copy files to/from S3 before and after running — Fusion makes S3 paths just work
transparently instead.

### The actual command

```bash
nextflow run nf-core/sarek -r 3.9.0 -profile docker -c nextflow.config \
  --input samplesheet.csv \
  --tools haplotypecaller \
  --intervals data/chr20.bed \
  --wes \
  --outdir s3://chirag-pgx-variant-pipeline-619759453039/results/germline-benchmark
```

- `-r 3.9.0` — **pin** the exact sarek version, so a future upstream update can't
  silently change our results
- `--tools haplotypecaller` — which variant caller to run (GATK's HaplotypeCaller)
- `--intervals data/chr20.bed --wes` — restrict all the work to chromosome 20 only
  (`--wes` = "whole exome sequencing" mode, which is really just sarek's generic
  "targeted region" mode — we're borrowing it to mean "targeted to chr20" for cost reasons)
- `--outdir` — where the final results land in S3

Under the hood this runs, in order: `fastp` (trim/QC raw reads) → `bwa-mem` (align to the
reference genome) → GATK `MarkDuplicates` (flag PCR duplicate reads) → GATK
`BaseRecalibrator`/`ApplyBQSR` (correct systematic sequencer quality-score errors) →
`HaplotypeCaller` (actually call the variants) → `CNNScoreVariants` /
`FilterVariantTranches` (machine-learning-based filtering of likely-false calls) →
QC reports → MultiQC summary.

### What went wrong, and how we found it

The first real run failed. Not with a crash — the job just sat there. Checking it
directly against AWS (not just trusting Nextflow's own error message) is what explained
it:

```bash
aws batch describe-jobs --jobs <job-id> --query 'jobs[0].statusReason'
# "MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT - The job resource requirement
#  (vCPU/memory/GPU) is higher than that can be met by the CE(s) attached to the job queue."
```

The alignment step asked for 24 vCPUs, but the AWS Batch compute environment's instance
family tops out around 16 vCPUs per machine — so no instance could ever satisfy the
request, no matter how long we waited. `describe-jobs` also confirmed zero EC2 capacity
had actually launched, so nothing was silently costing money while stuck.

Fix — cap what sarek is allowed to ask for, in `nextflow.config`:

```groovy
process.resourceLimits = [ cpus: 15, memory: 58.GB, time: 24.h ]
```

We also had 11 duplicate stuck jobs from the same failed run cluttering the shared queue,
which we explicitly confirmed with the user before terminating (since it's a shared
queue with the other project).

### What `.nextflow.log` is

Every `nextflow run` writes a detailed log of exactly what it did — every process it
launched, every config file it merged, every parameter it resolved, and (critically) the
full stack trace of anything that failed. It's the first place to look when something
goes wrong and the on-screen summary isn't enough detail. We used it directly to find the
"MISCONFIGURATION" cause above, and later to find a Picard sequence-dictionary error (see
Phase D) that wasn't fully shown on-screen either.

### Stopping and resuming mid-project

This run took long enough that we deliberately stopped it overnight — not by walking
away, but by explicitly terminating the AWS Batch job and the underlying EC2 instance,
then verifying with `aws ec2 describe-instances` that nothing was left running (so nothing
kept billing). The next day, we resumed with:

```bash
nextflow run nf-core/sarek ... -resume
```

`-resume` tells Nextflow to look at everything it already finished (identified by a hash
of each step's exact inputs) and skip straight to what's left — it picked up right at
`GATK4_HAPLOTYPECALLER`, re-doing zero of the alignment work.

### The result

`HG002_chr20.haplotypecaller.filtered.vcf.gz` — 132,108 variants called (110,272 SNPs,
21,950 indels), landed in S3 at
`s3://chirag-pgx-variant-pipeline-619759453039/results/germline-benchmark/variant_calling/haplotypecaller/HG002_chr20/`.

---

## 3. Proving it's accurate: the hap.py benchmark (Phase C)

Calling 132,108 variants doesn't mean anything on its own — we need to know how many of
them are *real*. That's what Phase C does: compare our VCF against the GIAB truth VCF
from Phase A and count true positives, false positives, and false negatives.

### Two dead ends before this worked

The original plan named `pkrusche/hap.py` as the container to use. It doesn't work
anymore — `docker pull pkrusche/hap.py` fails outright, because that image was built with
an old Docker manifest format current Docker no longer supports. We switched to the
actively-maintained `quay.io/biocontainers/hap.py:0.3.15--py27hcb73b3d_0` instead.

That image, though, has **no Java runtime installed** — and the specific comparison
engine we wanted (`vcfeval`, from a separate tool called rtg-tools, which does
haplotype-aware comparison instead of naive line-by-line VCF diffing) is Java-based. So
`hap.py --engine=vcfeval` failed with "rtg: not found."

Fix: we pulled rtg-tools' own container image and used `docker cp` to physically copy its
rtg-tools installation *and its bundled Java runtime* out onto the host filesystem:

```bash
cid=$(docker create quay.io/biocontainers/rtg-tools:3.12.1--hdfd78af_1)
docker cp "$cid:/usr/local/share/rtg-tools-3.12.1-1" tools/rtg-tools-3.12.1-1
docker cp "$cid:/usr/local/lib/jvm" tools/jvm
```

Then we bind-mounted both into the hap.py container at runtime, plus a few missing shared
libraries (`libz.so.1`, `libstdc++.so.6`, `libgcc_s.so.1`) that the copied Java binary
needed but the minimal hap.py image didn't have. This whole extraction is scripted in
`scripts/extract_rtg_tools.sh` so it's a one-command repeat, not a one-off hack.

### Building the reference index

`vcfeval` needs the reference genome in its own indexed format (an "SDF"), built once:

```bash
rtg format -o data/ref/chr20.sdf data/ref/chr20.fa
```

### The actual comparison

```bash
hap.py \
  data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark.vcf.gz \
  results/haplotypecaller/HG002_chr20.haplotypecaller.filtered.vcf.gz \
  -f data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark_noinconsistent.bed \
  -r data/ref/chr20.fa \
  -o results/happy/HG002_chr20 \
  --engine=vcfeval \
  --engine-vcfeval-path .../rtg \
  --engine-vcfeval-template data/ref/chr20.sdf \
  -l chr20
```

First argument is truth, second is our call set, `-f` is the "only score inside these
regions" BED, `-r`/`--engine-vcfeval-template` point at the reference and its index.

We also wrapped this exact command as a proper Nextflow process
(`benchmark_happy.nf`) — not because it needed to run on AWS Batch (it doesn't; it's
fast and local, same reasoning as running PharmCAT locally in the sibling PGx project),
but so the same harness can be pointed at a different caller's VCF later (e.g. DeepVariant
in a future phase) without rewriting anything.

### The result

| Type | Recall | Precision | F1 |
|---|---|---|---|
| SNP | 99.397% | 99.285% | 99.341% |
| INDEL | 98.943% | 99.441% | 99.191% |

Read as: of every truly-real variant GIAB says exists in this region, we correctly found
99.4% of the SNPs and 98.9% of the indels (recall); of everything we *called*, 99.3-99.4%
was actually real (precision). This is a strong, expected result for a single-sample
GATK HaplotypeCaller run.

---

## 4. Coverage economics: the panel metrics (Phase D)

A real question labs care about: if you only sequence a small gene panel instead of the
whole genome, how efficiently does the sequencing "land" where you wanted it? We
simulated this using a real gene.

### Picking a real gene, not a made-up coordinate range

We used **PRNP** (the prion disease gene) as a stand-in "panel," looked up precisely
(not guessed) via Ensembl's API:

```bash
curl -s "https://rest.ensembl.org/lookup/symbol/homo_sapiens/PRNP?content-type=application/json"
# -> chr20:4,685,730-4,701,590, GRCh38
```

Padded 1000bp each side and saved as `data/panel_prnp.bed`.

### A tool switch, mid-stream

The original plan was Picard's `CollectHsMetrics`, the standard tool for this. It failed
with a sequence-dictionary mismatch — our recalibrated CRAM's header (from sarek, aligned
against the *full* genome) lists 3,366 contigs; our local reference file only had chr20
(1 contig), and Picard strictly requires those to match exactly. Chasing that down would
have meant keeping a 3.25GB whole-genome reference on disk just to satisfy a metadata
check.

Instead we computed the same numbers directly with tools that don't care about the full
dictionary:

```bash
samtools view -c -L data/panel_prnp.bed HG002_chr20.recal.cram   # reads landing in the panel
samtools view -c HG002_chr20.recal.cram                          # total reads
mosdepth --by data/panel_prnp.bed -f data/ref/chr20.fa ...        # coverage inside the panel
```

### The result

| Metric | Value |
|---|---|
| On-target reads | 5,203 / 18,577,986 (0.028%) |
| Panel's share of chr20 (geometric) | 0.0277% |
| Panel mean coverage | 36.43x |
| chr20-wide mean coverage | 36.28x |

The on-target rate lands almost exactly on the panel's raw size-fraction of chr20, and
panel coverage almost exactly matches chr20-wide coverage. That's the **correct** result
here, not a red flag — this is whole-genome data computationally cut down to chr20, not a
real hybrid-capture experiment, so there was never any enrichment step to measure. The
honest conclusion is "uniform coverage, no capture bias," which is exactly what these
numbers show.

---

## 5. Annotation: what do the variants actually mean? (Phase E)

A VCF full of positions and genotypes doesn't say anything about biology on its own —
annotation adds "this variant is in gene X, it changes amino acid Y, here's how common it
is in the population, here's whether it's predicted to be damaging."

### Choosing tools

The original plan considered three annotators: VEP, snpEff, and ANNOVAR. We decided
**not** to use ANNOVAR — it requires each user to personally register for a license and
manually download its databases (nothing automatable there), and its main advantage is
being the historically-preferred tool in clinical diagnostic labs, not unique technical
capability. VEP already gives population frequencies and damage predictions, so we ran
VEP + snpEff only.

### What `samplesheet_annotate.csv` is, and why it's different from `samplesheet.csv`

```csv
patient,sample,variantcaller,vcf
HG002,HG002_chr20,haplotypecaller,s3://chirag.../HG002_chr20.haplotypecaller.filtered.vcf.gz
```

Sarek's samplesheet format changes depending on what stage you're starting from. The
first samplesheet (Phase B) pointed at raw FASTQ, because we were starting from scratch.
This one points directly at the already-called VCF from Phase B, because annotation
doesn't need to touch the raw reads at all — it just adds information to variants that
already exist.

### A validation error, and a better fix than the obvious one

The first attempt reused the *original* FASTQ-based samplesheet with `-resume`, hoping
Nextflow would skip straight to annotation. It failed immediately:

```
Error for field 'fastq_1': the file ... does not exist
```

`-resume` only skips *already-completed tasks* — it doesn't skip Nextflow's upfront check
that every file named in the samplesheet physically exists, and we'd deleted the local
FASTQ files earlier (see disk hygiene, below). Rather than re-downloading them just to
satisfy a check we didn't actually need, we used sarek's dedicated **`--step annotate`**
mode instead, with the VCF-based samplesheet above:

```bash
nextflow run nf-core/sarek -r 3.9.0 -profile docker -c nextflow.config \
  --input samplesheet_annotate.csv \
  --step annotate \
  --tools vep,snpeff \
  --wes \
  --outdir s3://chirag-pgx-variant-pipeline-619759453039/results/germline-benchmark
```

This is structurally better than `-resume` would have been even if it had worked — it
skips alignment/calling entirely by design, rather than depending on Nextflow's cache
happening to still be valid.

VEP and snpEff both needed their reference database ("cache") — sarek already defaults
these to public, pre-built S3 locations (`s3://annotation-cache/vep_cache/` and
`.../snpeff_cache/`), so nothing had to be downloaded or built ourselves.

### The result

Two annotated VCFs, each adding a structured info field per variant:

- **VEP**: `CSQ=` field — consequence type, gene/transcript, SIFT/PolyPhen damage
  predictions, gnomAD population allele frequencies
- **snpEff**: `ANN=` field — functional impact category, HGVS notation (the standard
  "c.123A>G" / "p.Lys41Arg" style variant description)

---

## 6. A detour: real SQL over the results (not a numbered phase)

After the core phases, we set up **AWS Athena** — serverless SQL directly over the CSV
result tables sitting in S3, no server, no standing cost, pay only per query (and these
queries are small enough to cost fractions of a cent each). Uploaded the hap.py and panel
summary CSVs to S3, defined two tables via `CREATE EXTERNAL TABLE` DDL, then ran real
`SELECT`/`WHERE`/aggregate SQL against them — e.g. computing a pooled SNP+INDEL
recall/precision number that didn't exist in either source CSV, purely via SQL
aggregation. Query helper saved at `scripts/athena_query.sh`. (DynamoDB was considered
and explicitly ruled out for this — it's NoSQL/key-value, not a real SQL skillset, and
this project doesn't need a queryable service, just the tables it already produces.)

The first pass only had summary-level tables — one row per variant type, nothing to
stratify by. Extended it with two tables that do have real structure: `happy_extended`
(hap.py's own indel-size/complexity breakdown — `D1_5`/`I1_5` for 1-5bp indels up through
`D16_PLUS`/`I16_PLUS` for 16bp+) and `roc_curve` (one row per QUAL score hap.py's ROC curve
observed, 7,043 rows, so a query can ask "at what QUAL threshold does recall cross 99%"
instead of only reading the one fixed PASS/ALL operating point). The "F1 by indel size"
query surfaces something real: accuracy drops monotonically as indels get longer — 99.37%
F1 for short deletions down to 95.49% for 16bp+ insertions — the textbook variant-calling
failure mode, read directly off real per-stratum counts.

One thing deliberately *not* done: physical Athena/Glue partitioning. Partitioning exists
to let a query skip scanning irrelevant S3 data at real scale; at a few hundred KB total
there's nothing to skip. Stratifying via `WHERE`/`GROUP BY` on a real column is the honest
version of this at our data size — partitioning would just be performing the pattern
without it doing anything.

The bigger gap the extension closed: "reproduce the SQL layer" previously meant "have my
AWS account," which nobody reviewing this repo has. Added a **DuckDB** path
(`scripts/duckdb_queries.sql`) that runs the identical SQL directly against the committed
`results/sql/*.csv` files — `duckdb < scripts/duckdb_queries.sql`, no AWS credentials, no
server, single static binary. Verified byte-identical output against the Athena version
before committing either.

---

## 7. Disk hygiene: a real mistake, corrected

Partway through, local disk usage crept up unnecessarily — a Docker image guessed by name
without checking it actually existed, a `docker pull | tail` that silently swallowed a
real failure, and a 3.25GB reference re-download for a Picard check that turned out to be
avoidable. Once flagged, everything unneeded was deleted: the raw source BAM/FASTQ (Phase
A — safely re-derivable from their documented source URLs any time), the whole-genome
truth VCF (only the chr20 subset is actually used), and ~10GB of Docker images that were
either dead ends or superseded. Standing practice now: verify a Docker image actually
pulls before building around it, and delete large downloaded artifacts the moment their
output is safely stored elsewhere (S3 or `results/`) rather than "just in case."

---

## 8. Where everything actually lives right now

**In S3** (`s3://chirag-pgx-variant-pipeline-619759453039/`):
- `results/germline-benchmark/variant_calling/haplotypecaller/HG002_chr20/` — the called
  VCF (Phase B)
- `results/germline-benchmark/annotation/haplotypecaller/HG002_chr20/` — VEP + snpEff
  annotated VCFs (Phase E)
- `results/germline-benchmark/benchmark_tables/` — the CSVs Athena queries: `happy_summary`,
  `panel_metrics` (Phase C/D), plus `happy_extended` and `roc_curve` (the stratified/ROC
  extension)
- `work/germline-benchmark/` — Nextflow's intermediate work directory (14-day
  auto-expiry lifecycle rule, already in place)

**Locally** (`data/`, `results/`, small — the multi-GB raw inputs were cleaned up):
- `data/ref/chr20.fa` + `.sdf` — the chr20 reference and its rtg-tools index
- `data/truth/` — the chr20-subset GIAB truth VCF/BED
- `data/panel_prnp.bed`, `data/chr20.bed` — the interval definitions
- `results/happy/`, `results/panel_metrics/` — the local benchmark output tables
- `results/sql/` — curated CSVs for the stratified/ROC queries, queryable via Athena or
  DuckDB (`scripts/duckdb_queries.sql`) with no AWS account
- `tools/` — the extracted rtg-tools + JVM (gitignored, regenerate any time via
  `scripts/extract_rtg_tools.sh`)

**Fully documented, phase by phase, with exact numbers and cost**: `ROADMAP.md`.
