#!/bin/bash
# =============================================================================
# TEMPLATE — GPU Python / ML training job (containerized)
# Derived from submit_full_model_30cmc.sh. Same skeleton as example 01, but the
# workload is a Python training script instead of GROMACS mdrun.
# =============================================================================

#SBATCH --job-name=CHANGE_ME            # e.g. deeptica-full-30cmc
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=64G                       # training often wants more RAM than MD
#SBATCH --gpus=1
#SBATCH --time=48:00:00
#SBATCH --output=slurm-CHANGE_ME-%j.out
#SBATCH --error=slurm-CHANGE_ME-%j.err
#SBATCH --account=wis192
#SBATCH --export=ALL

set -euo pipefail

echo "Job ID: ${SLURM_JOB_ID}"; echo "Start: $(date)"; echo "Host: $(hostname)"

module purge
module load singularitypro

SIF="/expanse/lustre/scratch/${USER}/temp_project/<image>.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

# --- data (in scratch) and a per-job output dir ------------------------------
DATA_DIR="/expanse/lustre/scratch/${USER}/temp_project/<dataset>"
OUTPUT_DIR="/expanse/lustre/scratch/${USER}/temp_project/<run>-${SLURM_JOB_ID}"
mkdir -p "${OUTPUT_DIR}"

# --- copy the training script next to its outputs (provenance) ---------------
cp /home/${USER}/<path>/train_script.py "${OUTPUT_DIR}/"
cd "${OUTPUT_DIR}"

# --- run ---------------------------------------------------------------------
${CONTAINER} python3 train_script.py \
    --data-dir "${DATA_DIR}" \
    --output-dir <out_subdir> \
    --mode <mode>

echo "Results in: ${OUTPUT_DIR}"
echo "End: $(date)"
# Copy final models/metrics back to /home — scratch is purged.
