#!/bin/bash
# =============================================================================
# VALIDATE the RECOMMENDED multi-GPU pattern for metadynamics:
#   ONE job, N GPUs, N multiple-walkers via `gmx_mpi -multidir` + PLUMED
#   WALKERS_MPI (walkers share one bias). Each walker gets its own GPU.
# This is "multiple GPUs for the same job" done the efficient way.
# Engine: euler_0.0.sif = GROMACS 2021.5 + PLUMED 2.8.0
# =============================================================================
#SBATCH --job-name=bench-walkers
#SBATCH --account=wis192
#SBATCH --partition=gpu-debug
#SBATCH --qos=gpu-debug-normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=90G
#SBATCH --gpus=2
#SBATCH --time=00:15:00
#SBATCH --output=bench-walkers-%j.out
#SBATCH --error=bench-walkers-%j.err
#SBATCH --export=ALL
set -uo pipefail

SC="/expanse/lustre/scratch/${USER}/temp_project"
SIF="${SC}/euler_0.0.sif"
TPR="${SC}/PME-BENCH/water_big_em.tpr"
GMX_MPI="/usr/local/gromacs_2021.5_plumed_2.8.0/bin/gmx_mpi"
BINDS="/expanse,/home,/scratch"
W="${SC}/BENCH-WALKERS-${SLURM_JOB_ID}"; mkdir -p "$W" && cd "$W"
module purge; module load singularitypro
echo "job=${SLURM_JOB_ID} host=$(hostname) $(date)"

nvidia-smi dmon -s u -d 3 -o DT > "$W/gpu_dmon.log" 2>&1 & DMON=$!; trap 'kill ${DMON} 2>/dev/null' EXIT

# per-walker dirs; each needs the tpr + a plumed input carrying WALKERS_MPI
for d in w0 w1; do
  mkdir -p "$W/$d"; cp "$TPR" "$W/$d/topol.tpr"
  cat > "$W/$d/plumed.dat" <<'PLU'
d1: DISTANCE ATOMS=1,2
METAD ARG=d1 PACE=100 HEIGHT=0.5 SIGMA=0.05 BIASFACTOR=10 TEMP=300 FILE=HILLS WALKERS_MPI
PRINT ARG=d1 FILE=COLVAR STRIDE=500
PLU
done

echo ">>> mpirun -np 2 gmx_mpi mdrun -multidir w0 w1  (1 GPU per walker, shared bias)"
env GMX_ENABLE_DIRECT_GPU_COMM=1 OMP_NUM_THREADS=10 \
  singularity exec --nv --bind ${BINDS} "${SIF}" \
  mpirun --oversubscribe --bind-to none -np 2 "${GMX_MPI}" mdrun \
  -multidir w0 w1 -deffnm md -s topol.tpr -plumed plumed.dat -ntomp 10 \
  -nb gpu -pme gpu -nsteps 20000 -resetstep 8000 -noconfout -pin off \
  > mdrun.console 2>&1
rc=$?
echo "rc=$rc"
echo "--- per-walker ns/day ---"
for d in w0 w1; do
  p=$(grep -a -E "^Performance:" "$W/$d/md.log" 2>/dev/null | awk '{print $2}' | tail -1)
  echo "  $d: ${p:-FAILED} ns/day"
done
echo "--- did walkers share the bias? (each HILLS should see the other's hills) ---"
for d in w0 w1; do echo "  $d HILLS lines: $(wc -l < "$W/$d/HILLS" 2>/dev/null || echo NA)"; done
echo "--- GPU map ---"; grep -aE "GPUs? selected|Mapping of GPU|PP:|PME:" "$W/w0/md.log" 2>/dev/null | head
echo "--- console tail (if failed) ---"; [[ $rc -ne 0 ]] && tail -20 "$W/mdrun.console"
kill ${DMON} 2>/dev/null; trap - EXIT
echo "--- dmon (both GPUs busy?) ---"; tail -8 "$W/gpu_dmon.log"
echo "Artifacts: $W"; echo "Done $(date)"
