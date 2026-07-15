#!/bin/bash
# =============================================================================
# MULTI-GPU GROMACS BENCHMARK HARNESS  (Expanse, account wis192)
# Runs the SAME .tpr under several GPU configurations, reports ns/day, and
# PROVES how the work was partitioned across GPUs:
#   (1) the mdrun rank->GPU mapping table printed in each md.log
#   (2) a continuous `nvidia-smi dmon` utilization timeline for the whole job
#   (3) a live nvidia-smi snapshot while two GPUs run at once
#
# Engine: euler_0.0.sif  ->  GROMACS 2021.5 + PLUMED 2.8.0
#         (same GROMACS/PLUMED as the collaborator's tutorial container)
#   - thread-MPI  gmx  : /usr/local/gromacs_2021.5/bin/gmx        (no PLUMED)
#   - MPI        gmx_mpi: /usr/local/gromacs_2021.5_plumed_2.8.0/bin/gmx_mpi (+ mpirun)
# =============================================================================
#SBATCH --job-name=bench-multigpu
#SBATCH --account=wis192
#SBATCH --partition=gpu-debug          # V100, 30-min cap, fast turnaround
#SBATCH --qos=gpu-debug-normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20             # 2 GPU-slices worth of cores (10/GPU)
#SBATCH --mem=90G
#SBATCH --gpus=2                        # <-- ask SLURM for TWO V100s
#SBATCH --time=00:30:00
#SBATCH --output=bench-multigpu-%j.out
#SBATCH --error=bench-multigpu-%j.err
#SBATCH --export=ALL

set -uo pipefail   # NB: not -e; we WANT to survive a config that mdrun rejects

# ---- config -----------------------------------------------------------------
SC="/expanse/lustre/scratch/${USER}/temp_project"
SIF="${SC}/euler_0.0.sif"
SRC_TPR="${SC}/METAD-SWP-S14-AEO-6cv-lag2000-47623370/metad.tpr"
GMX_TMPI="/usr/local/gromacs_2021.5/bin/gmx"                       # thread-MPI
GMX_MPI="/usr/local/gromacs_2021.5_plumed_2.8.0/bin/gmx_mpi"       # real MPI
MAXH="0.02"                     # wall per config (h) ~1.2 min; -resethway halves timed window
BINDS="/expanse,/home,/scratch"
RUN="singularity exec --nv --bind ${BINDS} ${SIF}"

WORKDIR="${SC}/BENCH-MULTIGPU-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

echo "================================================================"
echo " MULTI-GPU BENCHMARK   job=${SLURM_JOB_ID}  host=$(hostname)"
echo " $(date)"
echo "================================================================"
module purge
module load singularitypro

echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-?}   CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
echo "--- GPUs visible to this job ---"
nvidia-smi --query-gpu=index,name,memory.total,pstate --format=csv 2>&1 | head
echo "--- NVLink topology (why 2 GPUs on one node talk fast) ---"
nvidia-smi topo -m 2>&1 | head -12
echo

# continuous per-GPU SM-utilization timeline for the WHOLE job (proof of 1 vs 2 GPU use)
nvidia-smi dmon -s u -d 3 -o DT > "${WORKDIR}/gpu_dmon.log" 2>&1 &
DMON=$!
trap 'kill ${DMON} 2>/dev/null' EXIT

# ---- stage inputs -----------------------------------------------------------
cp "${SRC_TPR}" ./bench.tpr
# trivial, self-contained PLUMED input: measures the COST of having PLUMED in
# the MD loop (what limits MetaD multi-GPU scaling) WITHOUT needing the
# production model.ptc / metad.ndx files.
cat > plumed_bench.dat <<'PLU'
d1: DISTANCE ATOMS=1,2
METAD ARG=d1 PACE=100 HEIGHT=0.5 SIGMA=0.1 BIASFACTOR=10 TEMP=300 FILE=HILLS_bench
PRINT ARG=d1 FILE=COLVAR_bench STRIDE=500
PLU

# ---- helpers ----------------------------------------------------------------
nsday () { grep -a -E "^Performance:" "$1" 2>/dev/null | awk '{print $2}' | tail -1; }
gpumap () { grep -a -E "GPUs? selected for this run|Mapping of GPU IDs|PP:|PME:|will be used for|PP tasks will do|PME tasks will do" "$1" 2>/dev/null | head -10; }

SUMMARY="${WORKDIR}/SUMMARY.txt"; : > "${SUMMARY}"
record () { printf "%-26s %10s   %s\n" "$1" "${2:-FAILED}" "${3:-}" | tee -a "${SUMMARY}"; }

COMMON="-maxh ${MAXH} -resethway -nsteps -1 -noconfout -pin on -pinstride 1"

run_cfg () {  # $1=name  $2=env-prefix  $3...=mdrun invocation (after $RUN)
  local name="$1"; shift; local envp="$1"; shift
  local dir="${WORKDIR}/${name}"; mkdir -p "${dir}"; cp bench.tpr plumed_bench.dat "${dir}/"; cd "${dir}"
  echo "==================================================================="
  echo ">>> ${name}"
  echo ">>> env ${envp} ${RUN} $*"
  echo "==================================================================="
  local t0=$SECONDS
  env ${envp} ${RUN} "$@" > mdrun.console 2>&1
  local rc=$?
  local perf; perf=$(nsday md.log)
  echo "--- rank->GPU mapping (${name}) ---"; gpumap md.log
  if [[ -n "${perf}" ]]; then record "${name}" "${perf}" "(rc=${rc}, $((SECONDS-t0))s)";
  else echo "!!! no Performance line; tail:"; tail -22 mdrun.console; record "${name}" "FAILED" "(rc=${rc}) see ${name}/mdrun.console"; fi
  cd "${WORKDIR}"
}

echo; echo "########## PURE MD (no PLUMED) ##########"

# A) 1 GPU, SAFE baseline (guaranteed to run) -- the collaborator's 1-slice analog
run_cfg "A_1gpu" "OMP_NUM_THREADS=10" \
  "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 1 -ntomp 10 -nb gpu -pme gpu ${COMMON}

# A2) 1 GPU, GPU-resident (adds -update gpu; may be rejected -> that's a finding)
run_cfg "A2_1gpu_resident" "OMP_NUM_THREADS=10" \
  "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 1 -ntomp 10 -nb gpu -pme gpu -update gpu ${COMMON}

# B) 2 GPU, domain decomposition, dedicated PME rank, GPU-direct comm (NVLink)
run_cfg "B_2gpu_sepPME" "OMP_NUM_THREADS=10 GMX_ENABLE_DIRECT_GPU_COMM=1" \
  "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 2 -ntomp 10 -nb gpu -pme gpu -npme 1 -gputasks 01 ${COMMON}

# C) 2 GPU, both ranks PP on GPU, PME on CPU, GPU-resident update
run_cfg "C_2gpu_resident" "OMP_NUM_THREADS=10 GMX_ENABLE_DIRECT_GPU_COMM=1" \
  "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 2 -ntomp 10 -nb gpu -pme cpu -update gpu -gputasks 01 ${COMMON}

echo; echo "########## WITH PLUMED (gmx_mpi) ##########"

# D) 1 GPU + PLUMED  (the collaborator's REAL baseline shape)
run_cfg "D_1gpu_plumed" "OMP_NUM_THREADS=10" \
  "${GMX_MPI}" mdrun -deffnm md -s bench.tpr -ntomp 10 -nb gpu -pme gpu -plumed plumed_bench.dat ${COMMON}

# E) 2 GPU + PLUMED, dedicated PME rank (their REAL 2-GPU option) -- via mpirun
echo ">>> E_2gpu_plumed  (mpirun -np 2 inside container)"
mkdir -p "${WORKDIR}/E_2gpu_plumed"; cp bench.tpr plumed_bench.dat "${WORKDIR}/E_2gpu_plumed/"; cd "${WORKDIR}/E_2gpu_plumed"
env OMP_NUM_THREADS=10 GMX_ENABLE_DIRECT_GPU_COMM=1 \
  singularity exec --nv --bind ${BINDS} "${SIF}" \
  mpirun -np 2 "${GMX_MPI}" mdrun -deffnm md -s bench.tpr -ntomp 10 \
  -nb gpu -pme gpu -npme 1 -gputasks 01 -plumed plumed_bench.dat ${COMMON} > mdrun.console 2>&1
rcE=$?; echo "--- rank->GPU mapping (E) ---"; gpumap md.log
perfE=$(nsday md.log)
if [[ -n "${perfE}" ]]; then record "E_2gpu_plumed" "${perfE}" "(rc=${rcE})"; else echo "!!! tail:"; tail -22 mdrun.console; record "E_2gpu_plumed" "FAILED" "(rc=${rcE})"; fi
cd "${WORKDIR}"

echo; echo "########## THROUGHPUT: 2x independent 1-GPU (multiple-walkers proxy) ##########"
mkdir -p "${WORKDIR}/F_walker0" "${WORKDIR}/F_walker1"
cp bench.tpr "${WORKDIR}/F_walker0/"; cp bench.tpr "${WORKDIR}/F_walker1/"
( cd "${WORKDIR}/F_walker0"; env CUDA_VISIBLE_DEVICES=0 OMP_NUM_THREADS=10 ${RUN} \
    "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 1 -ntomp 10 -nb gpu -pme gpu \
    -pinoffset 0  ${COMMON} > mdrun.console 2>&1 ) & p0=$!
( cd "${WORKDIR}/F_walker1"; env CUDA_VISIBLE_DEVICES=1 OMP_NUM_THREADS=10 ${RUN} \
    "${GMX_TMPI}" mdrun -deffnm md -s bench.tpr -ntmpi 1 -ntomp 10 -nb gpu -pme gpu \
    -pinoffset 10 ${COMMON} > mdrun.console 2>&1 ) & p1=$!
sleep 25
echo "--- LIVE nvidia-smi while BOTH walkers run (proof both GPUs busy) ---"
nvidia-smi --query-gpu=index,utilization.gpu,memory.used,power.draw --format=csv 2>&1 | head
wait $p0 $p1
w0=$(nsday "${WORKDIR}/F_walker0/md.log"); w1=$(nsday "${WORKDIR}/F_walker1/md.log")
record "F_walker0_GPU0" "${w0:-FAILED}" "1-GPU, concurrent"
record "F_walker1_GPU1" "${w1:-FAILED}" "1-GPU, concurrent"
if [[ -n "${w0}" && -n "${w1}" ]]; then
  agg=$(awk -v a="${w0}" -v b="${w1}" 'BEGIN{printf "%.2f", a+b}'); record "F_aggregate_2walkers" "${agg}" "sum"
fi

kill ${DMON} 2>/dev/null; trap - EXIT
echo
echo "================================================================"
echo " SUMMARY (ns/day; higher = faster)"
echo "================================================================"
cat "${SUMMARY}"
echo
A=$(awk '/^A_1gpu /{print $2}' "${SUMMARY}")
echo "Speedup vs A_1gpu baseline (${A:-?} ns/day):"
if [[ -n "${A}" ]]; then
  awk -v A="${A}" '/^(A2|B_|C_|D_|E_|F_aggregate)/{printf "  %-24s %9s ns/day  -> %.2fx\n",$1,$2,($2/A)}' "${SUMMARY}"
fi
echo
echo "--- GPU utilization timeline (nvidia-smi dmon: sm%% per GPU over time) ---"
echo "  (col 'sm' for gpu 0 and gpu 1; two busy columns = both GPUs working)"
sed -n '1,3p;/./p' "${WORKDIR}/gpu_dmon.log" 2>/dev/null | tail -60
echo
echo "Artifacts: ${WORKDIR}  (per-config md.log/mdrun.console, SUMMARY.txt, gpu_dmon.log)"
echo "Done: $(date)"
