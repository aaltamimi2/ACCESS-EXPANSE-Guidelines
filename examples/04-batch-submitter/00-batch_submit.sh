#!/bin/bash
# =============================================================================
# BATCH SUBMIT SCRIPT - Submit multiple surfactants as separate SLURM jobs
# =============================================================================
# Usage:
#   ./00-batch_submit.sh --indices 522,488,362          # Comma-separated list
#   ./00-batch_submit.sh --indices-file indices.txt     # One index per line
#   ./00-batch_submit.sh --all-selected                 # All 24 selected surfactants
#   ./00-batch_submit.sh --indices 522,488 --skip-swarmcg --skip-build
#
# Options:
#   --indices <list>       Comma-separated surfactant indices
#   --indices-file <file>  File with one index per line
#   --all-selected         Submit all 24 selected surfactants
#   --skip-swarmcg         Pass --skip-swarmcg to each job
#   --skip-build           Pass --skip-build to each job
#   --skip-equil           Pass --skip-equil to each job
#   --skip-metad           Pass --skip-metad to each job
#   --dry-run              Show what would be submitted without submitting
#   --delay <seconds>      Delay between submissions (default: 2)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config/pipeline_config.sh"

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

INDICES=""
INDICES_FILE=""
ALL_SELECTED=false
DRY_RUN=false
DELAY=2
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --indices)
            INDICES="$2"
            shift 2
            ;;
        --indices-file)
            INDICES_FILE="$2"
            shift 2
            ;;
        --all-selected)
            ALL_SELECTED=true
            shift
            ;;
        --skip-swarmcg)
            EXTRA_ARGS="${EXTRA_ARGS} --skip-swarmcg"
            shift
            ;;
        --skip-build)
            EXTRA_ARGS="${EXTRA_ARGS} --skip-build"
            shift
            ;;
        --skip-equil)
            EXTRA_ARGS="${EXTRA_ARGS} --skip-equil"
            shift
            ;;
        --skip-metad)
            EXTRA_ARGS="${EXTRA_ARGS} --skip-metad"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Usage: $0 --indices <list> | --indices-file <file> | --all-selected [options]"
            exit 1
            ;;
    esac
done

# =============================================================================
# BUILD INDEX LIST
# =============================================================================

INDEX_LIST=()

if [[ "${ALL_SELECTED}" == "true" ]]; then
    # Selected surfactants (excluding 194, 504 - no CG parameters)
    INDEX_LIST=(496 369 276 408 415 362 459 544 488 359 522 174 177 198 205 202 77 60 136 149 31 22)
    log_info "Using all 22 selected surfactants"
elif [[ -n "${INDICES}" ]]; then
    # Parse comma-separated list
    IFS=',' read -ra INDEX_LIST <<< "${INDICES}"
    log_info "Using indices from command line: ${INDICES}"
elif [[ -n "${INDICES_FILE}" ]]; then
    # Read from file (one per line, skip comments and empty lines)
    if [[ ! -f "${INDICES_FILE}" ]]; then
        log_error "Indices file not found: ${INDICES_FILE}"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
        if [[ -n "$line" ]]; then
            INDEX_LIST+=("$line")
        fi
    done < "${INDICES_FILE}"
    log_info "Using indices from file: ${INDICES_FILE}"
else
    log_error "Must specify --indices, --indices-file, or --all-selected"
    echo "Usage: $0 --indices <list> | --indices-file <file> | --all-selected [options]"
    exit 1
fi

if [[ ${#INDEX_LIST[@]} -eq 0 ]]; then
    log_error "No surfactant indices specified"
    exit 1
fi

# =============================================================================
# CLEAR STALE LOCKS
# =============================================================================

log_info "Clearing stale locks..."
for idx in "${INDEX_LIST[@]}"; do
    LOCK_FILE="${LOCK_DIR}/SURF${idx}.lock"
    if [[ -f "${LOCK_FILE}" ]]; then
        rm -f "${LOCK_FILE}"
        log_info "  Removed lock for SURF${idx}"
    fi
done

# =============================================================================
# SUBMIT JOBS
# =============================================================================

log_info "=============================================="
log_info "BATCH SUBMIT: ${#INDEX_LIST[@]} surfactants"
log_info "=============================================="
log_info "Extra args: ${EXTRA_ARGS:-none}"
log_info "Delay between submissions: ${DELAY}s"
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY RUN - no jobs will be submitted"
fi
log_info "=============================================="

SUBMITTED=0
SKIPPED=0
JOB_IDS=()

for idx in "${INDEX_LIST[@]}"; do
    SURF_NAME="SURF${idx}"

    # Check if already completed
    if [[ -f "${RESULTS_DIR}/${SURF_NAME}/COMPLETED" ]] || \
       [[ -f "${SCRATCH_WORK}/${SURF_NAME}/results/METAD_COMPLETED" ]]; then
        log_warning "Skipping ${SURF_NAME} - already completed"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check if locked (job running)
    if [[ -f "${LOCK_DIR}/${SURF_NAME}.lock" ]]; then
        LOCK_JOB=$(cut -d: -f1 "${LOCK_DIR}/${SURF_NAME}.lock" 2>/dev/null || echo "unknown")
        log_warning "Skipping ${SURF_NAME} - locked by job ${LOCK_JOB}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Build sbatch command
    SBATCH_CMD="sbatch --job-name=surf-${idx} ${SCRIPT_DIR}/00-pipeline_master.sh --index ${idx} ${EXTRA_ARGS}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would submit: ${SBATCH_CMD}"
    else
        log_info "Submitting ${SURF_NAME}..."
        JOB_OUTPUT=$(${SBATCH_CMD} 2>&1) || {
            log_error "Failed to submit ${SURF_NAME}: ${JOB_OUTPUT}"
            continue
        }

        # Extract job ID
        JOB_ID=$(echo "${JOB_OUTPUT}" | grep -oE '[0-9]+' | tail -1)
        JOB_IDS+=("${JOB_ID}:${idx}")
        log_info "  Submitted ${SURF_NAME} as job ${JOB_ID}"

        SUBMITTED=$((SUBMITTED + 1))

        # Delay between submissions to avoid overwhelming scheduler
        if [[ ${DELAY} -gt 0 ]] && [[ ${SUBMITTED} -lt ${#INDEX_LIST[@]} ]]; then
            sleep ${DELAY}
        fi
    fi
done

# =============================================================================
# SUMMARY
# =============================================================================

log_info ""
log_info "=============================================="
log_info "BATCH SUBMIT COMPLETE"
log_info "=============================================="
log_info "Total requested: ${#INDEX_LIST[@]}"
log_info "Submitted: ${SUBMITTED}"
log_info "Skipped: ${SKIPPED}"

if [[ ${#JOB_IDS[@]} -gt 0 ]]; then
    log_info ""
    log_info "Submitted jobs:"
    for job_info in "${JOB_IDS[@]}"; do
        JOB_ID=$(echo "${job_info}" | cut -d: -f1)
        SURF_IDX=$(echo "${job_info}" | cut -d: -f2)
        echo "  Job ${JOB_ID}: SURF${SURF_IDX}"
    done

    log_info ""
    log_info "Monitor with: squeue -u ${USER}"
    log_info "Cancel all with: scancel ${JOB_IDS[*]%%:*}"
fi

log_info "=============================================="
