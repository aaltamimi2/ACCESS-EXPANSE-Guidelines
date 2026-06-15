# Using SDSC Expanse — Practical Guide

A working guide to running jobs on **Expanse** (SDSC) the way we actually use it:
filesystems, Python environments, and — the core of this guide — how to write and
submit SLURM batch (`.sh`) scripts, built from our own real examples.

- **Account:** `wis192`  ·  **User:** `aaltamimi`  ·  **Login:** `ssh expanse` (lands on `login02`)
- All examples here are real scripts copied from Expanse. See the workflow notes below.

---

## ⭐ Start here: the canonical example

> **[`examples/01-gpu-metad-sweep/`](examples/01-gpu-metad-sweep/) is the first script to reference.**
> It is the cleanest, most representative job we run — a pure GPU MD/metadynamics
> production job (GROMACS + PLUMED in a Singularity container, staged to scratch).
> Read its walkthrough first; every other example is a variation on it.

The other examples build on it:

| # | Example | What it adds |
|---|---------|--------------|
| **01 ⭐** | [GPU MetaD sweep](examples/01-gpu-metad-sweep/) | **Reference job.** GPU + Singularity GROMACS/PLUMED, stage to scratch |
| 02 | [GPU ML training](examples/02-gpu-ml-training/) | Same skeleton, Python/PyTorch workload instead of MD |
| 03 | [GPU job w/ QOS + email](examples/03-gpu-qos-mail/) | `--qos`, `--mail-*`, Singularity TMPDIR/CACHEDIR env vars |
| 04 | [Batch submitter](examples/04-batch-submitter/) | A wrapper that loops and calls `sbatch` many times (not a job itself) |

Each example folder contains **three files**:

1. `*.sh` — the **original** script, exactly as it runs on Expanse.
2. `template.sh` — the same job stripped to the **`#SBATCH` header block + a commented skeleton** you fill in.
3. `README.md` — a line-by-line walkthrough.

A shared, job-agnostic header template lives in [`templates/base_sbatch_header.sh`](templates/base_sbatch_header.sh).

---

## How work flows: home → scratch → back

The part that actually matters is **where a job runs**, not where you type. A job's data
moves through three places:

```
inputs in /home  ─stage→  job runs in /expanse/lustre/scratch  ─copy→  results you keep
```

- **`/home`** holds your scripts and inputs — persistent and backed up, but slow and small.
- **`/expanse/lustre/scratch/.../temp_project`** is where the job actually computes — fast
  Lustre, **not backed up** (a purge policy exists but hasn't been biting — see
  [docs/01](docs/01-filesystems.md)). Our scripts make a per-job `WORKDIR` here (keyed on
  `${SLURM_JOB_ID}`) and `cd` into it.
- Since scratch isn't backed up, the job **copies results back** to `/home` (or you download
  them). Don't leave anything you care about *only* in scratch.

See [docs/01-filesystems.md](docs/01-filesystems.md) for the full breakdown.

### Editing scripts — a suggestion, not a rule

You *can* edit on Expanse (vim is there and fine for a quick tweak). But for anything
you want to keep, it's worth editing in a version-controlled copy (like this repo) and
copying up — so the script that produced a result isn't lost when scratch is purged or a
home file is overwritten. When you do copy, use **`scp`**, not `rsync` (see CLAUDE.md):

```bash
scp submit_sweep_S13.sh expanse:/home/aaltamimi/30CMC-CAMPAIGN/02-PRODUCTION/SDS/
ssh expanse
cd 30CMC-CAMPAIGN/02-PRODUCTION/SDS && sbatch submit_sweep_S13.sh
```

---

## Topic guides

- **[docs/01-filesystems.md](docs/01-filesystems.md)** — home vs scratch vs projects, quotas, purge policy, where to run.
- **[docs/02-python-environments.md](docs/02-python-environments.md)** — how we handle Python: native conda/mamba **and** Singularity containers.
- **[docs/03-slurm-and-sbatch.md](docs/03-slurm-and-sbatch.md)** — partitions, the `#SBATCH` header anatomy, submit/monitor/cancel, our aliases.

## 60-second quickstart

```bash
ssh expanse                                   # login02
cd /expanse/lustre/scratch/$USER/temp_project # or: cdscratch (alias)
module purge && module load singularitypro    # load what the job needs
sbatch my_job.sh                              # submit
squeue -u $USER                               # watch (alias: qq / qme)
scancel <jobid>                               # cancel
```
