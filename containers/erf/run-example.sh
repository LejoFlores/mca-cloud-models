#!/bin/bash
# Small ERF regression cases from the ERF source tree, for checking an image end to end.
#   run-example.sh [case ...]     cases: radiation (RRTMGP + moisture), noahmp (Noah-MP), all (default)
#   radiation: NP ranks (default 4), STEPS steps (default 20), with the 2018 RRTMGP coefficient files
#              ERF ships (the test's own inputs name rrtmgp-gas-*.nc files that are not in the tree)
#   noahmp:    as the case's README runs it: 1 rank, 2 steps (a 4 x 4 column)
# Runs in $WORK (default /tmp/erf-examples).
set -uo pipefail
ERF=${ERF_SRC:-/opt/erf/src/ERF}/Exec; EXE=${ERF_EXE:-/opt/erf/bin/erf_exec}; DATA=${ERF_DATA:-/opt/erf/data}
NP=${NP:-4}; STEPS=${STEPS:-20}; WORK=${WORK:-/tmp/erf-examples}
cases=("$@"); [ ${#cases[@]} -eq 0 -o "${1:-}" = all ] && cases=(radiation noahmp)
fail=0
for c in "${cases[@]}"; do
  case $c in
    radiation) dir=RegTests/Radiation; inp=inputs_radiation; np=$NP; n=$STEPS
               extra=(erf.rrtmgp_coeffs_sw=rrtmgp-data-sw-g224-2018-12-04.nc
                      erf.rrtmgp_coeffs_lw=rrtmgp-data-lw-g256-2018-12-04.nc) ;;
    noahmp)    dir=RegTests/NoahMP_Ideal; inp=inputs_noahmp_ideal; np=1; n=2; extra=() ;;
    *) echo "unknown case $c"; exit 2 ;;
  esac
  R=$WORK/$c; rm -rf $R; mkdir -p $R; cp -r $ERF/$dir/. $R/; cd $R
  cp -n $DATA/*.nc $DATA/NoahmpTable.TBL . 2>/dev/null
  start=$(date +%s%N)
  ${LAUNCH:-mpirun --oversubscribe -np $np} $EXE $inp max_step=$n erf.plot_int_1=$n erf.check_int=-1 "${extra[@]}" \
    > run.log 2>&1; rc=$?
  t=$(( ($(date +%s%N) - start) / 1000000000 ))
  last=$(grep -E "^Coarse STEP|STEP [0-9]+ ends" run.log | tail -1)
  echo "== $c: exit $rc, $t s on $np ranks, $n steps; last: ${last:-none}"
  [ $rc -eq 0 ] && grep -q "STEP $n" run.log || { fail=1; tail -n 30 run.log; }
done
[ $fail -eq 0 ] && echo "ERF EXAMPLES PASSED" || { echo "ERF EXAMPLES FAILED"; exit 1; }
