# Example 02 — GPU ML Training (containerized Python)

Same skeleton as the [reference job (01)](../01-gpu-metad-sweep/), but the workload is a
**PyTorch training run**, not GROMACS. It shows that "running Python on a GPU node" is the
*same recipe* as running MD — only the final command changes.

- **Original:** [`submit_full_model_30cmc.sh`](submit_full_model_30cmc.sh)
- **Template:** [`template.sh`](template.sh)
- **Source on Expanse:** `~/30CMC-CAMPAIGN/submit_full_model_30cmc.sh`

## What it does

Trains the DeepTICA "full" model (all 8 surfactants) across 8 lag times in one job,
inside the `deeptica-plumed_v1.sif` container.

## What's the same as example 01

- Identical `#SBATCH` header except `--mem=64G` (training is memory-hungrier than this MD).
- `module purge` → `singularitypro`, same `CONTAINER` wrapper with `--nv`.
- Per-job directory keyed on `${SLURM_JOB_ID}`; copy results out afterward.

## What's different

- **Output dir, not workdir.** It makes `OUTPUT_DIR` in scratch and `cd`s there.
- **Script provenance.** It copies `train_deeptica_6cv_30cmc.py` *into* the output dir
  before running — so each run keeps the exact code that produced it. Good habit.
- **The run line is Python:**
  ```bash
  ${CONTAINER} python3 train_deeptica_6cv_30cmc.py \
      --data-dir ${DATA_DIR} --output-dir deeptica_6cv_30cmc_full --mode full
  ```
- **Data is read from scratch** (`.../temp_project/30CMC-CAMPAIGN/01-TRAINING`), because
  the COLVAR datasets are large — keep big inputs on Lustre, not home.

## Run it

```bash
scp submit_full_model_30cmc.sh expanse:/home/aaltamimi/30CMC-CAMPAIGN/
ssh expanse && cd 30CMC-CAMPAIGN && sbatch submit_full_model_30cmc.sh
```

## Note on Python environments

This job uses the **container's** Python — the portable choice for batch jobs. If you
instead wanted the native `masterclass` conda env, you'd `module load anaconda3` and
`conda activate masterclass` here (see [docs/02-python-environments.md](../../docs/02-python-environments.md)),
but the container is preferred for anything submitted to the scheduler.
