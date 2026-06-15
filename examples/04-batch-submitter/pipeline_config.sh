#!/bin/bash
# =============================================================================
# SURFACTANT PIPELINE CONFIGURATION
# =============================================================================
# Edit these settings to customize the pipeline for your environment.
# This file is sourced by all pipeline scripts.
# =============================================================================

# =============================================================================
# SLURM CONFIGURATION (Expanse)
# =============================================================================
SLURM_ACCOUNT="wis192"
SLURM_PARTITION="gpu-shared"
SLURM_QOS="gpu-shared-normal"
SLURM_NODES=1
SLURM_NTASKS=1
SLURM_CPUS=10
SLURM_MEM="8G"
SLURM_TIME_SWARMCG="24:00:00"    # SwarmCG optimization time
SLURM_TIME_EQUIL="04:00:00"      # Equilibration time
SLURM_TIME_METAD="120:00:00"     # Metadynamics time
SLURM_GPU=1
SLURM_EMAIL="aaltamimi2@wisc.edu"

# =============================================================================
# SCRATCH DIRECTORY SETUP (Expanse)
# =============================================================================
SCRATCH_BASE="/expanse/lustre/scratch/${USER}/temp_project"
SCRATCH_WORK="${SCRATCH_BASE}/surfactant-pipeline"
SCRATCH_IMG="${SCRATCH_BASE}/euler_0.0.sif"

# =============================================================================
# PYTHON ENVIRONMENTS (via Singularity container)
# =============================================================================
# Container with conda environments:
#   - swarmcg: Contains SwarmCG, ACPYPE, MDAnalysis, rdkit (numpy 1.24)
#   - masterclass: Contains pandas, numpy, scipy, scikit-learn, rdkit
PYTHON_CONTAINER_IMG="${SCRATCH_BASE}/surfactant_envs.sif"
# Use full path to container's conda and set CONDA_ENVS_DIRS to only use container environments
PYTHON_CONTAINER="singularity exec --cleanenv --env CONDA_ENVS_DIRS=/opt/conda/envs --env CONDA_PKGS_DIRS=/opt/conda/pkgs --bind /expanse,/home ${PYTHON_CONTAINER_IMG} /opt/conda/bin/conda"

# Environment names inside container
CONDA_SWARMCG_ENV="swarmcg"
CONDA_DEEPTICA_ENV="masterclass"

# =============================================================================
# SINGULARITY CONTAINER (for GROMACS+PLUMED on Expanse)
# =============================================================================
SINGULARITY_IMAGE="${SCRATCH_IMG}"
CONTAINER_CMD="singularity exec --nv --bind /expanse ${SINGULARITY_IMAGE}"
GMX="${CONTAINER_CMD} gmx_mpi"
PLUMED="${CONTAINER_CMD} plumed"

# =============================================================================
# PATHS
# =============================================================================
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTOMARTINI_DIR="${SCRATCH_WORK}/automartini_m3_filtered"
SURFPRO_CSV="${PIPELINE_DIR}/data/surfpro_processed.csv"

# Base system files (PE thin film with PEU binder)
BASE_SYSTEM_GRO="${PIPELINE_DIR}/topology/PE-PEUS-LONG-EQ-1us.gro"
BASE_SYSTEM_TOP="${PIPELINE_DIR}/topology"

# Output directories
WORK_DIR="${PIPELINE_DIR}/work"
RESULTS_DIR="${PIPELINE_DIR}/results"
LOCK_DIR="${PIPELINE_DIR}/lock"
LOGS_DIR="${PIPELINE_DIR}/logs"

# =============================================================================
# SURFACTANT SYSTEM PARAMETERS
# =============================================================================
CMC_MULTIPLIER=5              # CMC multiplier (e.g., 5x CMC)
MAX_SURFACTANTS=2300           # Maximum surfactant count (reduced for stability)
TEMPERATURE=310                # Simulation temperature (K)

# =============================================================================
# SWARMCG PARAMETERS
# =============================================================================
SWARMCG_MAX_ITERATIONS=100     # Max SwarmCG optimization iterations (uses default CG times)

# =============================================================================
# METADYNAMICS PARAMETERS
# =============================================================================
SIGMA_DZ="1.0"                 # Sigma for dZ CV
SIGMA_CONTACTS="0.1"           # Sigma for contacts CV
METAD_HEIGHT="1"               # Gaussian height (kJ/mol)
METAD_PACE="500"               # Deposition pace (steps)
METAD_BIASFACTOR=""            # Leave empty for standard metad

# =============================================================================
# ACTIVE LEARNING PARAMETERS
# =============================================================================
AL_ACQUISITION="ucb"           # Acquisition function: ucb, ei, or random
AL_EXPLORATION_WEIGHT=2.0      # UCB exploration weight (kappa)
AL_MIN_SAMPLES=10              # Minimum samples before using GP
AL_BATCH_SIZE=1                # Number of surfactants to select per round

# =============================================================================
# SYSTEM GEOMETRY (from base system)
# =============================================================================
BOX_Z_HALF="24.6525"           # Half box size in Z (nm)
FIRST_BEAD="17001"             # First bead for end-to-end distance
LAST_BEAD="17495"              # Last bead for end-to-end distance
CONTACTS_NORM_FACTOR="3000"    # Normalization for contacts CV

# =============================================================================
# RESIDUE DEFINITIONS
# =============================================================================
PE_RESNAME="PE"
BINDER_RESNAMES="PIS PUS PTS SWA"
WATER_RESNAMES="W SOL HOH WAT"
ION_RESNAMES="CL ION Cl NA Na BR Br K CA Mg"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*"
}

# Check if required command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command not found: $1"
        return 1
    fi
}

# Activate conda environment (sets PYTHON_CMD for subsequent use)
activate_conda() {
    local env_name="$1"
    # Use the Python container with conda run
    export CURRENT_CONDA_ENV="${env_name}"
    export PYTHON_CMD="${PYTHON_CONTAINER} run -n ${env_name} python3"
    export ACPYPE_CMD="${PYTHON_CONTAINER} run -n ${env_name} acpype"
    log_info "Activated conda environment: ${env_name} (via container)"
}

# Run Python script in container with specified environment
run_python() {
    local env_name="$1"
    shift
    ${PYTHON_CONTAINER} run -n "${env_name}" python3 "$@"
}

# Run command in container with specified environment
run_in_env() {
    local env_name="$1"
    shift
    ${PYTHON_CONTAINER} run -n "${env_name}" "$@"
}

# Load required modules for SLURM (Expanse)
load_modules() {
    module purge 2>/dev/null || true
    module load slurm 2>/dev/null || true
    module load gpu 2>/dev/null || true
    module load singularitypro/4.1.2 2>/dev/null || true
}

# Verify Python container exists
verify_python_container() {
    if [[ ! -f "${PYTHON_CONTAINER_IMG}" ]]; then
        log_error "Python container not found: ${PYTHON_CONTAINER_IMG}"
        return 1
    fi
    log_info "Python container verified: ${PYTHON_CONTAINER_IMG}"
    return 0
}

# Setup Singularity environment for Expanse
setup_singularity_env() {
    export SINGULARITY_TMPDIR="${SCRATCH_BASE}/sing_tmp"
    export SINGULARITY_CACHEDIR="${SCRATCH_BASE}/sing_cache"
    export TMPDIR="${SINGULARITY_TMPDIR}"
    mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

    # MPI temporary directories (prevent read-only filesystem errors)
    export OMPI_MCA_orte_tmpdir_base="${SINGULARITY_TMPDIR}"
    export OMPI_MCA_btl_vader_single_copy_mechanism=none
}

# Verify Singularity container exists
verify_container() {
    if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
        log_error "Container image not found: ${SINGULARITY_IMAGE}"
        log_error "Listing ${SCRATCH_BASE}:"
        ls -lh "${SCRATCH_BASE}" 2>/dev/null || true
        return 1
    fi
    # Verify SIF is readable
    singularity inspect -l "${SINGULARITY_IMAGE}" >/dev/null 2>&1 || {
        log_error "Container image not readable: ${SINGULARITY_IMAGE}"
        return 1
    }
    log_info "Container verified: ${SINGULARITY_IMAGE}"
    return 0
}

# Setup scratch working directory
setup_scratch_dirs() {
    mkdir -p "${SCRATCH_WORK}" "${SCRATCH_WORK}/logs" || {
        log_error "Failed to create scratch directories: ${SCRATCH_WORK}"
        return 1
    }
    # Force Lustre metadata sync
    sync
    sleep 0.5
    log_info "Scratch directories ready: ${SCRATCH_WORK}"
    return 0
}
