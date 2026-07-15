#!/bin/bash
# =============================================================================
# MULTI-GPU GROMACS BENCHMARK -- ATOMISTIC / PME  (Expanse, account wis192)
# Systems: TIP3P water boxes (amber99sb-ildn, PME) built in PME-BENCH/
#          small = 50,859 atoms   big = 191,226 atoms
# These USE PME (unlike CG Martini), so they exercise the PP/PME GPU split
# that is the crux of atomistic multi-GPU MD -- i.e. the collaborator's GAFF job.
#
# Measures ns/day for 1-GPU vs 2-GPU partitions and PROVES the partition via
# the mdrun rank->GPU map + a whole-job nvidia-smi dmon utilization timeline.
# Engine: euler_0.0.sif  = GROMACS 2021.5 + PLUMED 2.8.0 (== collaborator's).
# =============================================================================
#SBATCH --job-name=bench-pme
#SBATCH --account=wis192
#SBATCH --partition=gpu-debug
#SBATCH --qos=gpu-debug-normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=90G
#SBATCH --gpus=2
#SBATCH --time=00:30:00
#SBATCH --output=bench-pme-%j.out
#SBATCH --error=bench-pme-%j.err
#SBATCH --export=ALL

set -uo pipefail

SC="/expanse/lustre/scratch/${USER}/temp_project"
SIF="${SC}/euler_0.0.sif"
TPR_S="${SC}/PME-BENCH/water_small_em.tpr"    # 50,859 atoms (energy-minimized)
TPR_B="${SC}/PME-BENCH/water_big_em.tpr"      # 191,226 atoms (energy-minimized)
GMX_TMPI="/usr/local/gromacs_2021.5/bin/gmx"
GMX_MPI="/usr/local/gromacs_2021.5_plumed_2.8.0/bin/gmx_mpi"
MAXH="0.015"                                # ~54 s/config; -resethway halves timed window
BINDS="/expanse,/home,/scratch"
RUN="singularity exec --nv --bind ${BINDS} ${SIF}"
DIRECT="GMX_ENABLE_DIRECT_GPU_COMM=1"

WORKDIR="${SC}/BENCH-PME-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

echo "================================================================"
echo " ATOMISTIC/PME MULTI-GPU BENCHMARK  job=${SLURM_JOB_ID} host=$(hostname) $(date)"
echo "================================================================"
module purge; module load singularitypro
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
nvidia-smi --query-gpu=index,name,memory.total --format=csv 2>&1 | head
echo "--- NVLink topology ---"; nvidia-smi topo -m 2>&1 | head -8

nvidia-smi dmon -s u -d 3 -o DT > "${WORKDIR}/gpu_dmon.log" 2>&1 &
DMON=$!; trap 'kill ${DMON} 2>/dev/null' EXIT

cat > plumed_bench.dat <<'PLU'
d1: DISTANCE ATOMS=1,2
METAD ARG=d1 PACE=100 HEIGHT=0.5 SIGMA=0.05 BIASFACTOR=10 TEMP=300 FILE=HILLS_bench
PRINT ARG=d1 FILE=COLVAR_bench STRIDE=500
PLU

nsday () { grep -a -E "^Performance:" "$1" 2>/dev/null | awk '{print $2}' | tail -1; }
gpumap () { grep -a -E "GPUs? selected for this run|Mapping of GPU IDs|PP:|PME:|will do PME|GPU will be used" "$1" 2>/dev/null | head -8; }
SUMMARY="${WORKDIR}/SUMMARY.txt"; : > "${SUMMARY}"
record () { printf "%-30s %10s   %s\n" "$1" "${2:-FAILED}" "${3:-}" | tee -a "${SUMMARY}"; }
COMMON="-maxh ${MAXH} -resethway -nsteps -1 -noconfout -pin off"   # cgroup blocks in-container pinning; <=20 thr on 20 cores

run_cfg () {  # $1=name $2=env $3=tpr $4...=mdrun args (after '$RUN $bin mdrun')
  local name="$1"; shift; local envp="$1"; shift; local tpr="$1"; shift
  local bin="$1"; shift
  local dir="${WORKDIR}/${name}"; mkdir -p "${dir}"; cp plumed_bench.dat "${dir}/"; cd "${dir}"
  echo "==================================================================="
  echo ">>> ${name}    (tpr=$(basename "$tpr"))"
  echo ">>> env ${envp} ${RUN} ${bin} mdrun -s ${tpr} $*"
  echo "==================================================================="
  local t0=$SECONDS
  env ${envp} ${RUN} "${bin}" mdrun -deffnm md -s "${tpr}" "$@" > mdrun.console 2>&1
  local rc=$?; local perf; perf=$(nsday md.log)
  echo "--- rank->GPU map (${name}) ---"; gpumap md.log
  if [[ -n "${perf}" ]]; then record "${name}" "${perf}" "(rc=${rc}, $((SECONDS-t0))s)";
  else echo "!!! tail:"; tail -18 mdrun.console; record "${name}" "FAILED" "(rc=${rc})"; fi
  cd "${WORKDIR}"
}

echo; echo "########## SMALL (50,859 atoms) ##########"
run_cfg "S_1gpu"        "OMP_NUM_THREADS=10"          "$TPR_S" "$GMX_TMPI" -ntmpi 1 -ntomp 10 -nb gpu -pme gpu -update gpu ${COMMON}
run_cfg "S_2gpu_ppPME"  "OMP_NUM_THREADS=10 $DIRECT"  "$TPR_S" "$GMX_TMPI" -ntmpi 2 -ntomp 10 -nb gpu -pme gpu -npme 1 -gputasks 01 ${COMMON}

echo; echo "########## BIG (191,226 atoms) ##########"
run_cfg "B_1gpu"        "OMP_NUM_THREADS=10"          "$TPR_B" "$GMX_TMPI" -ntmpi 1 -ntomp 10 -nb gpu -pme gpu -update gpu ${COMMON}
run_cfg "B_2gpu_ppPME"  "OMP_NUM_THREADS=10 $DIRECT"  "$TPR_B" "$GMX_TMPI" -ntmpi 2 -ntomp 10 -nb gpu -pme gpu -npme 1 -gputasks 01 ${COMMON}
run_cfg "B_2gpu_ppPME_updGPU" "OMP_NUM_THREADS=10 $DIRECT" "$TPR_B" "$GMX_TMPI" -ntmpi 2 -ntomp 10 -nb gpu -pme gpu -npme 1 -gputasks 01 -update gpu ${COMMON}

echo; echo "########## BIG + PLUMED (gmx_mpi) ##########"
run_cfg "B_1gpu_plumed" "OMP_NUM_THREADS=10"          "$TPR_B" "$GMX_MPI" -ntomp 10 -nb gpu -pme gpu -plumed plumed_bench.dat ${COMMON}

echo ">>> B_2gpu_plumed  (mpirun -np 2)"
mkdir -p "${WORKDIR}/B_2gpu_plumed"; cp plumed_bench.dat "${WORKDIR}/B_2gpu_plumed/"; cd "${WORKDIR}/B_2gpu_plumed"
env OMP_NUM_THREADS=10 GMX_ENABLE_DIRECT_GPU_COMM=1 \
  singularity exec --nv --bind ${BINDS} "${SIF}" \
  mpirun --oversubscribe --bind-to none -np 2 "${GMX_MPI}" mdrun -deffnm md -s "${TPR_B}" -ntomp 10 \
  -nb gpu -pme gpu -npme 1 -gputasks 01 -plumed plumed_bench.dat ${COMMON} > mdrun.console 2>&1
rcE=$?; echo "--- rank->GPU map (B_2gpu_plumed) ---"; gpumap md.log
perfE=$(nsday md.log)
if [[ -n "${perfE}" ]]; then record "B_2gpu_plumed" "${perfE}" "(rc=${rcE})"; else echo "!!! tail:"; tail -18 mdrun.console; record "B_2gpu_plumed" "FAILED" "(rc=${rcE})"; fi
cd "${WORKDIR}"

echo; echo "########## THROUGHPUT: 2x independent 1-GPU BIG (walkers proxy) ##########"
mkdir -p "${WORKDIR}/T_w0" "${WORKDIR}/T_w1"
( cd "${WORKDIR}/T_w0"; env CUDA_VISIBLE_DEVICES=0 OMP_NUM_THREADS=10 ${RUN} \
    "${GMX_TMPI}" mdrun -deffnm md -s "${TPR_B}" -ntmpi 1 -ntomp 10 -nb gpu -pme gpu -update gpu ${COMMON} > mdrun.console 2>&1 ) & p0=$!
( cd "${WORKDIR}/T_w1"; env CUDA_VISIBLE_DEVICES=1 OMP_NUM_THREADS=10 ${RUN} \
    "${GMX_TMPI}" mdrun -deffnm md -s "${TPR_B}" -ntmpi 1 -ntomp 10 -nb gpu -pme gpu -update gpu ${COMMON} > mdrun.console 2>&1 ) & p1=$!
sleep 22
echo "--- LIVE nvidia-smi while BOTH walkers run ---"
nvidia-smi --query-gpu=index,utilization.gpu,memory.used,power.draw --format=csv 2>&1 | head
wait $p0 $p1
w0=$(nsday "${WORKDIR}/T_w0/md.log"); w1=$(nsday "${WORKDIR}/T_w1/md.log")
record "T_walker0_GPU0" "${w0:-FAILED}" "big, concurrent"
record "T_walker1_GPU1" "${w1:-FAILED}" "big, concurrent"
[[ -n "${w0}" && -n "${w1}" ]] && record "T_aggregate_2walkers" "$(awk -v a=$w0 -v b=$w1 'BEGIN{printf "%.2f",a+b}')" "sum"

kill ${DMON} 2>/dev/null; trap - EXIT
echo; echo "================================================================"
echo " SUMMARY (ns/day)"; echo "================================================================"
cat "${SUMMARY}"
echo; echo "--- Speedups ---"
S1=$(awk '/^S_1gpu /{print $2}' "${SUMMARY}"); B1=$(awk '/^B_1gpu /{print $2}' "${SUMMARY}"); BP=$(awk '/^B_1gpu_plumed /{print $2}' "${SUMMARY}")
awk -v s="$S1" '/^S_2gpu/{printf "  SMALL 2-GPU: %s ns/day -> %.2fx vs 1-GPU (%s)\n",$2,($2/s),s}' "${SUMMARY}"
awk -v b="$B1" '/^B_2gpu_ppPME/{printf "  BIG   %s: %s ns/day -> %.2fx vs 1-GPU (%s)\n",$1,$2,($2/b),b}' "${SUMMARY}"
awk -v p="$BP" '/^B_2gpu_plumed/{printf "  BIG+PLUMED 2-GPU: %s ns/day -> %.2fx vs 1-GPU+plumed (%s)\n",$2,($2/p),p}' "${SUMMARY}"
awk -v b="$B1" '/^T_aggregate/{printf "  BIG 2 walkers aggregate: %s ns/day -> %.2fx vs 1-GPU (%s)\n",$2,($2/b),b}' "${SUMMARY}"
echo; echo "--- dmon SM%% timeline (gpu 0 & 1; two busy = both GPUs working) ---"
tail -70 "${WORKDIR}/gpu_dmon.log" 2>/dev/null
echo; echo "Artifacts: ${WORKDIR}"; echo "Done: $(date)"
