#!/usr/bin/env bash
# Extracts rtg-tools + its bundled JVM + the shared libs both need out of the
# quay.io/biocontainers/rtg-tools image, for bind-mounting into the hap.py
# container (which has no JVM of its own) at runtime. See ROADMAP.md Phase C
# result for why this is needed instead of just `docker pull pkrusche/hap.py`.
set -euo pipefail

cd "$(dirname "$0")/.."

RTG_IMAGE="quay.io/biocontainers/rtg-tools:3.12.1--hdfd78af_1"
mkdir -p tools/lib

cid=$(docker create "$RTG_IMAGE")
trap 'docker rm "$cid" > /dev/null' EXIT

docker cp "$cid:/usr/local/share/rtg-tools-3.12.1-1" tools/rtg-tools-3.12.1-1
docker cp "$cid:/usr/local/lib/jvm" tools/jvm
docker cp "$cid:/usr/local/lib/libz.so.1" tools/lib/
docker cp "$cid:/usr/local/lib/libz.so.1.3.1" tools/lib/
docker cp "$cid:/usr/local/lib/libstdc++.so.6.0.33" tools/lib/
docker cp "$cid:/usr/local/lib/libgcc_s.so.1" tools/lib/
ln -sf libstdc++.so.6.0.33 tools/lib/libstdc++.so.6

echo "tools/ ready:"
du -sh tools/
