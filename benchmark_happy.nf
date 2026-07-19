#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
 * benchmark_happy.nf — caller-agnostic hap.py/vcfeval benchmark harness (Phase C)
 * ---------------------------------------------------------------------------
 * Scores a query VCF against a GIAB truth VCF+BED, stratified SNP/INDEL
 * precision/recall/F1. Reused unchanged for DeepVariant in Phase G — swap
 * params.query_vcf and rerun.
 *
 * The quay.io/biocontainers/hap.py image has no bundled JVM (needed for the
 * vcfeval engine) and rtg-tools' own image lacks libz/libstdc++ once run
 * standalone against an arbitrary mount point. tools/ (extracted once via
 * scripts/extract_rtg_tools.sh) bundles rtg-tools + its JVM + the shared libs
 * both need, mounted into the hap.py container at runtime. See ROADMAP.md
 * Phase C result for how this was diagnosed.
 *
 * Run locally (no AWS Batch — a single fast comparison doesn't justify cloud
 * infra, same reasoning as running PharmCAT locally in the PGx project):
 *   nextflow run benchmark_happy.nf
 */

params.query_vcf   = 'results/haplotypecaller/HG002_chr20.haplotypecaller.filtered.vcf.gz'
params.query_tbi   = "${params.query_vcf}.tbi"
params.truth_vcf   = 'data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark.vcf.gz'
params.truth_tbi   = "${params.truth_vcf}.tbi"
params.truth_bed   = 'data/truth/HG002_GRCh38_chr20_v4.2.1_benchmark_noinconsistent.bed'
params.ref_fasta   = 'data/ref/chr20.fa'
params.ref_fai     = "${params.ref_fasta}.fai"
params.ref_sdf     = 'data/ref/chr20.sdf'
params.region      = 'chr20'
params.sample      = 'HG002_chr20'
params.outdir      = 'results/happy'
params.tools_dir   = 'tools'

process HAPPY_BENCHMARK {
    tag params.sample
    container 'quay.io/biocontainers/hap.py:0.3.15--py27hcb73b3d_0'
    containerOptions "-v ${file(params.tools_dir).toAbsolutePath()}/rtg-tools-3.12.1-1:/usr/local/share/rtg-tools-3.12.1-1 -v ${file(params.tools_dir).toAbsolutePath()}/jvm:/tools/jvm -v ${file(params.tools_dir).toAbsolutePath()}/lib:/tools/lib"
    publishDir params.outdir, mode: 'copy'

    input:
    tuple path(query_vcf), path(query_tbi)
    tuple path(truth_vcf), path(truth_tbi)
    path truth_bed
    tuple path(ref_fasta), path(ref_fai)
    path ref_sdf

    output:
    path "${params.sample}.summary.csv", emit: summary
    path "${params.sample}.extended.csv"
    path "${params.sample}*"

    script:
    """
    . /usr/local/env-activate.sh
    export JAVA_HOME=/tools/jvm
    export PATH="/tools/jvm/bin:/usr/local/share/rtg-tools-3.12.1-1:\$PATH"
    export LD_LIBRARY_PATH="/tools/lib:\${LD_LIBRARY_PATH:-}"

    hap.py \\
        ${truth_vcf} \\
        ${query_vcf} \\
        -f ${truth_bed} \\
        -r ${ref_fasta} \\
        -o ${params.sample} \\
        --engine=vcfeval \\
        --engine-vcfeval-path /usr/local/share/rtg-tools-3.12.1-1/rtg \\
        --engine-vcfeval-template ${ref_sdf} \\
        -l ${params.region}
    """
}

workflow {
    query_ch = Channel.of([file(params.query_vcf), file(params.query_tbi)])
    truth_ch = Channel.of([file(params.truth_vcf), file(params.truth_tbi)])
    bed_ch   = Channel.fromPath(params.truth_bed)
    ref_ch   = Channel.of([file(params.ref_fasta), file(params.ref_fai)])
    sdf_ch   = Channel.fromPath(params.ref_sdf)

    HAPPY_BENCHMARK(query_ch, truth_ch, bed_ch, ref_ch, sdf_ch)
}
