#!/bin/bash
# =============================================================================
# Build the atomistic PME benchmark systems used by bench_pme.sh.
# Run ON A LOGIN NODE (CPU only, ~2 min) — solvate + energy-minimize two TIP3P
# water boxes so they don't blow up at step 0. Produces:
#   PME-BENCH/water_small_em.tpr   (50,859 atoms)
#   PME-BENCH/water_big_em.tpr     (191,226 atoms)
# Engine: euler_0.0.sif = GROMACS 2021.5 + PLUMED 2.8.0.
#
# Why water+PME: it exercises the PP/PME GPU split that governs atomistic
# (GAFF) multi-GPU MD. A CG Martini system uses reaction-field (no PME) and
# cannot test this — every `-pme gpu` config errors out.
# =============================================================================
set -uo pipefail
module load singularitypro
SC="/expanse/lustre/scratch/${USER}/temp_project"
SIF="${SC}/euler_0.0.sif"
GMX="/usr/local/gromacs_2021.5/bin/gmx"                       # thread-MPI (no PLUMED needed to build)
RUN="singularity exec --bind /expanse,/home,/scratch ${SIF}"  # NB: must bind /expanse
B="${SC}/PME-BENCH"; mkdir -p "${B}"; cd "${B}"

# production mdp: PME, rigid TIP3P (settle), GPU-update compatible (v-rescale, no pcoupl)
cat > bench.mdp <<'MDP'
integrator=md
nsteps=500000
dt=0.002
nstlist=20
cutoff-scheme=Verlet
coulombtype=PME
rcoulomb=1.0
rvdw=1.0
vdwtype=Cut-off
fourier-spacing=0.12
pme-order=4
tcoupl=v-rescale
tc-grps=System
tau-t=1.0
ref-t=300
pcoupl=no
constraints=none
gen-vel=yes
gen-temp=300
MDP
cat > em.mdp <<'MDP'
integrator=steep
nsteps=3000
emtol=200
emstep=0.01
nstlist=20
cutoff-scheme=Verlet
coulombtype=PME
rcoulomb=1.0
rvdw=1.0
MDP

build () { # $1=label $2=box(nm)
  local lab=$1 L=$2
  printf '#include "amber99sb-ildn.ff/forcefield.itp"\n#include "amber99sb-ildn.ff/tip3p.itp"\n[ system ]\nwater %s\n[ molecules ]\n' "$lab" > topol_$lab.top
  $RUN $GMX solvate -cs spc216.gro -box $L $L $L -o conf_$lab.gro -p topol_$lab.top
  $RUN $GMX grompp -f em.mdp -c conf_$lab.gro -p topol_$lab.top -o em_$lab.tpr -maxwarn 5
  $RUN $GMX mdrun -deffnm em_$lab -ntmpi 1 -ntomp 32 -nb cpu -pme cpu     # minimize (CPU)
  $RUN $GMX grompp -f bench.mdp -c em_$lab.gro -p topol_$lab.top -o water_${lab}_em.tpr -maxwarn 5
  echo "built water_${lab}_em.tpr"
}
build small 8       # ~50k atoms
build big   12.5    # ~190k atoms
ls -lh water_*_em.tpr
