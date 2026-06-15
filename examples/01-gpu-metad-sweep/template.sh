#!/bin/bash
# =============================================================================
# TEMPLATE — GPU MD / metadynamics production job (GROMACS + PLUMED in Singularity)
# Derived from submit_sweep_S13.sh. Fill in CHANGE_ME / <...>, then submit.
# Pattern: freeze model (optional) -> stage inputs to scratch -> mdrun -> results.
# =============================================================================

#SBATCH --job-name=CHANGE_ME            # e.g. SWP-S13-SDS
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --gpus=1
#SBATCH --time=48:00:00
#SBATCH --output=slurm-CHANGE_ME-%j.out
#SBATCH --error=slurm-CHANGE_ME-%j.err
#SBATCH --account=wis192
#SBATCH --export=ALL

set -euo pipefail

echo "Job ID: ${SLURM_JOB_ID}"; echo "Start: $(date)"; echo "Host: $(hostname)"

# --- environment -------------------------------------------------------------
module purge
module load singularitypro

SIF="/expanse/lustre/scratch/${USER}/temp_project/<image>.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

# --- inputs (read from /home) ------------------------------------------------
SYSTEM_DIR="/home/${USER}/<path>/SYSTEM/<system>"
TPR_FILE="${SYSTEM_DIR}/metad.tpr"
NDX_FILE="${SYSTEM_DIR}/metad.ndx"
PLUMED_FILE="/home/${USER}/<path>/plumed.dat"
# MODEL_PATH="/home/${USER}/<path>/model.ptc"   # only if using a DeepTICA CV

# --- per-job working dir in scratch (keyed on job id) ------------------------
WORKDIR="/expanse/lustre/scratch/${USER}/temp_project/METAD-CHANGE_ME-${SLURM_JOB_ID}"

export OMPI_MCA_orte_tmpdir_base="/tmp"
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}

mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# --- (optional) freeze a TorchScript model for PLUMED ------------------------
# ${CONTAINER} python3 - <<PYEOF
# import torch
# m = torch.jit.load("${MODEL_PATH}")
# torch.jit.freeze(m).save("${WORKDIR}/model.ptc")
# PYEOF

# --- stage inputs ------------------------------------------------------------
cp "${PLUMED_FILE}" plumed_metad.dat
cp "${TPR_FILE}" metad.tpr
cp "${NDX_FILE}" metad.ndx

# --- run ---------------------------------------------------------------------
${CONTAINER} gmx_mpi mdrun \
    -v -deffnm metad \
    -plumed plumed_metad.dat \
    -nsteps <NSTEPS> \
    -nb gpu -bonded cpu \
    -ntomp ${SLURM_CPUS_PER_TASK} \
    -pin on

echo "End: $(date)"
ls -lh metad.* COLVAR_METAD HILLS_* 2>/dev/null
# Results stay in ${WORKDIR} (scratch). Copy what you need back to /home.
