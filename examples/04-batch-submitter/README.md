# Example 04 — Batch Submitter (many jobs from one command)

Unlike examples 01–03, **this is not a SLURM job.** It's a script you run **on the login
node** that loops over a list and calls `sbatch` once per item. This is how we launch a
whole campaign (e.g. 22 surfactants) without hand-submitting each one.

- **Original:** [`00-batch_submit.sh`](00-batch_submit.sh)
- **Shared config it sources:** [`pipeline_config.sh`](pipeline_config.sh)
- **Template:** [`template.sh`](template.sh)
- **Source on Expanse:** `~/SURFACTANT-PIPELINE/00-batch_submit.sh`

## How you run it

```bash
ssh expanse && cd SURFACTANT-PIPELINE
./00-batch_submit.sh --indices 522,488,362     # NOTE: no `sbatch` in front
./00-batch_submit.sh --all-selected --dry-run  # preview without submitting
```

It then issues `sbatch ... 00-pipeline_master.sh --index <i>` for each item.

## The patterns worth copying

**1. Input flexibility.** Accepts `--indices a,b,c`, `--indices-file file.txt`, or
`--all-selected` (a hardcoded list of 22). Comma-splitting:
```bash
IFS=',' read -ra INDEX_LIST <<< "${INDICES}"
```

**2. `--dry-run`.** Prints the exact `sbatch` commands without submitting — always sanity-check
a big batch this way first.

**3. Skip-guards (idempotency).** Before submitting each item it checks for a completion
marker and a lock file, so re-running the batch only submits what's left:
```bash
[[ -f "${RESULTS_DIR}/${SURF_NAME}/COMPLETED" ]] && continue   # already done
[[ -f "${LOCK_DIR}/${SURF_NAME}.lock" ]] && continue           # already running
```
(This pairs with the `METAD_COMPLETED` marker that [example 03](../03-gpu-qos-mail/) writes.)

**4. Throttling.** `sleep ${DELAY}` between submissions so you don't hammer the scheduler.

**5. Capture job IDs.** Parse `sbatch` output to record ids, then print a ready-made
`scancel` line to kill the whole batch:
```bash
JOB_ID=$(echo "${JOB_OUTPUT}" | grep -oE '[0-9]+' | tail -1)
# ...
echo "Cancel all with: scancel ${JOB_IDS[*]%%:*}"
```

**6. Shared config.** It sources [`pipeline_config.sh`](pipeline_config.sh), which centralizes
account/partition/QOS, scratch paths, and container images so every script agrees. Editing
one file re-points the whole pipeline.

## When to use this vs. a job array

This wrapper submits **independent jobs** (each with its own multi-step pipeline and guards),
which is more flexible than a SLURM job array. Reach for `--array` only when the items are
truly uniform and you don't need per-item skip logic.
