# SLURM & the `#SBATCH` Header

Expanse uses **SLURM**. A batch job is a `.sh` script whose top lines are `#SBATCH`
directives (read by the scheduler), followed by ordinary bash that runs on the compute node.

## Partitions we use

| Partition | Hardware | Notes |
|---|---|---|
| `gpu-shared` | fraction of a 4×V100 node (1 GPU) | **Our default.** Cheaper, faster to schedule |
| `gpu` | full GPU node (4 GPUs) | only when you truly need 4 GPUs |
| `shared` | fraction of a 128-core CPU node | CPU-only work |
| `compute` | full 128-core CPU node | large CPU-only / MPI jobs |
| `debug` / `gpu-debug` | short, fast turnaround | quick tests |

Every job needs `--account=wis192`. GPU jobs request `--gpus=1` on `gpu-shared`.

## Anatomy of the header

From our reference job (`examples/01-gpu-metad-sweep/`):

```bash
#!/bin/bash
#SBATCH --job-name=SWP-S13-SDS       # name shown in squeue
#SBATCH --partition=gpu-shared       # queue (see table)
#SBATCH --nodes=1                    # nodes (1 for shared partitions)
#SBATCH --ntasks=1                   # MPI tasks
#SBATCH --cpus-per-task=10           # CPU cores; ~10 per GPU on gpu-shared
#SBATCH --mem=40G                    # RAM
#SBATCH --gpus=1                     # GPUs (gpu-shared = 1)
#SBATCH --time=48:00:00              # walltime HH:MM:SS (hard kill at limit)
#SBATCH --output=slurm-...-%j.out    # stdout; %j = job id
#SBATCH --error=slurm-...-%j.err     # stderr
#SBATCH --account=wis192             # REQUIRED: allocation to charge
#SBATCH --export=ALL                 # pass current env to the job
```

Optional directives we use elsewhere (`examples/03-gpu-qos-mail/`):

```bash
#SBATCH --qos=gpu-shared-normal      # quality-of-service tier
#SBATCH --mail-type=END,FAIL         # email on finish/fail
#SBATCH --mail-user=aaltamimi2@wisc.edu
```

### Sizing on `gpu-shared`
One V100 ⇒ request **`--gpus=1`, `--cpus-per-task=10`**, and memory to match
(`16–64G` typical). Asking for far more cores/RAM per GPU than the node ratio allows
makes the job wait longer (or never schedule).

### Body conventions we follow
- `set -euo pipefail` right after the header — fail fast on errors/unset vars.
- Echo `${SLURM_JOB_ID}`, `$(date)`, `$(hostname)` at the top for debuggable logs.
- `export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}` so threading matches the request.
- Create a scratch `WORKDIR` keyed on `${SLURM_JOB_ID}`, `cd` in, run, copy results out.

## Submit, monitor, cancel

```bash
sbatch my_job.sh                 # submit -> prints job id
squeue -u $USER                  # your queue
scancel <jobid>                  # cancel one
scancel -u $USER                 # cancel all yours
sacct -j <jobid> --format=JobID,State,Elapsed,MaxRSS,ReqMem   # post-mortem
sinfo -p gpu-shared              # partition availability
```

### Our shell aliases (`~/.bashrc`)

```bash
qq      # squeue -u $USER
qme     # squeue -u $USER, compact format (id/part/name/state/time/nodes/reason)
qprio   # pending gpu-shared jobs sorted by priority (where am I in line?)
qgpu    # gpu-shared nodes that are mix/idle (any GPUs free right now?)
```

## Quick reference: useful `SLURM_*` env vars (inside the job)

| Var | Meaning |
|---|---|
| `$SLURM_JOB_ID` | job id — use it to name unique scratch dirs |
| `$SLURM_CPUS_PER_TASK` | cores granted — feed to `-ntomp` / `OMP_NUM_THREADS` |
| `$SLURM_SUBMIT_DIR` | dir you ran `sbatch` from |
| `$SLURM_JOB_NODELIST` | nodes assigned |
