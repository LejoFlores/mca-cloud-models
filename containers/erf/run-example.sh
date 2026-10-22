#!/bin/bash
# Small ERF regression cases from the ERF source tree, for checking an image end to end.
#   run-example.sh [case ...]     cases: radiation (RRTMGP + moisture), noahmp (Noah-MP), all (default)
# Ranks: NP (default 4). Steps: STEPS (default 20). Runs in $WORK (default /tmp/erf-examples).
set -uo pipefail
ERF=${ERF_SRC:-/opt/erf/src/ERF}/Exec; EXE=${ERF_EXE:-/opt/erf/bin/erf_exec}; DATA=${ERF_DATA:-/opt/erf/data}
NP=${NP:-4}; STEPS=${STEPS:-20}; WORK=${WORK:-/tmp/erf-examples}
LAUNCH=${LAUNCH:-mpirun --oversubscribe -np $NP}
cases=("$@"); [ ${#cases[@]} -eq 0 -o "${1:-}" = all ] && cases=(radiation noahmp)
fail=0
for c in "${cases[@]}"; do
  case $c in
    radiation) dir=RegTests/Radiation; inp=inputs_radiation ;;
    noahmp)    dir=RegTests/NoahMP_Ideal; inp=$(cd $ERF/$dir && ls inputs* | head -1) ;;
    *) echo "unknown case $c"; exit 2 ;;
  esac
  R=$WORK/$c; rm -rf $R; mkdir -p $R; cp -r $ERF/$dir/. $R/; cd $R
  cp -n $DATA/*.nc $DATA/NoahmpTable.TBL . 2>/dev/null
  start=$(date +%s%N)
  $LAUNCH $EXE $inp max_step=$STEPS erf.plot_int_1=$STEPS erf.check_int=-1 > run.log 2>&1; rc=$?
  t=$(( ($(date +%s%N) - start) / 1000000000 ))
  last=$(grep -E "^Coarse STEP|STEP [0-9]+ ends" run.log | tail -1)
  echo "== $c: exit $rc, $t s on $NP ranks; last: ${last:-none}"
  [ $rc -eq 0 ] && grep -q "STEP $STEPS" run.log || { fail=1; tail -n 30 run.log; }
done
[ $fail -eq 0 ] && echo "ERF EXAMPLES PASSED" || { echo "ERF EXAMPLES FAILED"; exit 1; }
