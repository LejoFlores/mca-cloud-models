#!/bin/bash
# Parallel HDF5, netcdf-c, netcdf-fortran (and optionally PnetCDF) from source into $PREFIX.
# Shared by every image in containers/ so SCHNAPS, ERF and WPS/WRF link the same I/O stack.
# Versions match the Borah builds (schnaps-borah build/versions_gpu.sh, erf-borah build/versions.sh).
#
#   PREFIX=/opt/deps CC=mpicc FC=mpif90 WITH_PNETCDF=1 build-netcdf-stack.sh
#
# Sources come from GitHub (release assets and git tags) only: the HDF Group and Unidata web
# servers are not needed. CMake options follow schnaps-borah build/compile_gpu.sh.
set -euo pipefail
: "${PREFIX:?set PREFIX}"
HDF5_VER=${HDF5_VER:-1.14.6}
NETCDF_C_VER=${NETCDF_C_VER:-4.10.0}
NETCDF_F_VER=${NETCDF_F_VER:-4.6.1}
PNETCDF_VER=${PNETCDF_VER:-1.14.1}
WITH_PNETCDF=${WITH_PNETCDF:-0}
CC=${CC:-mpicc} FC=${FC:-mpif90}
J=${J:-$(nproc)}
W=$(mktemp -d); cd "$W"
export CMAKE_PREFIX_PATH=$PREFIX PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig LD_LIBRARY_PATH=$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

echo "== HDF5 $HDF5_VER (parallel, C only)"
curl -fsSL --retry 3 -o hdf5.tgz \
  "https://github.com/HDFGroup/hdf5/releases/download/hdf5_${HDF5_VER}/hdf5-${HDF5_VER}.tar.gz"
tar xzf hdf5.tgz
cmake -S hdf5-$HDF5_VER -B hdf5-b -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_BUILD_TYPE=Release -DHDF5_ENABLE_PARALLEL=ON \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DHDF5_BUILD_FORTRAN=OFF -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_BUILD_JAVA=OFF -DHDF5_BUILD_EXAMPLES=OFF -DHDF5_BUILD_TOOLS=ON -DBUILD_TESTING=OFF \
  -DHDF5_ENABLE_Z_LIB_SUPPORT=ON -DHDF5_ENABLE_SZIP_SUPPORT=OFF
cmake --build hdf5-b -j$J && cmake --install hdf5-b

PNC=OFF
if [ "$WITH_PNETCDF" = 1 ]; then
  echo "== PnetCDF $PNETCDF_VER"
  git -c advice.detachedHead=false clone -q --depth 1 -b checkpoint.$PNETCDF_VER \
    https://github.com/Parallel-NetCDF/PnetCDF.git pnetcdf
  (cd pnetcdf && autoreconf -i >/dev/null && \
   ./configure -q --prefix=$PREFIX --enable-shared --disable-static MPICC=$CC MPIF77=$FC MPIF90=$FC \
     --disable-cxx --disable-fortran-test && make -j$J >/dev/null && make install >/dev/null)
  PNC=ON
fi

echo "== netcdf-c $NETCDF_C_VER (parallel netCDF-4; no DAP/S3/byte-range)"
git -c advice.detachedHead=false clone -q --depth 1 -b v$NETCDF_C_VER https://github.com/Unidata/netcdf-c.git ncc
cmake -S ncc -B ncc-b -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_BUILD_TYPE=Release -DHDF5_ROOT=$PREFIX \
  -DNETCDF_ENABLE_PARALLEL4=ON -DNETCDF_ENABLE_PNETCDF=$PNC -DNETCDF_ENABLE_DAP=OFF \
  -DNETCDF_ENABLE_BYTERANGE=OFF -DNETCDF_ENABLE_S3=OFF -DNETCDF_ENABLE_LIBXML2=OFF \
  -DNETCDF_ENABLE_TESTS=OFF -DNETCDF_BUILD_UTILITIES=ON -DNETCDF_ENABLE_FILTER_TESTING=OFF \
  -DNETCDF_ENABLE_PLUGINS=OFF
cmake --build ncc-b -j$J && cmake --install ncc-b

echo "== netcdf-fortran $NETCDF_F_VER"
git -c advice.detachedHead=false clone -q --depth 1 -b v$NETCDF_F_VER https://github.com/Unidata/netcdf-fortran.git ncf
cmake -S ncf -B ncf-b -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_Fortran_COMPILER=$FC -DCMAKE_BUILD_TYPE=Release \
  -DnetCDF_INCLUDE_DIR=$PREFIX/include -DnetCDF_LIBRARIES=$PREFIX/lib/libnetcdf.so \
  -DnetCDF_LIBRARY=$PREFIX/lib/libnetcdf.so -DENABLE_TESTS=OFF -DBUILD_EXAMPLES=OFF
cmake --build ncf-b -j$J && cmake --install ncf-b

[ -f "$PREFIX/include/netcdf_par.h" ] || { echo "netcdf-c is not the parallel build" >&2; exit 1; }
{ echo "hdf5 $HDF5_VER"; echo "netcdf-c $NETCDF_C_VER"; echo "netcdf-fortran $NETCDF_F_VER"
  [ "$PNC" = ON ] && echo "pnetcdf $PNETCDF_VER"; echo "stack-compilers CC=$CC FC=$FC"; } > $PREFIX/STACK_VERSIONS
cd / && rm -rf "$W"
