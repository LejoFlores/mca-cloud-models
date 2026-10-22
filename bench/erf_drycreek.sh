#!/bin/bash
# ERF benchmark: Dry Creek Dec 2015, the wettest 12 h (2015-12-18 18Z to 2015-12-19 06Z), 1 km ->
# 250 m -> 50 m static refinement (erf-borah setup/inputs_drycreek). Appends to bench/results/erf.csv.
#
#   CASE_DIR=/data/drycreek IMAGE=erf:5fa15bd-cuda12.4-sm80 NGPU=1 bench/erf_drycreek.sh
#   CASE_DIR=/data/drycreek IMAGE=erf:5fa15bd-cpu NP=32 bench/erf_drycreek.sh
#   IMAGE=erf:5fa15bd-cpu CASE=smoke bench/erf_drycreek.sh   # 20-step RRTMGP regression test only
#
# Stage CASE_DIR first with bench/stage_drycreek.sh (it needs the WPS image and WPS static data).
set -euo pipefail
source "$(dirname "$0")/common.sh"
: "${IMAGE:?set IMAGE}"
CASE=${CASE:-drycreek}
START=${START:-2015-12-18 18:00:00}; END=${END:-2015-12-19 06:00:00}
[ "$NGPU" -gt 0 ] || NP=${NP:-$(physical_cores)}
TAG=$([ "$NGPU" -gt 0 ] && echo ${NGPU}gpu || echo ${NP}cpu)-$(date -u +%Y%m%dT%H%M%S)
if [ "$CASE" = smoke ]; then
  # Harness check, not a benchmark: ERF's Radiation regression test (dt = 1 s), 20 steps.
  CASE_DIR=${CASE_DIR:-$(mktemp -d)}; CASE_DIR=$(cd "$CASE_DIR" && pwd); mkdir -p "$CASE_DIR/runs/erf-smoke-$TAG"
  t0=$(date +%s%N)
  if run_in_image "$CASE_DIR" env NP=${NP:-1} STEPS=20 WORK=/case/runs/erf-smoke-$TAG /opt/erf/run-example.sh radiation; then
    st=ok; else st=failed; fi
  wall=$(python3 -c "print(($(date +%s%N) - $t0) / 1e9)")
  write_row erf erf_regtest_radiation_20steps "${NP:-$NGPU}" "$(python3 -c 'print(20/3600)')" "$wall" "$st" \
    "harness smoke test incl. container start; not a benchmark"
  exit 0
fi
: "${CASE_DIR:?set CASE_DIR (staged by bench/stage_drycreek.sh)}"
SIMH=$(python3 -c "import datetime as d; f='%Y-%m-%d %H:%M:%S'; print((d.datetime.strptime('$END',f)-d.datetime.strptime('$START',f)).total_seconds()/3600)")
NAME=erf-$TAG
CASE_DIR=$(cd "$CASE_DIR" && pwd); mkdir -p "$CASE_DIR/runs"
for f in wrfinput_d01 wrfinput_d02 wrfinput_d03 wrfbdy_d01 inputs_drycreek namelist.erf; do
  [ -f "$CASE_DIR/erf/$f" ] || { echo "missing $CASE_DIR/erf/$f; run bench/stage_drycreek.sh"; exit 1; }
done
run_in_image "$CASE_DIR" /bench/inner/erf_case.sh "$NAME" "$START" "$END" || true
R="$CASE_DIR/runs/$NAME/result.env"
[ -f "$R" ] || { echo "no $R: the run did not start"; exit 1; }
source "$R"
write_row erf drycreek_dec2015_12h_1km-250m-50m "$RANKS" "$SIMH" "$(python3 -c "print($WALL_MS/1000)")" "$STATUS" "$START..$END run=$NAME"
[ "$STATUS" = ok ]
