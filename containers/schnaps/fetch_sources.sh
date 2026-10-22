#!/bin/bash
# SCHNAPS sources for the container builds: a port of schnaps-borah build/fetch_sources.sh.
# Writes the same layout as $SCHNAPS_ROOT/src on Borah, so a Borah source tree can stand in for
# this step (docker build --build-context schnaps-sources=/bsuscratch/$USER/schnaps/src ...):
#   $DEST/SCHNAPS                       SCHNAPS at $REF (+ tests/Test_Cases)
#   $DEST/fetch/{rte-rrtmgp,rrtmgp-data,icar_supporting_files,test-drive,noahmp,SNOWPACK}
#   $DEST/fetch/PINS, $DEST/fetch/REF   the dependency commits this ref pins
#
#   fetch_sources.sh <ref> <dest> [snowpack_fallback.tar.gz]
# SNOWPACK lives on git.wsl.ch. If that host is unreachable, pass schnaps-borah's
# build/snowpack_fallback.tar.gz (a git copy holding the commits v1.1.1 and main pin).
set -euo pipefail
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
REF=$1; DEST=$2; SNOW_TGZ=${3:-}
F=$DEST/fetch; mkdir -p $F; cd $DEST

pin_clone() {  # url dest ref: shallow fetch of one commit
  rm -rf $2; git init -q $2; git -C $2 remote add origin $1
  git -C $2 fetch -q --depth 1 origin "$3" && git -C $2 checkout -q FETCH_HEAD
}

git clone -q https://codeberg.org/SCHNAPS-Model/SCHNAPS.git
git -C SCHNAPS checkout -q "$REF"
S=$DEST/SCHNAPS; echo "$REF $(git -C $S describe --tags --always) $(git -C $S rev-parse HEAD)" > $F/REF

# Pins read from this ref's own CMake files (same parsing as schnaps-borah)
pin() {
  awk -v n="$2" '/FetchContent_Declare\(/{d=1; k=0} d{k++; if ($0 ~ "(\\(|^[[:space:]]*)" n "[[:space:]]*$") hit=1;
    if (hit && $1=="GIT_TAG") {print $2; exit} if (k>4) {d=0; hit=0}}' $S/$1; }
RTE=$(pin CMakeLists.txt rte-rrtmgp); RDATA=$(pin CMakeLists.txt rrtmgp-data)
ICAR=$(pin CMakeLists.txt icar_supporting_files); TDRIVE=$(pin tests/CMakeLists.txt test-drive)
NOAHMP=$(grep -oP 'set\(NOAHMP_GIT_SHA \K[0-9a-f]+' $S/CMakeLists.txt)
SNOW=$(grep -oP 'set\(SNOWPACK_COMMIT "\K[0-9a-f]+' $S/cmake/snowpack.cmake)
printf 'rte-rrtmgp %s\nrrtmgp-data %s\nicar_supporting_files %s\ntest-drive %s\nnoahmp %s\nsnowpack %s\n' \
  "$RTE" "$RDATA" "$ICAR" "$TDRIVE" "$NOAHMP" "$SNOW" | tee $F/PINS
for v in RTE RDATA ICAR TDRIVE NOAHMP SNOW; do [ -n "${!v}" ] || { echo "could not read pin $v"; exit 1; }; done

git clone -q --depth 1 -b $RTE https://github.com/earth-system-radiation/rte-rrtmgp.git $F/rte-rrtmgp
git clone -q --depth 1 -b $RDATA https://github.com/earth-system-radiation/rrtmgp-data.git $F/rrtmgp-data
git clone -q --depth 1 -b $TDRIVE https://github.com/fortran-lang/test-drive.git $F/test-drive
pin_clone https://github.com/NCAR/icar_supporting_files.git $F/icar_supporting_files $ICAR
pin_clone https://codeberg.org/SCHNAPS-Model/noahmp.git $F/noahmp $NOAHMP

if [ -n "$SNOW_TGZ" ] && [ -f "$SNOW_TGZ" ]; then
  tar xzf "$SNOW_TGZ" -C $F
else
  git clone -q https://git.wsl.ch/snow-models/snowpack.git $F/SNOWPACK
fi
git -C $F/SNOWPACK checkout -q "$SNOW" || { echo "SNOWPACK $SNOW not found (refresh the fallback tarball?)"; exit 1; }

git clone -q --depth 1 -b main https://codeberg.org/SCHNAPS-Model/Test-Data.git $S/tests/Test_Cases
echo "test-data $(git -C $S/tests/Test_Cases rev-parse HEAD)" >> $F/PINS
