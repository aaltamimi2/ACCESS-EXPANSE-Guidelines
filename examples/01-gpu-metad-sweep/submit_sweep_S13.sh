#!/bin/bash
#SBATCH --job-name=SWP-S13-SDS
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --gpus=1
#SBATCH --time=48:00:00
#SBATCH --output=slurm-SWP-S13-SDS-%j.out
#SBATCH --error=slurm-SWP-S13-SDS-%j.err
#SBATCH --account=wis192
#SBATCH --export=ALL

set -euo pipefail

echo "========================================================================"
echo "2D WT-MetaD SWEEP S13 - SDS - 6CV |dZ| lag2000 Full model"
echo "HEIGHT=1.0 (0.34 kBT), BF=500, SIGMA=0.024,0.020, PACE=500"
echo "Strategy: tiny constant Gaussians with high BF (minimal decay)"
echo "========================================================================"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Start time: $(date)"
echo "Host: $(hostname)"

module purge
module load singularitypro

SIF="/expanse/lustre/scratch/aaltamimi/temp_project/deeptica-plumed_v1.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

MODEL_PATH="/home/aaltamimi/30CMC-CAMPAIGN/01-TRAINING/DeepTICA-6CV/DeepTICA-6CV-absdZ/Full/lag2000/FULL/model.ptc"

SYSTEM_DIR="/home/aaltamimi/30CMC-CAMPAIGN/01-TRAINING/SYSTEM/SDS-30CMC-REP1"
TPR_FILE="${SYSTEM_DIR}/metad.tpr"
NDX_FILE="${SYSTEM_DIR}/metad.ndx"

WORKDIR="/expanse/lustre/scratch/aaltamimi/temp_project/METAD-SWP-S13-SDS-6cv-lag2000-${SLURM_JOB_ID}"

export OMPI_MCA_orte_tmpdir_base="/tmp"
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "Working directory: ${WORKDIR}"

echo ""
echo "[1/3] Freezing model..."
${CONTAINER} python3 << PYEOF
import torch
m = torch.jit.load("${MODEL_PATH}")
frozen = torch.jit.freeze(m)
frozen.save("${WORKDIR}/model.ptc")
print("Frozen model saved")
PYEOF

echo "[2/3] Staging files..."
PLUMED_FILE="/home/aaltamimi/30CMC-CAMPAIGN/02-PRODUCTION/SDS/plumed_sweep_S13.dat"
cp "${PLUMED_FILE}" plumed_metad.dat
cp "${TPR_FILE}" metad.tpr
cp "${NDX_FILE}" metad.ndx

echo "[3/3] Running 2D WT-MetaD S13 (SDS, 30000000 steps = 600 ns)..."

${CONTAINER} gmx_mpi mdrun \
    -v \
    -deffnm metad \
    -plumed plumed_metad.dat \
    -nsteps 30000000 \
    -nb gpu \
    -bonded cpu \
    -ntomp ${SLURM_CPUS_PER_TASK} \
    -pin on

echo ""
echo "========================================================================"
echo "WT-MetaD S13 SDS Complete"
echo "========================================================================"
echo "End time: $(date)"
ls -lh metad.* COLVAR_METAD HILLS_DEEPTICA 2>/dev/null
