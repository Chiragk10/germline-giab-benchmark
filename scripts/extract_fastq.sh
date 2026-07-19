#!/usr/bin/env bash
# Mate-aware BAM -> FASTQ extraction for the HG002 chr20 benchmark BAM.
# collate (not sort-by-name) avoids the orphaned-mate MarkDuplicates failure
# noted in ROADMAP.md pitfall #2.
set -euo pipefail

cd "$(dirname "$0")/.."

IN_BAM="data/reads/HG002.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam"
OUT_R1="data/reads/HG002_chr20_R1.fq.gz"
OUT_R2="data/reads/HG002_chr20_R2.fq.gz"

docker run --rm -v "$(pwd)/data/reads:/data" staphb/samtools bash -c "
  samtools collate -O -u /data/$(basename "$IN_BAM") /tmp/collate_tmp \
    | samtools fastq -1 /data/$(basename "$OUT_R1") -2 /data/$(basename "$OUT_R2") \
                     -0 /dev/null -s /dev/null -n -
"

echo '--- read counts ---'
zcat "$OUT_R1" | echo "R1 reads: $(($(wc -l) / 4))"
zcat "$OUT_R2" | echo "R2 reads: $(($(wc -l) / 4))"
