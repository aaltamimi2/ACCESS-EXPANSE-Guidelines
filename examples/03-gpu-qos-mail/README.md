# Example 03 — GPU Job with QOS, Email & Singularity TMPDIR control

Same GPU-MD skeleton as the [reference job (01)](../01-gpu-metad-sweep/), with three
production niceties: a **`--qos`** line, **email notifications**, and **explicit control
of where Singularity writes temp/cache files**. It's also a fuller end-to-end job — it
builds the system, generates the index and PLUMED files, runs, and copies results back.

- **Original:** [`submit_SURF554_dt0.01.sh`](submit_SURF554_dt0.01.sh)
- **Template:** [`template.sh`](template.sh)
- **Source on Expanse:** `~/SURFACTANT-PIPELINE/submit_SURF554_dt0.01.sh`

## New header directives

```bash
#SBATCH --qos=gpu-shared-normal          # QOS tier for the partition
#SBATCH --output=logs/SURF554_metad_%j.out   # writes into logs/ — create it first!
#SBATCH --mail-type=END,FAIL             # email on completion / failure
#SBATCH --mail-user=aaltamimi2@wisc.edu
```

> ⚠️ Because `--output=logs/...`, the `logs/` directory **must exist before you `sbatch`**
> or the job fails immediately with no log to tell you why. `mkdir -p logs` first.

## The environment block — the real lesson here

```bash
module purge
module load slurm gpu singularitypro/4.1.2   # pinned version; 'gpu' loads the GPU stack

export SINGULARITY_TMPDIR="${SCRATCH_BASE}/sing_tmp"
export SINGULARITY_CACHEDIR="${SCRATCH_BASE}/sing_cache"
export TMPDIR="${SINGULARITY_TMPDIR}"
export OMPI_MCA_orte_tmpdir_base="${SINGULARITY_TMPDIR}"
export OMPI_MCA_btl_vader_single_copy_mechanism=none
export OMP_NUM_THREADS=10
```

Why it matters:
- **Singularity and `/tmp`** can fill the small node-local temp or your home quota. Pointing
  `SINGULARITY_TMPDIR` / `CACHEDIR` / `TMPDIR` at **scratch** avoids "no space left" failures.
- `OMPI_MCA_btl_vader_single_copy_mechanism=none` silences a common OpenMPI/CMA warning in
  containerized GROMACS.
- Pinned `singularitypro/4.1.2` → reproducible across module updates.

## Other things it demonstrates

- **Sourcing a shared config:** `source ${HOME}/SURFACTANT-PIPELINE/config/pipeline_config.sh`
  centralizes paths/SLURM settings (see [example 04](../04-batch-submitter/pipeline_config.sh)).
- **Idempotency:** it skips building the system if `NVT.tpr` already exists — safe to re-run.
- **`-bonded gpu`:** unlike example 01, this offloads bonded forces to the GPU too.
- **Results copied back** to `${PIPELINE_DIR}/results/${SURF_NAME}` with a `METAD_COMPLETED`
  marker file (used by the batch submitter to skip finished work).

## Run it

```bash
scp submit_SURF554_dt0.01.sh expanse:/home/aaltamimi/SURFACTANT-PIPELINE/
ssh expanse && cd SURFACTANT-PIPELINE && mkdir -p logs && sbatch submit_SURF554_dt0.01.sh
```
