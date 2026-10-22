#!/bin/bash
# SCHNAPS benchmark: Dry Creek Dec 2015, the wettest 12 h (2015-12-18 18Z to 2015-12-19 06Z, the
# window erf-borah uses), on the schnaps-borah grids. Appends one row to bench/results/schnaps.csv.
#
#   CASE_DIR=/data/drycreek IMAGE=schnaps:1.1.1-gpu-cuda12.4 NGPU=1 bench/schnaps_drycreek.sh
#   CASE_DIR=/data/drycreek IMAGE=schnaps:1.1.1-cpu NP=33 bench/schnaps_drycreek.sh
#
# VARIANT  50m  (default) d01 1 km + d02 250 m + d03 50 m, Noah-MP snow (drycreek_dec2015_50m_noahmp),
#               the same footprint as the ERF levels; stays on the GPU end to end
#          250m d01 1 km + d02 250 m, SNOWPACK (drycreek_dec2015), the case behind the 13 sim-h/wall-h
#               Borah CPU number in cost/cost_model.py
# Stage CASE_DIR first with bench/stage_drycreek.sh. See common.sh for RUNTIME, PRICE_*, INSTANCE.
set -euo pipefail
source "$(dirname "$0")/common.sh"
: "${CASE_DIR:?set CASE_DIR (staged by bench/stage_drycreek.sh)}"; : "${IMAGE:?set IMAGE}"
VARIANT=${VARIANT:-50m}
START=${START:-2015-12-18 18:00:00}; END=${END:-2015-12-19 06:00:00}
case $VARIANT in
  50m)  NML=drycreek_dec2015_50m_noahmp ;;
  250m) NML=drycreek_dec2015 ;;
  *) echo "VARIANT must be 50m or 250m"; exit 2 ;;
esac
[ "$NGPU" -gt 0 ] || NP=${NP:-$(physical_cores)}
SIMH=$(python3 -c "import datetime as d; f='%Y-%m-%d %H:%M:%S'; print((d.datetime.strptime('$END',f)-d.datetime.strptime('$START',f)).total_seconds()/3600)")
NAME=schnaps-$VARIANT-$([ "$NGPU" -gt 0 ] && echo ${NGPU}gpu || echo ${NP}cpu)-$(date -u +%Y%m%dT%H%M%S)
CASE_DIR=$(cd "$CASE_DIR" && pwd); mkdir -p "$CASE_DIR/runs"
run_in_image "$CASE_DIR" /bench/inner/schnaps_case.sh "$NAME" "$NML" "$START" "$END" || true
R="$CASE_DIR/runs/$NAME/result.env"
[ -f "$R" ] || { echo "no $R: the run did not start"; exit 1; }
source "$R"
write_row schnaps "drycreek_dec2015_12h_$VARIANT" "$RANKS" "$SIMH" "$(python3 -c "print($WALL_MS/1000)")" "$STATUS" "$EXE $START..$END run=$NAME"
[ "$STATUS" = ok ]
