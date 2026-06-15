#!/bin/bash
# =============================================================================
# BASE SBATCH HEADER — job-agnostic starting point for Expanse (account wis192)
# Copy this, rename, fill in the marked fields, then add your job body below.
# Keep a version-controlled copy, scp up, submit on Expanse.
# =============================================================================

#SBATCH --job-name=CHANGE_ME          # short name shown in squeue
#SBATCH --account=wis192              # REQUIRED — allocation to charge
#SBATCH --partition=gpu-shared       # gpu-shared | gpu | shared | compute | debug
#SBATCH --nodes=1                    # 1 for shared partitions
#SBATCH --ntasks=1                   # MPI tasks
#SBATCH --cpus-per-task=10           # ~10 cores per GPU on gpu-shared
#SBATCH --mem=16G                    # RAM (16–64G typical for 1 GPU)
#SBATCH --gpus=1                     # drop this line for CPU-only (shared/compute)
#SBATCH --time=48:00:00              # walltime HH:MM:SS — hard kill at limit
#SBATCH --output=slurm-CHANGE_ME-%j.out   # %j = job id
#SBATCH --error=slurm-CHANGE_ME-%j.err
#SBATCH --export=ALL                 # inherit submit-time environment
# ---- optional ----
# #SBATCH --qos=gpu-shared-normal
# #SBATCH --mail-type=END,FAIL
# #SBATCH --mail-user=aaltamimi2@wisc.edu

set -euo pipefail

# ---- log header (makes failures debuggable) ---------------------------------
echo "Job ID:  ${SLURM_JOB_ID}"
echo "Start:   $(date)"
echo "Host:    $(hostname)"

# ---- environment ------------------------------------------------------------
module purge
module load singularitypro           # + 'slurm gpu' if needed; or anaconda3 for conda

export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}

# ---- run in scratch, not home -----------------------------------------------
WORKDIR="/expanse/lustre/scratch/${USER}/temp_project/JOBNAME-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# ---- stage inputs from /home → scratch --------------------------------------
# cp /home/${USER}/path/to/input ./

# ---- run --------------------------------------------------------------------
# SIF="/expanse/lustre/scratch/${USER}/temp_project/your_image.sif"
# CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"
# ${CONTAINER} <your command>

# ---- copy results back to /home (scratch is purged!) ------------------------
# cp results.* /home/${USER}/path/to/keep/

echo "End: $(date)"
