#!/bin/bash
# Runs INSIDE the ERF image (bench/erf_drycreek.sh starts it). Mirrors erf-borah run/erf_gpu.slurm.
#   erf_case.sh <run-name> <start> <end>
# /case/erf holds wrfinput_d01..d03 and wrfbdy_d01 (bench/stage_drycreek.sh, WPS + real.exe) and
# inputs_drycreek + namelist.erf copied from erf-borah setup/.
set -uo pipefail
RUN=/case/runs/$1; START=$2; END=$3
D=${ERF_DATA:-/opt/erf/data}
mkdir -p $RUN && cd $RUN
for f in wrfinput_d01 wrfinput_d02 wrfinput_d03 wrfbdy_d01; do ln -sfn /case/erf/$f .; done
sed -e "s|__START__|$START|" -e "s|__END__|$END|" /case/erf/inputs_drycreek > inputs
cp /case/erf/namelist.erf .
cp $D/NoahmpTable.TBL $D/rrtmgp-*.nc .
cp /opt/manifest.txt image_manifest.txt
ulimit -s unlimited 2>/dev/null || true       # Noah-MP's Fortran driver
if [ "${NGPU:-0}" -gt 0 ]; then
  RANKS=$NGPU
  nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv | tee gpu.txt
else
  RANKS=${NP:-$(nproc)}
fi
start=$(date +%s%N)
mpirun --oversubscribe -np $RANKS erf_exec inputs amrex.the_arena_init_size=0 > erf.out 2>&1; rc=$?
wall=$(( ($(date +%s%N) - start) / 1000000 ))
grep -E "STEP|Writing|rror" erf.out | tail -n 15
status=ok; [ $rc -eq 0 ] || status="failed(rc=$rc)"
printf 'WALL_MS=%s\nRANKS=%s\nSTATUS=%s\n' $wall $RANKS "$status" > result.env
cat result.env
