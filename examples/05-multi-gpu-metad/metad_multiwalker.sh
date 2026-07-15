#!/bin/bash
# =============================================================================
# ⭐ RECOMMENDED multi-GPU metadynamics on Expanse:
#    ONE job, N GPUs, N multiple-walkers (gmx_mpi -multidir + PLUMED WALKERS_MPI).
#    Each walker owns one V100 and runs at full single-GPU speed (~90% util);
#    the walkers SHARE one growing bias -> ~N× faster convergence of the FES.
#
# This is the efficient way to answer "run my metadynamics on multiple GPUs."
# Validated on Expanse (see bench/bench_multiwalker.sh and this folder's README).
# Adapted from the collaborator's single-GPU script (same container/trap style).
#
# TO SCALE: set NWALKERS and --gpus/--cpus-per-task together (10 cores/GPU).
#   2 walkers -> --gpus=2 --cpus-per-task=20 --mem=180G   -np 2
#   4 walkers -> --gpus=4 --cpus-per-task=40 --mem=360G   -np 4   (a full node)
# =============================================================================
#SBATCH --job-name=metad-mw-nopva-gaff-500
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20            # 2 walkers × 10 cores/GPU
#SBATCH --mem=180G                    # 2 walkers × ~90 GB/GPU
#SBATCH --gpus=2                      # 2 V100 = 2 walkers
#SBATCH --time=48:00:00
#SBATCH --output=slurm-metad-mw-nopva-gaff-500-%j.out
#SBATCH --error=slurm-metad-mw-nopva-gaff-500-%j.err
#SBATCH --account=wis193
#SBATCH --export=ALL
#SBATCH --mail-user=CHANGE_ME@wisc.edu     # <-- your email
#SBATCH --mail-type=END,FAIL
#SBATCH --signal=B:USR1@300

set -euo pipefail

# --- config ------------------------------------------------------------------
NWALKERS=2
INPUT_DIR="/expanse/lustre/scratch/${USER}/temp_project/metad_nopva_gaff_500"
TPR_FILE="${INPUT_DIR}/md_nopva_gly_gaff_500_big.tpr"
PLUMED_FILE="${INPUT_DIR}/metad_nopva_gly_2d.dat"   # must contain WALKERS_MPI on its METAD line (see below)
SCRIPT="${INPUT_DIR}/metad_multiwalker.sh"
SIF="/expanse/lustre/scratch/${USER}/temp_project/containers/tutorial_gromacs2021.5_plumed2.8-crystall.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

WORKDIR="/expanse/lustre/scratch/${USER}/temp_project/METAD-MW-NOPVA-GAFF-500-${SLURM_JOB_ID}"
export OMPI_MCA_orte_tmpdir_base="/tmp"
export OMP_NUM_THREADS=$(( SLURM_CPUS_PER_TASK / NWALKERS ))   # 10 threads per walker
export GMX_ENABLE_DIRECT_GPU_COMM=1                            # NVLink

# --- trap: 5 min before wall time, save every walker's checkpoint and resubmit -
resubmit() {
    echo "[INFO] Wall time approaching — saving checkpoints and resubmitting..."
    sleep 30
    for i in $(seq 0 $((NWALKERS-1))); do
        cp "${WORKDIR}/walker${i}/"md.cpt   "${INPUT_DIR}/walker${i}.cpt"   2>/dev/null || true
        cp "${WORKDIR}/walker${i}/"COLVAR*  "${INPUT_DIR}/"                 2>/dev/null || true
        cp "${WORKDIR}/walker${i}/"HILLS*   "${INPUT_DIR}/"                 2>/dev/null || true
        cp "${WORKDIR}/walker${i}/"md.log   "${INPUT_DIR}/walker${i}.log"   2>/dev/null || true
    done
    if grep -q "Finished mdrun" "${WORKDIR}/walker0/md.log" 2>/dev/null; then
        echo "[INFO] Simulation complete! No resubmission needed."
    else
        sbatch "${SCRIPT}"; echo "[INFO] Job resubmitted."
    fi
    exit 0
}
trap resubmit USR1

echo "=================================================================="
echo " 2D WT-MetaD  ${NWALKERS} walkers × 1 GPU  (nopva/gaff/500)"
echo " Job ${SLURM_JOB_ID}  host $(hostname)  $(date)"
echo " OMP threads/walker=${OMP_NUM_THREADS}  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
echo "=================================================================="
module purge; module load singularitypro

[[ -f "${TPR_FILE}"    ]] || { echo "[ERROR] Missing TPR: ${TPR_FILE}";    exit 1; }
[[ -f "${PLUMED_FILE}" ]] || { echo "[ERROR] Missing PLUMED: ${PLUMED_FILE}"; exit 1; }
grep -q "WALKERS_MPI" "${PLUMED_FILE}" || echo "[WARN] '${PLUMED_FILE}' has no WALKERS_MPI — walkers will NOT share the bias!"

# --- set up one directory per walker -----------------------------------------
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"
for i in $(seq 0 $((NWALKERS-1))); do
    d="walker${i}"; mkdir -p "$d"
    cp "${TPR_FILE}"    "${d}/md.tpr"
    cp "${PLUMED_FILE}" "${d}/plumed_metad.dat"
    [[ -f "${INPUT_DIR}/walker${i}.cpt" ]] && cp "${INPUT_DIR}/walker${i}.cpt" "${d}/md.cpt"   # restart if present
done
WALKER_DIRS=$(seq -f "walker%g" 0 $((NWALKERS-1)) | tr '\n' ' ')
echo "Walker dirs: ${WALKER_DIRS}"

# --- run: N ranks, GROMACS auto-assigns 1 GPU per rank -----------------------
# -cpi md.cpt resumes each walker from its own checkpoint if present.
${CONTAINER} mpirun --oversubscribe --bind-to none -np ${NWALKERS} \
    gmx_mpi mdrun -multidir ${WALKER_DIRS} \
        -deffnm md -s md.tpr -cpi md.cpt -plumed plumed_metad.dat \
        -ntomp ${OMP_NUM_THREADS} -nb gpu -pme gpu \
        -maxh 47.5 -noconfout

# --- copy results back to the input dir (scratch is not backed up) -----------
for i in $(seq 0 $((NWALKERS-1))); do
    cp "${WORKDIR}/walker${i}/"{md.cpt,md.log,COLVAR*,HILLS*} "${INPUT_DIR}/" 2>/dev/null || true
done
echo "[INFO] Done: $(date)"

# -----------------------------------------------------------------------------
# ONE change to your PLUMED input (metad_nopva_gly_2d.dat): add WALKERS_MPI to
# the METAD line so the walkers share hills, e.g.
#
#   metad: METAD ARG=deeptica.node-0,deeptica.node-1 PACE=... HEIGHT=... \
#          SIGMA=0.03,0.03 BIASFACTOR=500 FILE=HILLS TEMP=300 WALKERS_MPI
#
# With WALKERS_MPI + gmx_mpi -multidir, PLUMED shares the bias across ranks
# automatically — no per-walker WALKERS_DIR/WALKERS_ID bookkeeping needed.
# =============================================================================
