# Python Environments on Expanse

We handle Python **two ways**. Know which one a script expects before you run it.

1. **Native conda/mamba** in home — quick, interactive, login-node work.
2. **Singularity containers** holding their own conda envs — reproducible, what our
   batch jobs use. **Preferred for anything submitted to the scheduler.**

---

## 1. Native conda / mamba (`~/.conda/envs`)

Our home conda envs:

| Env | Purpose |
|---|---|
| `masterclass` | pandas, numpy, scipy, scikit-learn, rdkit (analysis / DeepTICA) |
| `swarmcg` | SwarmCG, ACPYPE, MDAnalysis, rdkit (CG model optimization) |
| `dissolve` | DISSOLVE-related tooling |

Conda is **not** auto-initialized in `.bashrc`; load it via module first:

```bash
module load cpu/0.17.3b              # CPU software stack (lmod hierarchy)
module load anaconda3/2021.05        # provides conda
source activate masterclass         # or: conda activate masterclass
```

- Envs are stored under `~/.conda/envs` (set up once via the `.conda_envs_dir_test` marker).
- `mamba` is available (`~/.mamba`) as a faster drop-in for `conda install`.
- **Use this for light, interactive work on the login node** (quick analysis, plotting).
  For real compute, put it in a job — or better, use a container.

## 2. Singularity containers (the batch-job way)

Containers bundle GROMACS+PLUMED and/or conda envs so jobs are reproducible and don't
depend on home-dir state. Images live in scratch (they're large):

| Image | Contents |
|---|---|
| `deeptica-plumed_v1.sif` | GROMACS + PLUMED + PyTorch (DeepTICA MetaD & training) |
| `euler_0.0.sif` | GROMACS + PLUMED (surfactant pipeline MD) |
| `surfactant_envs.sif` | conda envs `swarmcg` + `masterclass` inside the container |

Load the runtime, then `exec` into the image:

```bash
module purge
module load singularitypro           # or singularitypro/4.1.2

SIF="/expanse/lustre/scratch/$USER/temp_project/deeptica-plumed_v1.sif"
CONTAINER="singularity exec --nv --bind /expanse,/home,/scratch ${SIF}"

${CONTAINER} gmx_mpi mdrun ...       # run GROMACS from the container
${CONTAINER} python3 train.py        # run Python from the container
```

Key flags:
- `--nv` — expose the NVIDIA GPU into the container (required for GPU jobs).
- `--bind /expanse,/home,/scratch` — make those host paths visible inside.
- `--cleanenv` — start from a clean environment (don't inherit host vars). Used when we
  want to guarantee the container's conda, not home's.

### Using a container's *internal* conda envs

When the env lives **inside** the image (e.g. `surfactant_envs.sif`), point conda at the
container's env dir so it ignores `~/.conda`:

```bash
singularity exec --cleanenv \
  --env CONDA_ENVS_DIRS=/opt/conda/envs \
  --env CONDA_PKGS_DIRS=/opt/conda/pkgs \
  --bind /expanse,/home \
  surfactant_envs.sif /opt/conda/bin/conda run -n masterclass python script.py
```

(See `examples/04-batch-submitter/pipeline_config.sh` — `PYTHON_CONTAINER` does exactly this.)

---

## Which to use?

- **Submitting a job?** → container. It's portable and survives env drift.
- **Quick login-node analysis?** → native conda is fine.
- **Don't mix them in one command.** `--cleanenv` exists precisely to stop the host conda
  from leaking into the container.

> ⚠️ Secret hygiene: our `~/.bashrc` currently exports an API key in plaintext. Don't
> copy secrets into committed scripts or this repo; prefer a `~/.config` file that isn't
> tracked, and rotate keys that have been exposed.
