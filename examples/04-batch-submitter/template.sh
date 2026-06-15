#!/bin/bash
# =============================================================================
# TEMPLATE — Batch submitter (NOT a SLURM job; you run this on the login node)
# It loops over a list of items and calls `sbatch` once per item, with guards to
# skip finished/running work. Derived from 00-batch_submit.sh.
# Run directly:  ./submit_all.sh --items 1,2,3   (no sbatch in front)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source "${SCRIPT_DIR}/config/pipeline_config.sh"   # shared paths/SLURM settings

# --- args --------------------------------------------------------------------
ITEMS=""
DRY_RUN=false
DELAY=2                       # seconds between submissions (don't flood scheduler)
while [[ $# -gt 0 ]]; do
  case $1 in
    --items)   ITEMS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --delay)   DELAY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

IFS=',' read -ra ITEM_LIST <<< "${ITEMS}"
[[ ${#ITEM_LIST[@]} -eq 0 ]] && { echo "Need --items a,b,c"; exit 1; }

# --- submit loop -------------------------------------------------------------
SUBMITTED=0
for item in "${ITEM_LIST[@]}"; do
  # skip if already finished (adjust to your own completion marker)
  if [[ -f "results/${item}/COMPLETED" ]]; then
    echo "skip ${item}: already done"; continue
  fi

  CMD="sbatch --job-name=job-${item} ${SCRIPT_DIR}/per_item_job.sh --index ${item}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] ${CMD}"
  else
    JOB_OUT=$(${CMD}) || { echo "FAILED ${item}: ${JOB_OUT}"; continue; }
    JOB_ID=$(echo "${JOB_OUT}" | grep -oE '[0-9]+' | tail -1)
    echo "submitted ${item} -> job ${JOB_ID}"
    SUBMITTED=$((SUBMITTED+1))
    sleep "${DELAY}"
  fi
done

echo "Done. Submitted ${SUBMITTED} job(s). Monitor: squeue -u ${USER}"
