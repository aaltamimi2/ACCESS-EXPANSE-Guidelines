# ⭐ Example 01 — GPU MetaD Sweep (the reference job)

**This is the first script to reference.** It's the cleanest, most representative job we
run on Expanse: a pure GPU **molecular dynamics / well-tempered metadynamics** production
run using **GROMACS + PLUMED inside a Singularity container**, staged to scratch. Every
other example in this guide is a variation on this skeleton — learn this one first.

- **Original:** [`submit_sweep_S13.sh`](submit_sweep_S13.sh) — runs as-is on Expanse.
- **Template:** [`template.sh`](template.sh) — header block + fill-in skeleton.
- **Source on Expanse:** `~/30CMC-CAMPAIGN/02-PRODUCTION/SDS/submit_sweep_S13.sh`

## What it does

A 2D WT-MetaD sweep (run "S13") for SDS, biasing along a 6-CV DeepTICA collective
variable. It freezes a TorchScript model, stages inputs from home into a fresh scratch
working directory, and runs 600 ns of GPU MD (`30,000,000` steps).

## The anatomy — the pattern to internalize

**1. Header** (lines 2–13): `gpu-shared`, 1 GPU, 10 cores, 40 G, 48 h, `account=wis192`.
The standard single-V100 request. `%j` in the log names = job id.

**2. Fail-fast + logging** (15–24): `set -euo pipefail`, then echo job id / date / host —
so a dead job's `.out` tells you *where* and *when* it died.

**3. Environment** (26–30): `module purge` → `module load singularitypro`, then build a
reusable `CONTAINER` command. `--nv` gives GPU access; `--bind /expanse,/home,/scratch`
exposes the host paths. Everything scientific runs *through* `${CONTAINER}`.

**4. Inputs live in `/home`** (32–36): model, `.tpr`, `.ndx` are read from the home
campaign dir — persistent, backed up.

**5. Work happens in scratch** (38–44): `WORKDIR=.../temp_project/METAD-...-${SLURM_JOB_ID}`.
Keying on `${SLURM_JOB_ID}` guarantees concurrent sweeps never collide.
`OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}` ties threading to the core request.

**6. Stage → run → report** (49–81):
- freeze the model into scratch,
- `cp` plumed/tpr/ndx into the working dir,
- `gmx_mpi mdrun` with `-nb gpu -bonded cpu -ntomp ${SLURM_CPUS_PER_TASK} -pin on`,
- list outputs at the end.

> **GPU offload choice:** `-nb gpu -bonded cpu` puts nonbonded on the GPU, bonded on CPU —
> a safe default on `gpu-shared`. Compare example 03, which uses `-bonded gpu`.

## Run it

```bash
# locally: edit, then push
scp submit_sweep_S13.sh expanse:/home/aaltamimi/30CMC-CAMPAIGN/02-PRODUCTION/SDS/
# on Expanse:
ssh expanse
cd 30CMC-CAMPAIGN/02-PRODUCTION/SDS
sbatch submit_sweep_S13.sh
qme                         # watch it
```

Outputs (`metad.*`, `COLVAR_METAD`, `HILLS_*`) end up in the scratch `WORKDIR`.
**Scratch is purged** — copy anything you want to keep back to `/home` or download it.

## Adapt it (use `template.sh`)

- Change `--job-name`, the `SYSTEM_DIR`/`PLUMED_FILE` paths, and `-nsteps`.
- Different surfactant/run → point at its `plumed_*.dat` and system dir.
- No ML CV? Delete the model-freeze block and the `MODEL_PATH` line.
