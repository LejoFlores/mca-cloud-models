#!/bin/bash
# Runs INSIDE the SCHNAPS image (bench/schnaps_drycreek.sh starts it). Mirrors schnaps-borah
# run/drycreek_storm.slurm and run/drycreek_storm_gpu.slurm.
#   schnaps_case.sh <run-name> <namelist> <start> <end>
# /case holds the staged case (bench/stage_drycreek.sh): schnaps/domains, schnaps/<namelist>.nml,
# schnaps/forcing/hrrr_*.nc. Writes /case/runs/<run-name>/result.env for the host script.
set -uo pipefail
RUN=/case/runs/$1; NML=$2; START=$3; END=$4
S=${SCHNAPS_SRC:-/opt/schnaps/src/SCHNAPS}
mkdir -p $RUN/input $RUN/output $RUN/restart
ln -sfn /case/schnaps/domains $RUN/domains          # namelists point at ../domains/*.nc
cp /case/schnaps/$NML.nml $RUN/input/
sed -i -e "s/^\( *start_date *= *\)'[^']*'/\1'$START'/" -e "s/^\( *end_date *= *\)'[^']*'/\1'$END'/" $RUN/input/$NML.nml
# Forcing list: the staged hours, with in-container paths, quoted as hrrr_forcing.py writes them
ls /case/schnaps/forcing/hrrr_*.nc | sed 's/.*/"&"/' > $RUN/input/file_list_hrrr.txt
cp $S/run/*.TBL $RUN/input/
for d in mp_support rrtmg_support rrtmgp_support; do ln -sfn $S/run/$d $RUN/input/$d; done
cp /opt/manifest.txt $RUN/image_manifest.txt
cd $RUN/input
export OMP_NUM_THREADS=1
ulimit -s unlimited 2>/dev/null || true
if [ "${NGPU:-0}" -gt 0 ]; then
  EXE=SCHNAPS_gpu; RANKS=$((NGPU + 1))     # one compute rank per GPU + the I/O rank SCHNAPS keeps per node
  nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv | tee $RUN/gpu.txt
  BIND=(--bind-to none)
else
  EXE=SCHNAPS; RANKS=$(( ${NP:-$(nproc)} ))   # NP includes the I/O rank, as Borah's 33 = 32 + 1
  BIND=()
fi
$S/bin/$EXE --check-nml $NML.nml | tail -3
start=$(date +%s%N)
mpirun -np $RANKS "${BIND[@]}" $S/bin/$EXE $NML.nml > $NML.out 2> $NML.err; rc=$?
wall=$(( ($(date +%s%N) - start) / 1000000 ))
grep -v "n^2 search" $NML.out | tail -n 15; tail -n 10 $NML.err
nout=$(ls $RUN/output | wc -l)
status=ok; [ $rc -eq 0 ] && [ $nout -gt 0 ] || status="failed(rc=$rc,outputs=$nout)"
printf 'WALL_MS=%s\nRANKS=%s\nSTATUS=%s\nEXE=%s\n' $wall $RANKS "$status" $EXE > $RUN/result.env
cat $RUN/result.env
