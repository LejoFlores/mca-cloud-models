#!/bin/bash
# Stage the Dry Creek Dec 2015 12-hour benchmark inputs into CASE_DIR. Steps (run any subset):
#   schnaps  domain files + namelists from schnaps-borah, HRRR forcing from AWS (hrrr_forcing.py)
#   erf-hrrr HRRR GRIB2 for WPS from AWS (erf-borah setup/hrrr_wps.py)
#   erf-wps  WPS + real.exe in the WPS image -> wrfinput_d01..d03, wrfbdy_d01 (needs GEOG_DIR)
#
#   CASE_DIR=/data/drycreek SCHNAPS_BORAH=~/schnaps-borah ERF_BORAH=~/erf-borah \
#   GEOG_DIR=/data/WPS_GEOG WPS_IMAGE=wps-real:4.6.0-4.7.1 bench/stage_drycreek.sh schnaps erf-hrrr erf-wps
#
# HRRR comes from the public AWS bucket noaa-hrrr-bdp-pds (no credentials, no cost inside us-east-1;
# elsewhere it is internet egress from AWS's side, free to the reader). The 6 h forecast valid each
# hour is used, as on Borah. The Python steps need numpy, netCDF4, requests and eccodes: by default
# a venv in $CASE_DIR/.venv is made with pip (PYTHON=... to use an existing interpreter instead).
set -euo pipefail
BENCH=$(cd "$(dirname "$0")" && pwd)
: "${CASE_DIR:?set CASE_DIR}"; mkdir -p "$CASE_DIR"; CASE_DIR=$(cd "$CASE_DIR" && pwd)
SCHNAPS_BORAH=${SCHNAPS_BORAH:-$HOME/schnaps-borah}; ERF_BORAH=${ERF_BORAH:-$HOME/erf-borah}
H0=${H0:-2015-12-18T18}; H1=${H1:-2015-12-19T06}          # inclusive hours of the 12 h window
BBOX=(42.7 -117.6 44.7 -114.8)                              # the Borah forcing box (S W N E)
steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(schnaps erf-hrrr erf-wps)

py() {
  if [ -n "${PYTHON:-}" ]; then "$PYTHON" "$@"; return; fi
  if [ ! -x "$CASE_DIR/.venv/bin/python" ]; then
    python3 -m venv "$CASE_DIR/.venv"
    "$CASE_DIR/.venv/bin/pip" install -q numpy netCDF4 requests eccodes
  fi
  "$CASE_DIR/.venv/bin/python" "$@"
}

for s in "${steps[@]}"; do case $s in
schnaps)
  D=$SCHNAPS_BORAH/setup/drycreek
  [ -d "$D/domains" ] || { echo "no $D/domains: clone LejoFlores/schnaps-borah to SCHNAPS_BORAH"; exit 1; }
  mkdir -p $CASE_DIR/schnaps/domains
  cp $D/domains/drycreek_d0*.nc $D/domains/drycreek_50m_d0*.nc $CASE_DIR/schnaps/domains/
  cp $D/drycreek_dec2015.nml $D/drycreek_dec2015_50m_noahmp.nml $CASE_DIR/schnaps/
  echo "schnaps-borah $(git -C $SCHNAPS_BORAH rev-parse HEAD 2>/dev/null || echo unknown)" > $CASE_DIR/schnaps/SOURCE
  py $SCHNAPS_BORAH/setup/hrrr_forcing.py --start $H0 --end $H1 --bbox "${BBOX[@]}" --out $CASE_DIR/schnaps/forcing \
    | grep -E "Z |rror" ;;
erf-hrrr)
  [ -f "$ERF_BORAH/setup/hrrr_wps.py" ] || { echo "no $ERF_BORAH/setup: clone LejoFlores/erf-borah to ERF_BORAH"; exit 1; }
  mkdir -p $CASE_DIR/erf/setup
  cp $ERF_BORAH/setup/namelist.wps $ERF_BORAH/setup/namelist.input $CASE_DIR/erf/setup/
  cp $ERF_BORAH/setup/inputs_drycreek $ERF_BORAH/setup/namelist.erf $CASE_DIR/erf/
  echo "erf-borah $(git -C $ERF_BORAH rev-parse HEAD 2>/dev/null || echo unknown)" > $CASE_DIR/erf/SOURCE
  bb=(); command -v wgrib2 >/dev/null && bb=(--bbox "${BBOX[@]}")   # crop only when wgrib2 is there
  py $ERF_BORAH/setup/hrrr_wps.py --start $H0 --end $H1 --out $CASE_DIR/erf/hrrr "${bb[@]}" ;;
erf-wps)
  : "${GEOG_DIR:?set GEOG_DIR to the WPS static geography (geog_high_res_mandatory)}"
  : "${WPS_IMAGE:?set WPS_IMAGE}"
  W0=${H0/T/_}; W1=${H1/T/_}
  if [ "${RUNTIME:-docker}" = apptainer ]; then
    apptainer exec --cleanenv --bind $CASE_DIR:/case --bind $GEOG_DIR:/geog:ro --bind $BENCH:/bench:ro \
      "$WPS_IMAGE" /bench/inner/wps_real.sh $W0 $W1
  else
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e GEOGRES=${GEOGRES:-default} -v $CASE_DIR:/case \
      -v $GEOG_DIR:/geog:ro -v $BENCH:/bench:ro "$WPS_IMAGE" /bench/inner/wps_real.sh $W0 $W1
  fi ;;
*) echo "unknown step $s"; exit 2 ;;
esac; done
echo "Staged in $CASE_DIR"
