#!/bin/bash
#SBATCH --account=wis192
#SBATCH --partition=gpu-shared
#SBATCH --qos=gpu-shared-normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=10
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --gpus=1
#SBATCH --job-name=SURF554-metad
#SBATCH --output=logs/SURF554_metad_%j.out
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=aaltamimi2@wisc.edu

set -euo pipefail

SURF_NAME="SURF554"
SURF_INDEX="554"

echo "======================================================================"
echo "[Thu Jan 29 21:34:34 CST 2026] SURF554 METADYNAMICS - dt=0.01 ps"
echo "======================================================================"

# Source pipeline config
source ${HOME}/SURFACTANT-PIPELINE/config/pipeline_config.sh

# Load modules
module purge
module load slurm gpu singularitypro/4.1.2

SCRATCH_BASE="/expanse/lustre/scratch/${USER}/temp_project"
SINGULARITY_IMAGE="${SCRATCH_BASE}/euler_0.0.sif"

export SINGULARITY_TMPDIR="${SCRATCH_BASE}/sing_tmp"
export SINGULARITY_CACHEDIR="${SCRATCH_BASE}/sing_cache"
export TMPDIR="${SINGULARITY_TMPDIR}"
export OMPI_MCA_orte_tmpdir_base="${SINGULARITY_TMPDIR}"
export OMPI_MCA_btl_vader_single_copy_mechanism=none
export OMP_NUM_THREADS=10

mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

GMX="singularity exec --nv --bind /expanse ${SINGULARITY_IMAGE} gmx_mpi"
PIPELINE_DIR="${HOME}/SURFACTANT-PIPELINE"

# Setup directories
WORK_DIR="${PIPELINE_DIR}/work/${SURF_NAME}"
METAD_DIR="${SCRATCH_BASE}/surfactant-pipeline/${SURF_NAME}/metad"
SYSTEM_DIR="${WORK_DIR}/system"

mkdir -p "${SYSTEM_DIR}" "${METAD_DIR}"
cd "${METAD_DIR}"

echo "Working dir: ${METAD_DIR}"

# =============================================================================
# Step 1: Ensure optimized ITP is in topology folder
# =============================================================================

OPTIMIZED_ITP="${WORK_DIR}/swarmcg/swarmcg_output_${SURF_NAME}/optimized_CG_model/SURF554-CG-UO.itp"
TARGET_ITP="${PIPELINE_DIR}/topology/${SURF_NAME}-CG-OPTIMIZED.itp"

if [[ ! -f "${TARGET_ITP}" ]]; then
    echo "Copying optimized ITP to topology folder..."
    # Convert residue name from SUR to SUR if needed, and molecule name
    sed 's/^554  /SUR  /; s/moleculetype/moleculetype ; ${SURF_NAME}/' "${OPTIMIZED_ITP}" > "${TARGET_ITP}"
fi

# =============================================================================
# Step 2: Build system if not exists
# =============================================================================

if [[ ! -f "${SYSTEM_DIR}/NVT.tpr" ]]; then
    echo "System not built yet. Running build script..."
    cd ${PIPELINE_DIR}
    ./03-build_system.sh --index ${SURF_INDEX} --surf-type cationic --counterion CL
    
    if [[ ! -f "${SYSTEM_DIR}/NVT.tpr" ]]; then
        echo "ERROR: System build failed"
        exit 1
    fi
    cd "${METAD_DIR}"
fi

# =============================================================================
# Step 3: Run metadynamics with dt=0.01 ps
# =============================================================================

echo ""
echo "Setting up metadynamics..."

# Copy required files
cp "${PIPELINE_DIR}/MDP/metad_dt0.01.mdp" metad.mdp
cp "${SYSTEM_DIR}/system.top" ./
cp "${SYSTEM_DIR}/NVT.tpr" ./system.tpr
cp "${SYSTEM_DIR}/system_equilibrated.gro" ./system.gro 2>/dev/null ||     cp "${SYSTEM_DIR}/NVT.gro" ./system.gro

# Copy topology files
for f in "${PIPELINE_DIR}/topology/"*.itp; do
    [[ -f "$f" ]] && cp "$f" ./
done

# Get box size for PLUMED
BOX_Z=$(tail -1 system.gro | awk '{print $3}')
BOX_Z_HALF=$(echo "${BOX_Z}/2" | bc -l | xargs printf "%.4f")
echo "Box Z: ${BOX_Z} nm, Half: ${BOX_Z_HALF} nm"

# =============================================================================
# Generate comprehensive index file
# =============================================================================

echo "Creating index file..."

# Create basic groups first
${GMX} make_ndx -f system.gro -o metad_temp.ndx << EOF
q
EOF

# Use select for more specific groups
${GMX} select -s system.tpr -f system.gro -on metad.ndx -select "
group \"System\";
resname PE;
resname PIS or resname PUS or resname PTS or resname SWA;
resname SUR;
resname W;
resname CL or resname NA or resname ION
" 2>/dev/null || {
    echo "Warning: select failed, using basic make_ndx"
    ${GMX} make_ndx -f system.gro -o metad.ndx << EOF
q
EOF
}

# =============================================================================
# Generate PLUMED file
# =============================================================================

echo "Creating PLUMED file..."

cat > plumed.dat << PLUMED_EOF
UNITS LENGTH=nm ENERGY=kj/mol TIME=ps

# Group definitions from index file
PE: GROUP NDX_FILE=metad.ndx NDX_GROUP=PE
LIG: GROUP NDX_FILE=metad.ndx NDX_GROUP=Binder
SURF: GROUP NDX_FILE=metad.ndx NDX_GROUP=Surfactant
HOH: GROUP NDX_FILE=metad.ndx NDX_GROUP=W

WHOLEMOLECULES ENTITY0=PE,LIG,SURF

# Centers of mass
COM_PE: COM ATOMS=PE
COM_LIG: COM ATOMS=LIG

# Polymer descriptors
rg_lig: GYRATION TYPE=RADIUS ATOMS=LIG
uwall_rg: UPPER_WALLS ARG=rg_lig AT=10.0 KAPPA=1000.0 EXP=2

# Distance from PE surface (Z-component)
dist_components: DISTANCE ATOMS=COM_LIG,COM_PE COMPONENTS
dZ_FULL: COMBINE ARG=dist_components.z PERIODIC=-${BOX_Z_HALF},${BOX_Z_HALF}

# PE-Binder contacts
contacts_BOTH: COORDINATION GROUPA=LIG GROUPB=PE R_0=0.6 NN=6 MM=12
contacts_NORM_BOTH: MATHEVAL ARG=contacts_BOTH FUNC=x/3000 PERIODIC=NO

# Surfactant-binder contacts
CONTACTS_SURF_BINDER: COORDINATION GROUPA=SURF GROUPB=LIG R_0=0.55 NN=6 MM=12 NLIST NL_CUTOFF=0.80 NL_STRIDE=500
CONTACTS_BINDER_WAT: COORDINATION GROUPA=LIG GROUPB=HOH R_0=0.5 NN=6 MM=12 NLIST NL_CUTOFF=0.8 NL_STRIDE=500

# Metadynamics
metad: METAD ...
    ARG=dZ_FULL,contacts_NORM_BOTH
    PACE=500
    HEIGHT=1
    SIGMA=1.0,0.1
    GRID_MIN=-${BOX_Z_HALF},0
    GRID_MAX=${BOX_Z_HALF},1
    GRID_BIN=200,100
    CALC_RCT
    FILE=HILLS_METAD
...

# Output
PRINT STRIDE=50 FILE=COLVAR_METAD ARG=* FMT=%12.6f
DUMPMASSCHARGE FILE=mcfile
ENDPLUMED
PLUMED_EOF

# =============================================================================
# Prepare TPR
# =============================================================================

echo "Creating TPR file..."
${GMX} grompp -f metad.mdp -c system.gro -r system.gro -p system.top -n metad.ndx -o metad.tpr -maxwarn 2

# =============================================================================
# Run metadynamics
# =============================================================================

echo ""
echo "======================================================================"
echo "[Thu Jan 29 21:34:34 CST 2026] Starting metadynamics with dt=0.01 ps..."
echo "======================================================================"

${GMX} mdrun -v -deffnm metad -plumed plumed.dat \
    -nb gpu -bonded gpu -ntomp ${OMP_NUM_THREADS} 2>&1

# =============================================================================
# Copy results
# =============================================================================

RESULTS_DIR="${PIPELINE_DIR}/results/${SURF_NAME}"
mkdir -p "${RESULTS_DIR}"
cp COLVAR_METAD HILLS_METAD plumed.dat metad.ndx "${RESULTS_DIR}/" 2>/dev/null || true
cp metad.xtc metad.gro "${RESULTS_DIR}/" 2>/dev/null || true

echo "METAD completed: Thu Jan 29 21:34:34 CST 2026" >> "${RESULTS_DIR}/METAD_COMPLETED"

echo ""
echo "======================================================================"
echo "[Thu Jan 29 21:34:34 CST 2026] COMPLETE: ${SURF_NAME}"
echo "======================================================================"
