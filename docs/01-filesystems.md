# Filesystems: Home vs Scratch vs Projects

Expanse has three storage areas with very different purposes. Putting work in the
wrong place is the #1 cause of slow jobs and lost data.

## TL;DR

| | Path | Backed up? | Purged? | Speed | Use for |
|---|---|---|---|---|---|
| **Home** | `/home/aaltamimi` | ✅ yes | ❌ no | slow (NFS) | code, scripts, configs, small inputs |
| **Scratch** | `/expanse/lustre/scratch/aaltamimi/temp_project` | ❌ no | ✅ ~purged when idle | fast (Lustre parallel) | **run jobs here**, trajectories, big I/O |
| **Projects** | `/expanse/lustre/projects/<alloc>` | ❌ no | per-allocation | fast (Lustre) | data shared across the allocation |

**Rule of thumb:** *Keep* things in home, *compute* in scratch.

---

## Home — `/home/aaltamimi`

- NFS-mounted, **backed up**, modest quota (~100 GB). Persistent across the allocation.
- Slow for heavy parallel I/O — **never run an MD/training job directly in home.**
- What we keep here: submission scripts, pipeline code (`30CMC-CAMPAIGN/`,
  `SURFACTANT-PIPELINE/`), topology/`.itp` inputs, configs, the native conda envs (`~/.conda/envs`).
- Jobs **read** inputs from home, then stage them into scratch (see the examples).

> Tip: SLURM `.out`/`.err` files land in your submit directory. We submit from home, so
> these accumulate there — clean them periodically (lots of `slurm-*.err` build up fast).

## Scratch — `/expanse/lustre/scratch/aaltamimi/temp_project`

- Lustre parallel filesystem: **fast, large**, but **NOT backed up** and **purged** when
  files go untouched (Expanse policy is ~90 days). Treat everything here as disposable.
- This is where jobs actually run. Our scripts create a per-job working dir here:
  ```bash
  WORKDIR="/expanse/lustre/scratch/$USER/temp_project/METAD-...-${SLURM_JOB_ID}"
  mkdir -p "$WORKDIR" && cd "$WORKDIR"
  ```
  Using `${SLURM_JOB_ID}` keeps concurrent jobs from clobbering each other.
- Big container images (`.sif`) live here too, e.g.
  `deeptica-plumed_v1.sif`, `euler_0.0.sif`, `surfactant_envs.sif`.
- **Shortcut:** `cdscratch` (alias in our `.bashrc`) → `cd /expanse/lustre/scratch/$USER/temp_project`.

**Because scratch is purged: copy results you care about back to home or download them locally.**
Our jobs do this explicitly (`cp COLVAR_METAD HILLS_METAD ... "${RESULTS_DIR}/"`).

## Projects — `/expanse/lustre/projects/<allocation>`

- Lustre, allocation-scoped, persistent for the life of the allocation. Good for datasets
  shared by everyone on `wis192`. Same "not backed up" caveat as scratch.

---

## Checking usage

```bash
expanse-client user -r expanse   # allocation / SU balance (SDSC tool)
df -h /expanse/lustre/scratch/$USER
du -sh ~/* | sort -h             # what's eating your home quota
```
