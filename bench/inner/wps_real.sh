#!/bin/bash
# Runs INSIDE the WPS/real image: HRRR -> geogrid, ungrib, metgrid -> real.exe -> wrfinput_d01..d03
# + wrfbdy_d01 for ERF. A port of erf-borah run/wps_real.slurm.
#   wps_real.sh <START YYYY-MM-DD_HH> <END YYYY-MM-DD_HH>
# Mounts: /case (CASE_DIR; HRRR GRIB in /case/erf/hrrr, erf-borah setup/ templates in /case/erf/setup),
#         /geog (WPS static geography). GEOGRES (default "default"), NP (MPI ranks, default nproc).
set -euo pipefail
START=$1; END=$2; GEOGRES=${GEOGRES:-default}; NP=${NP:-$(nproc)}
C=/case/erf; T=$C/setup
fill() {
  local y0=${START:0:4} m0=${START:5:2} d0=${START:8:2} h0=${START:11:2}
  local y1=${END:0:4} m1=${END:5:2} d1=${END:8:2} h1=${END:11:2}
  sed -e "s|__START__|${START}:00:00|g" -e "s|__END__|${END}:00:00|g" -e "s|__GEOG__|/geog|" \
      -e "s|__GEOGRES1__|default|" -e "s|__GEOGRES2__|$GEOGRES|" -e "s|__GEOGRES3__|$GEOGRES|" \
      -e "s|__Y0__|$y0|g" -e "s|__M0__|$m0|g" -e "s|__D0__|$d0|g" -e "s|__H0__|$h0|g" \
      -e "s|__Y1__|$y1|g" -e "s|__M1__|$m1|g" -e "s|__D1__|$d1|g" -e "s|__H1__|$h1|g" $1 > $2
}
mkdir -p $C/wps/geogrid $C/wps/metgrid $C/real
cd $C/wps
fill $T/namelist.wps namelist.wps
ln -sf $WPS_DIR/geogrid/GEOGRID.TBL.ARW geogrid/GEOGRID.TBL
[ -n "${GEOGRID_TBL:-}" ] && ln -sf $GEOGRID_TBL geogrid/GEOGRID.TBL     # custom table with schnaps_topo
ln -sf $WPS_DIR/metgrid/METGRID.TBL.ARW metgrid/METGRID.TBL
ln -sf $WPS_DIR/ungrib/Variable_Tables/Vtable.raphrrr Vtable
[ -f geo_em.d03.nc ] || mpirun --oversubscribe -np $(( NP < 4 ? NP : 4 )) geogrid.exe
rm -f GRIBFILE.* HRRR:*
$WPS_DIR/link_grib.csh $C/hrrr/hrrr.*.grib2
ungrib.exe > ungrib.log 2>&1 || { tail ungrib.log; exit 1; }
mpirun --oversubscribe -np $NP metgrid.exe
ls met_em.d0* | head -3
cd $C/real
fill $T/namelist.input namelist.input
ln -sf $C/wps/met_em.d0* .
for f in $WRF_DIR/run/*.TBL $WRF_DIR/run/*_DATA $WRF_DIR/run/*.formatted; do [ -e $f ] && ln -sf $f .; done
mpirun --oversubscribe -np $NP real.exe
tail -2 rsl.out.0000
cp wrfinput_d01 wrfinput_d02 wrfinput_d03 wrfbdy_d01 $C/
ncdump -h $C/wrfbdy_d01 | grep -E "QCLOUD_BXS|QICE_BXS|QRAIN_BXS" || echo "no moisture boundaries in wrfbdy_d01"
