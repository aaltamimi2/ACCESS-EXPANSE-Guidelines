# 05 · Running GROMACS + PLUMED metadynamics on multiple GPUs (Expanse)

> **Question from a collaborator:** *"How do I change my metadynamics job so it
> runs on multiple GPUs?"* (their script requests `--gpus=1`; they want it faster.)
>
> **Short answer, backed by benchmarks on Expanse V100s below:** For a single
> GROMACS **metadynamics** trajectory, putting **2 GPUs on one simulation makes
> it ~2× *slower*, not faster** — and with PLUMED in the loop the second GPU does
> nothing. The right way to use N GPUs for metadynamics is **N one-GPU walkers**
> (one job, `-multidir`, `WALKERS_MPI`): **~N× the sampling, both GPUs ~90% busy.**

This example builds directly on **[⭐ example 01](../01-gpu-metad-sweep/)** (the
canonical single-GPU GROMACS/PLUMED-in-Singularity job). Read that first — here we
only change *how many GPUs* the work spreads over.

Everything below was **measured on Expanse**, not assumed. The harness, raw
numbers, and GROMACS's own timing breakdown are in [`bench/`](bench/).

---

## TL;DR — what to do

| You want… | Do this | Why |
|---|---|---|
| **Faster convergence of one FES** | **Multiple walkers**, 1 GPU each, one job (`-multidir` + `WALKERS_MPI`) | ~N× sampling, both GPUs saturated. **Recommended.** |
| **More independent replicas / a CV sweep** | **N separate `--gpus=1` jobs** (see [example 04](../04-batch-submitter/)) | Simplest; same per-GPU efficiency |
| **One trajectory to literally go faster on 2 GPUs** | Usually *not possible* for MetaD on V100 — benchmark first ([`bench/`](bench/)) | PP\|PME split underutilizes both GPUs; PLUMED is the real ceiling |

**Do not** just change `--gpus=1` → `--gpus=2` on a single MetaD run and expect a
speedup. You will pay 2× the SUs to run at ~0.5× the speed (**~4× worse
throughput per SU**). The benchmark proves it.

---

## 1 · The mechanics: getting 2 GPUs allocated on Expanse

Expanse GPU nodes = **4× NVIDIA V100 (32 GB, NVLink), 40 cores, 384 GB**. On
`gpu-shared` you rent GPUs by the slice; the going ratio is **~10 cores + ~90 GB
per GPU**. To ask SLURM for two GPUs on one node, scale the header:

```bash
#SBATCH --partition=gpu-shared
#SBATCH --nodes=1
#SBATCH --ntasks=1                 # 1 for thread-MPI; = N if you launch via mpirun -np N
#SBATCH --cpus-per-task=20         # 2 slices → 2×10 cores  (was 10 for 1 GPU)
#SBATCH --mem=180G                 # ~90 GB/GPU            (was ~40–90G for 1 GPU)
#SBATCH --gpus=2                   # <-- TWO V100s         (was --gpus=1)
```

SLURM hands the job two GPUs and sets `CUDA_VISIBLE_DEVICES=0,1`; inside the
Singularity container (`--nv`) they appear as GPU 0 and 1, NVLink-connected. That
part is easy and *works*. The hard part is that **GROMACS can rarely use them
well for one MetaD trajectory** — which is the rest of this document.

---

## 2 · The benchmark (Expanse V100, GROMACS 2021.5 + PLUMED 2.8.0)

Same GROMACS/PLUMED build as the collaborator's container
(`gromacs2021.5_plumed2.8`). Test systems are atomistic **TIP3P water + PME**
(the electrostatics engine a GAFF atomistic job uses), energy-minimized, two
sizes to expose the size-dependence of scaling. Each config runs the *same* input
under a fixed wall clock; we report **ns/day** (`-resethway` discards warm-up).

| Config | System | ns/day | vs 1-GPU |
|---|---:|---:|---:|
| 1 GPU (PP+PME+update on GPU) | 50 k atoms | **427.8** | 1.00× |
| 2 GPU (PP on gpu0, PME on gpu1) | 50 k atoms | 236.4 | **0.55× 🔻** |
| 1 GPU | 191 k atoms | **124.1** | 1.00× |
| 2 GPU (PP\|PME split) | 191 k atoms | 65.2 | **0.53× 🔻** |
| 2 GPU + `-update gpu` (GPU-resident) | 191 k atoms | 67.9 | 0.55× 🔻 |
| **1 GPU + PLUMED** | 191 k atoms | 69.1 | *(PLUMED caps it)* |
| **2 GPU + PLUMED** | 191 k atoms | 68.7 | **0.99× ⟂ (no gain)** |
| **2 walkers × 1 GPU (aggregate)** | 191 k atoms | **248.0** | **2.00× ✅** |

Two independent 1-GPU walkers each hit **124 ns/day** — full speed — for a
combined **248 ns/day**, with **both GPUs at ~90% utilization**. Every attempt to
make *one* trajectory span two GPUs lost.

---

## 3 · Why single-job 2-GPU is slower (GROMACS says so itself)

To split one simulation across 2 GPUs, GROMACS dedicates one GPU to the
non-bonded/particle (PP) work and the *entire other GPU* to PME (reciprocal-space
electrostatics). For systems this size that is a bad trade. From the 191 k-atom
2-GPU run's own cycle accounting ([`bench/results/evidence.txt`](bench/results/evidence.txt)):

```
 PME wait for PP  ........ 36.2 %   ← the PME GPU sits idle a THIRD of the time
 Wait GPU NB local ...... 20.6 %   ← the PP GPU waiting on its own kernels
 Send X to PME .......... 9.4 %  ┐
 Wait + Recv. PME F ..... 7.9 %  ├─ ~30% is just PP⇄PME communication
 Wait PME GPU gather .... 13.0 % ┘
```
> `NOTE: … using 10 OpenMP threads per rank, which is most likely inefficient.
> The optimum is usually between 2 and 6 threads per rank.` — GROMACS

**Over half the wall-clock is waiting and communicating, not computing.** The
`nvidia-smi` timeline confirms it: in the split, **gpu0 (PP) ≈ 47%** and
**gpu1 (PME) ≈ 31%** — both live (the partition *works*), both starved. Neither
V100 is close to saturated because a ≤200 k-atom system doesn't even fill *one*
V100. Splitting only adds overhead.

**And PLUMED is the real ceiling.** Notice 1-GPU drops from 124 → 69 ns/day the
moment PLUMED is attached: `-plumed` forces the integration/constraints back onto
the CPU each step (no GPU-resident `-update gpu`) and adds the collective-variable
work. Once PLUMED sets the pace at ~69 ns/day, the GPU is no longer the
bottleneck, so a second GPU changes nothing (0.99×). A real DeepTICA/`PYTORCH_MODEL`
bias like the collaborator's costs *more* CPU than this trivial test bias, making
the second GPU even more pointless.

---

## 4 · The recommended pattern: multiple walkers, one GPU each

Metadynamics doesn't need one trajectory to run faster — it needs **more sampling
of the bias**. That is *embarrassingly parallel across GPUs*: run N walkers that
each own one GPU and **share one growing bias**. This is genuine "multiple GPUs
for the same job," and it scales.

**One job, N GPUs, N walkers** (`-multidir` + PLUMED `WALKERS_MPI`) — see
[`metad_multiwalker.sh`](metad_multiwalker.sh):

```bash
#SBATCH --gpus=2 --cpus-per-task=20 --mem=180G --ntasks=1   # N=2 walkers → N GPUs

export GMX_ENABLE_DIRECT_GPU_COMM=1
singularity exec --nv --bind /expanse,/home,/scratch "$SIF" \
  mpirun --oversubscribe --bind-to none -np 2 \
    gmx_mpi mdrun -multidir walker0 walker1 \
      -deffnm md -s topol.tpr -plumed plumed.dat \
      -ntomp 10 -nb gpu -pme gpu \
      -maxh 47.5 -noconfout
```

The **only** change to the PLUMED input is one keyword on the `METAD` line so the
walkers share hills:

```plumed
METAD ... FILE=HILLS WALKERS_MPI      # <-- add WALKERS_MPI
```

Each `walkerX/` directory holds its own `topol.tpr` (and starting structure).
GROMACS gives each rank its own GPU automatically (rank0→gpu0, rank1→gpu1); each
walker runs the full PP+PME on its GPU. Scale to 4 walkers by
`--gpus=4 --ntasks=1 --cpus-per-task=40 -np 4 -multidir walker0 … walker3`.

> **Validated on Expanse** ([`bench/bench_multiwalker.sh`](bench/bench_multiwalker.sh),
> job 52094017): GROMACS mapped `PP:0,PME:0,PP:1,PME:1` — each walker fully on its
> own GPU, **both GPUs ~72% busy**; PLUMED's shared `HILLS` accumulated hills from
> *both* walkers (confirming `WALKERS_MPI` coupling), aggregate sampling ≈ 2×.

**Even simpler — N independent `--gpus=1` jobs.** If you don't need a *shared*
bias (e.g. independent replicas, or a CV/parameter sweep), just submit the
**1-GPU job N times** with [example 04](../04-batch-submitter/)'s loop. Identical
per-GPU efficiency, zero MPI, and each is the fast GPU-resident single-GPU run.

---

## 5 · "But could 2 GPUs ever help *my* system?"

Yes — for a **large** system (roughly **≳ 0.5–1 M atoms** on V100) whose one-GPU
run is genuinely GPU-bound, a PP\|PME split or PP-domain decomposition can win.
But two things usually kill it for metadynamics:

1. **Size.** ≤ a few hundred k atoms won't fill one V100; splitting only adds overhead.
2. **PLUMED.** The bias runs on CPU and caps throughput before GPUs matter.

So: **measure before you spend.** [`bench/bench_pme.sh`](bench/bench_pme.sh) is a
drop-in harness — point `TPR_S`/`TPR_B` at *your* `.tpr`, submit to `gpu-debug`,
and read the ns/day table. If (and only if) `2gpu > 1gpu` for your system do you
change your production header. For the mechanics of a single-job 2-GPU run (should
you need it), see [`metad_2gpu_singlejob.sh`](metad_2gpu_singlejob.sh).

---

## 6 · Files in this folder

| File | What it is |
|---|---|
| **`metad_multiwalker.sh`** | ⭐ **Recommended.** One job, N GPUs, N walkers (`-multidir` + `WALKERS_MPI`). Validated on Expanse. |
| `metad_2gpu_singlejob.sh` | The literal "2 GPUs on one trajectory" the question asked for — with the honest caveat and the exact `mdrun` flags. |
| `template_multigpu_header.sh` | Job-agnostic 2-GPU `#SBATCH` header + skeleton. |
| `bench/bench_pme.sh` | The atomistic-PME benchmark harness (1 vs 2 GPU, ± PLUMED, walkers). Re-point at your system. |
| `bench/bench_multiwalker.sh` | End-to-end validation of the `-multidir` + `WALKERS_MPI` recipe. |
| `bench/bench_multigpu.sh` | The first (CG-Martini) harness — kept because it shows the reaction-field-vs-PME gotcha (see below). |
| `bench/results/` | Raw `SUMMARY.txt` + `evidence.txt` (cycle accounting, GPU utilization). |

### Gotcha we hit: coarse-grained (Martini) systems don't use PME
The first benchmark used a CG Martini system and every `-pme gpu` config failed with
`PME GPU does not support systems that do not use PME for electrostatics`. Martini
uses **reaction-field**, not PME, so it never has a PME task to move to a second
GPU (its multi-GPU story is *only* PP domain decomposition, and CG systems are far
too small/cheap per step to benefit). The collaborator's **atomistic GAFF** job
*does* use PME — hence the PME water benchmark above. Know which regime you're in.

---

## 7 · Reproduce it

```bash
# 1. build the minimized PME benchmark systems once (login node, CPU, no GPU cost)
scp bench/build_pme_systems.sh expanse:~/expanse-bench/
ssh expanse 'bash ~/expanse-bench/build_pme_systems.sh'   # → PME-BENCH/water_{small,big}_em.tpr
# 2. run the benchmark on gpu-debug (~10 min)
scp bench/bench_pme.sh expanse:~/expanse-bench/
ssh expanse 'cd ~/expanse-bench && sbatch bench_pme.sh'
# results: /expanse/lustre/scratch/$USER/temp_project/BENCH-PME-<jobid>/SUMMARY.txt
# validate the recommended walkers recipe likewise with bench/bench_multiwalker.sh
```

All runs used `--partition=gpu-debug` (V100, 30-min cap, instant scheduling) on
account `wis192`. Production runs should use `gpu-shared` (48 h).
