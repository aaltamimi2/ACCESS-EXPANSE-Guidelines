#!/bin/bash
# =============================================================================
# MULTI-GPU SBATCH HEADER (Expanse gpu-shared) — 2 GPUs on one node.
# Scale the CPU/mem WITH the GPUs: Expanse gives ~10 cores + ~90 GB per V100.
# Copy, fill the CHANGE_ME fields, add your job body. Keep it version-controlled
# and `scp` it up (see ../../README.md). See THIS folder's README before using
# 2 GPUs on a single metadynamics trajectory — it is usually SLOWER; prefer
# multiple walkers (metad_multiwalker.sh).
# =============================================================================
#SBATCH --job-name=CHANGE_ME
#SBATCH --account=CHANGE_ME            # e.g. wis192 / wis193 — REQUIRED
#SBATCH --partition=gpu-shared        # gpu-debug for <30-min tests
#SBATCH --nodes=1                     # one node (a node has 4 V100)
#SBATCH --ntasks=1                    # 1 for thread-MPI `gmx`; set = N if you use `mpirun -np N`
#SBATCH --cpus-per-task=20            # 2 GPUs × ~10 cores       (was 10 for 1 GPU)
#SBATCH --mem=180G                    # 2 GPUs × ~90 GB          (was ~40–90G for 1 GPU)
#SBATCH --gpus=2                      # <-- TWO V100s            (was --gpus=1)
#SBATCH --time=48:00:00
#SBATCH --output=slurm-CHANGE_ME-%j.out
#SBATCH --error=slurm-CHANGE_ME-%j.err
#SBATCH --export=ALL
# ---- optional ----
# #SBATCH --qos=gpu-shared-normal
# #SBATCH --mail-type=END,FAIL
# #SBATCH --mail-user=CHANGE_ME@wisc.edu

set -euo pipefail
echo "Job ${SLURM_JOB_ID} on $(hostname) — $(date)"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"   # SLURM sets this to your 2 GPUs
nvidia-smi --query-gpu=index,name --format=csv                # sanity: two V100 listed?

module purge
module load singularitypro

SC="/expanse/lustre/scratch/${USER}/temp_project"
SIF="${SC}/CHANGE_ME.sif"                                     # GROMACS+PLUMED container
WORKDIR="${SC}/JOBNAME-${SLURM_JOB_ID}"                       # per-job scratch dir
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

# ---- stage inputs from /home or an inputs dir into scratch ------------------
# cp /path/to/{topol.tpr,plumed.dat} ./

# ---- RUN (pick ONE; see this folder's README) -------------------------------
# NB: `gmx` in the container = thread-MPI (no PLUMED); `gmx_mpi` = MPI (+PLUMED, needs mpirun).
export GMX_ENABLE_DIRECT_GPU_COMM=1   # let the 2 GPUs talk over NVLink

# (A) RECOMMENDED — 2 walkers, 1 GPU each, shared bias (see metad_multiwalker.sh):
#   mpirun --oversubscribe --bind-to none -np 2 gmx_mpi mdrun -multidir w0 w1 \
#       -deffnm md -s topol.tpr -plumed plumed.dat -ntomp 10 -nb gpu -pme gpu -maxh 47.5 -noconfout
#
# (B) Single trajectory across 2 GPUs (PP|PME split — usually SLOWER, benchmark first):
#   mpirun --oversubscribe --bind-to none -np 2 gmx_mpi mdrun \
#       -deffnm md -s topol.tpr -plumed plumed.dat -ntomp 10 \
#       -nb gpu -pme gpu -npme 1 -gputasks 01 -maxh 47.5 -noconfout

# ---- copy results back to /home (scratch is not backed up) ------------------
# cp md.log COLVAR* HILLS* "${HOME}/path/to/keep/"
echo "End: $(date)"
