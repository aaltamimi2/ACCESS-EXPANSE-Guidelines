#!/bin/bash
# =============================================================================
# Single metadynamics TRAJECTORY across 2 GPUs (PP on gpu0 | PME on gpu1).
# This is the literal "put my job on 2 GPUs" the question asked for.
#
#  ⚠️  HONEST WARNING (measured on Expanse V100 — see this folder's README):
#      For a ≤ ~200k-atom system this runs at ~0.5× of a SINGLE GPU, and with
#      PLUMED attached the 2nd GPU gives ~0% benefit. You would pay 2× the SUs
#      for ~half the speed. BENCHMARK YOUR SYSTEM (bench/bench_pme.sh) before
#      using this in production. For metadynamics, prefer metad_multiwalker.sh.
#
# Kept here because (a) it's what was asked, (b) it's the correct recipe IF you
# ever have a large enough (≳0.5–1M atom), non-PLUMED-bound system where it wins.
# Adapted from the collaborator's single-GPU script.
# =============================================================================
#SBATCH --job-name=metad-2gpu-nopva-gaff-500
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1                    # 1 sbatch task; mpirun spawns the 2 ranks
#SBATCH --cpus-per-task=20            # 2 × 10 cores
#SBATCH --mem=180G
#SBATCH --gpus=2                      # <-- was --gpus=1
#SBATCH --time=48:00:00
#SBATCH --output=slurm-metad-2gpu-nopva-gaff-500-%j.out
#SBATCH --error=slurm-metad-2gpu-nopva-gaff-500-%j.err
#SBATCH --account=wis193
#SBATCH --export=ALL
#SBATCH --mail-user=CHANGE_ME@wisc.edu     # <-- your email
#SBATCH --mail-type=END,FAIL
#SBATCH --signal=B:USR1@300

set -euo pipefail

INPUT_DIR="/expanse/lustre/scratch/${USER}/temp_project/metad_nopva_gaff_500"
TPR_FILE="${INPUT_DIR}/md_nopva_gly_gaff_500_big.tpr"
PLUMED_FILE="${INPUT_DIR}/metad_nopva_gly_2d.dat"
DEFFNM="md_nopva_gly_gaff_500_big"
SCRIPT="${INPUT_DIR}/metad_2gpu_singlejob.sh"
SIF="/expanse/lustre/scratch/${USER}/temp_project/containers/tutorial_gromacs2021.5_plumed2.8-crystall.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"
WORKDIR="/expanse/lustre/scratch/${USER}/temp_project/METAD-2GPU-NOPVA-GAFF-500-${SLURM_JOB_ID}"

export OMPI_MCA_orte_tmpdir_base="/tmp"
export OMP_NUM_THREADS=10                 # 10 threads per rank (2 ranks × 10 = 20 cores)
export GMX_ENABLE_DIRECT_GPU_COMM=1       # PP⇄PME over NVLink

resubmit() {
    echo "[INFO] Wall time approaching — checkpoint + resubmit..."; sleep 30
    cp "${WORKDIR}/${DEFFNM}.cpt" "${INPUT_DIR}/" 2>/dev/null && echo "[INFO] cpt saved" || echo "[WARN] no cpt"
    cp "${WORKDIR}"/COLVAR* "${INPUT_DIR}/" 2>/dev/null || true
    cp "${WORKDIR}"/HILLS*  "${INPUT_DIR}/" 2>/dev/null || true
    cp "${WORKDIR}/${DEFFNM}.log" "${INPUT_DIR}/" 2>/dev/null || true
    if grep -q "Finished mdrun" "${WORKDIR}/${DEFFNM}.log" 2>/dev/null; then echo "[INFO] complete"; else sbatch "${SCRIPT}"; echo "[INFO] resubmitted"; fi
    exit 0
}
trap resubmit USR1

echo "=== 2D WT-MetaD (nopva/gaff/500) — SINGLE TRAJECTORY on 2 GPUs ==="
echo "Job ${SLURM_JOB_ID}  host $(hostname)  $(date)  CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
module purge; module load singularitypro

[[ -f "${TPR_FILE}"    ]] || { echo "[ERROR] Missing TPR: ${TPR_FILE}"; exit 1; }
[[ -f "${PLUMED_FILE}" ]] || { echo "[ERROR] Missing PLUMED: ${PLUMED_FILE}"; exit 1; }

mkdir -p "${WORKDIR}" && cd "${WORKDIR}"
cp "${PLUMED_FILE}" plumed_metad.dat
cp "${TPR_FILE}" "${DEFFNM}.tpr"
[[ -f "${INPUT_DIR}/${DEFFNM}.cpt" ]] && cp "${INPUT_DIR}/${DEFFNM}.cpt" .   # restart if present

# --- 2 ranks: rank0 = PP on gpu0, rank1 = PME on gpu1 (-npme 1, -gputasks 01) ---
${CONTAINER} mpirun --oversubscribe --bind-to none -np 2 \
    gmx_mpi mdrun -deffnm "${DEFFNM}" -s "${DEFFNM}.tpr" \
        -cpi "${DEFFNM}.cpt" -plumed plumed_metad.dat \
        -ntomp 10 -nb gpu -pme gpu -npme 1 -gputasks 01 \
        -maxh 47.5 -noconfout

cp "${WORKDIR}/${DEFFNM}.cpt" "${WORKDIR}/${DEFFNM}.log" "${WORKDIR}"/COLVAR* "${WORKDIR}"/HILLS* "${INPUT_DIR}/" 2>/dev/null || true
echo "[INFO] Done: $(date)"
# Compare this job's ns/day (grep Performance: ${DEFFNM}.log) against your 1-GPU
# run. If it is not clearly >1×, go back to 1 GPU or metad_multiwalker.sh.
