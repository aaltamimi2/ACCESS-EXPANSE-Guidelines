#!/bin/bash
# =============================================================================
# TEMPLATE — GPU job with QOS, email, and explicit Singularity TMPDIR/CACHEDIR
# Derived from submit_SURF554_dt0.01.sh. Use this when you want job notifications
# and full control over where Singularity writes its scratch/temp files.
# =============================================================================

#SBATCH --account=wis192
#SBATCH --partition=gpu-shared
#SBATCH --qos=gpu-shared-normal          # QOS tier (matches the partition)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --gpus=1
#SBATCH --job-name=CHANGE_ME
#SBATCH --output=logs/CHANGE_ME_%j.out   # note: logs/ must exist before submit
#SBATCH --mail-type=END,FAIL             # email when the job ends or fails
#SBATCH --mail-user=aaltamimi2@wisc.edu

set -euo pipefail

echo "Start: $(date)"; echo "Host: $(hostname)"

# --- optional: shared config sourced by all pipeline scripts -----------------
# source ${HOME}/<pipeline>/config/pipeline_config.sh

module purge
module load slurm gpu singularitypro/4.1.2

SCRATCH_BASE="/expanse/lustre/scratch/${USER}/temp_project"
SINGULARITY_IMAGE="${SCRATCH_BASE}/<image>.sif"

# --- keep Singularity's temp/cache on fast scratch, not home -----------------
export SINGULARITY_TMPDIR="${SCRATCH_BASE}/sing_tmp"
export SINGULARITY_CACHEDIR="${SCRATCH_BASE}/sing_cache"
export TMPDIR="${SINGULARITY_TMPDIR}"
export OMPI_MCA_orte_tmpdir_base="${SINGULARITY_TMPDIR}"
export OMPI_MCA_btl_vader_single_copy_mechanism=none   # avoids an OpenMPI/CMA warning
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

GMX="singularity exec --nv --bind /expanse ${SINGULARITY_IMAGE} gmx_mpi"

# --- work in scratch ---------------------------------------------------------
WORKDIR="${SCRATCH_BASE}/<run>/${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# ... stage inputs, build tpr, etc. ...

${GMX} mdrun -v -deffnm metad -plumed plumed.dat \
    -nb gpu -bonded gpu -ntomp ${OMP_NUM_THREADS}

echo "End: $(date)"
# copy results back to /home — scratch is purged
