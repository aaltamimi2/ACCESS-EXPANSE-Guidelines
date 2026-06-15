#!/bin/bash
#SBATCH --job-name=deeptica-full-30cmc
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=64G
#SBATCH --gpus=1
#SBATCH --time=48:00:00
#SBATCH --output=slurm-full-30cmc-%j.out
#SBATCH --error=slurm-full-30cmc-%j.err
#SBATCH --account=wis192
#SBATCH --export=ALL

#===============================================================================
# DeepTICA Full Model - 6 CV Version (30CMC Campaign)
#
# Train on ALL 8 surfactants at each lag time (no held-out).
# 8 lag times × 1 model = 8 training runs.
# Complement to the LOOCV job — this is the production model.
#===============================================================================

set -euo pipefail

echo "========================================================================"
echo "DeepTICA Full Model Sweep - 6 CV, 30CMC Campaign (8 surfactants)"
echo "========================================================================"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Start time: $(date)"
echo "Host: $(hostname)"

module purge
module load singularitypro

SIF="/expanse/lustre/scratch/aaltamimi/temp_project/deeptica-plumed_v1.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

# Data directory with cleaned COLVARs
DATA_DIR="/expanse/lustre/scratch/aaltamimi/temp_project/30CMC-CAMPAIGN/01-TRAINING"

# Output directory — separate from LOOCV job
OUTPUT_DIR="/expanse/lustre/scratch/aaltamimi/temp_project/30CMC-CAMPAIGN/deeptica-full-6cv-${SLURM_JOB_ID}"
mkdir -p ${OUTPUT_DIR}

# Copy training script
cp /home/aaltamimi/30CMC-CAMPAIGN/train_deeptica_6cv_30cmc.py ${OUTPUT_DIR}/

cd ${OUTPUT_DIR}

echo ""
echo "Data directory: ${DATA_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Mode: FULL (all 8 systems)"
echo "Lag times: 10, 50, 100, 200, 500, 1000, 2000, 5000 ps"
echo "Total runs: 8"
echo ""

# Run the full model sweep
${CONTAINER} python3 train_deeptica_6cv_30cmc.py \
    --data-dir ${DATA_DIR} \
    --output-dir deeptica_6cv_30cmc_full \
    --mode full

echo ""
echo "========================================================================"
echo "Full Model Sweep complete"
echo "========================================================================"
echo "Results in: ${OUTPUT_DIR}/deeptica_6cv_30cmc_full"
echo "End time: $(date)"
