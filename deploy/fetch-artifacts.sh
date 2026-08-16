#!/usr/bin/env bash
#
# fetch-artifacts.sh — ensure the api's gitignored model weights are on disk.
#
# These two files are NOT in git and must be provided out-of-band:
#   * whisper_model/model.safetensors   (~151 MB, whisper-tiny encoder)
#   * whisper_multihead_model.pt        (~32 MB, multi-head classifier)
#
# Strategy (simplest first — pick one via ARTIFACTS_BASE_URL or pre-staging):
#   1. PRE-STAGE (default, simplest for the local VM PoC):
#        Copy the files onto the box yourself before running bootstrap, e.g. from your Mac:
#          multipass transfer whisper_model/model.safetensors musilinda:/srv/musilinda/api/whisper_model/
#          multipass transfer whisper_multihead_model.pt      musilinda:/srv/musilinda/api/
#        This script then just verifies they exist.
#   2. URL FETCH: set ARTIFACTS_BASE_URL (e.g. a private S3/HTTPS prefix). Files are
#        downloaded from "$ARTIFACTS_BASE_URL/<relative-path>".
#
# Usage: fetch-artifacts.sh <api_dir>
#
set -euo pipefail

API_DIR="${1:?usage: fetch-artifacts.sh <api_dir>}"
ARTIFACTS_BASE_URL="${ARTIFACTS_BASE_URL:-}"

ARTIFACTS=(
  "whisper_multihead_model.pt"
  "whisper_model/model.safetensors"
)

for rel in "${ARTIFACTS[@]}"; do
  dest="${API_DIR}/${rel}"
  if [[ -s "${dest}" ]]; then
    echo "artifact present: ${rel}"
    continue
  fi
  if [[ -n "${ARTIFACTS_BASE_URL}" ]]; then
    echo "fetching ${rel} from ${ARTIFACTS_BASE_URL}"
    mkdir -p "$(dirname "${dest}")"
    curl -fSL "${ARTIFACTS_BASE_URL%/}/${rel}" -o "${dest}"
  else
    echo "MISSING artifact: ${dest}" >&2
    echo "  Pre-stage it (see header) or set ARTIFACTS_BASE_URL, then re-run." >&2
    exit 1
  fi
done

echo "all model artifacts present."
