#!/usr/bin/env bash
# Submit a query to Athena, wait for it, print the result table.
# Usage: ./athena_query.sh "SELECT * FROM germline_benchmark.happy_summary"
set -euo pipefail

QUERY="$1"
OUTPUT_LOCATION="s3://chirag-pgx-variant-pipeline-619759453039/athena-results/"
REGION="us-east-1"

QID=$(aws athena start-query-execution \
  --query-string "$QUERY" \
  --result-configuration OutputLocation="$OUTPUT_LOCATION" \
  --region "$REGION" \
  --query 'QueryExecutionId' --output text)

while true; do
  STATE=$(aws athena get-query-execution --query-execution-id "$QID" --region "$REGION" \
    --query 'QueryExecution.Status.State' --output text)
  case "$STATE" in
    SUCCEEDED) break ;;
    FAILED|CANCELLED)
      aws athena get-query-execution --query-execution-id "$QID" --region "$REGION" \
        --query 'QueryExecution.Status.StateChangeReason' --output text
      exit 1
      ;;
  esac
  sleep 1
done

aws athena get-query-results --query-execution-id "$QID" --region "$REGION" \
  --query 'ResultSet.Rows[].Data[].VarCharValue' --output text
