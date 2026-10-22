#!/bin/bash
# Build ERF with MPI + NetCDF + Noah-MP + RRTMGP (erf-borah build/compile.sh), install to $3.
#   build_erf.sh cpu|gpu <src> <prefix>
# gpu reads CUDA_ARCH (e.g. 8.0) and KOKKOS_ARCH (e.g. AMPERE80) from the environment.
set -euo pipefail
T=$1; SRC=$2; P=$3; J=${J:-$(nproc)}
[ -f "$(nc-config --includedir)/netcdf_par.h" ] || { echo "netcdf-c is not the parallel build" >&2; exit 1; }
GPU=()
if [ "$T" = gpu ]; then
  # nvcc compiles AMReX's .cu files without the MPI wrapper: give it MPI's headers.
  export CPATH=$(mpicxx --showme:incdirs | tr ' ' ':')${CPATH:+:$CPATH}
  GPU=(-DERF_ENABLE_CUDA=ON -DAMReX_CUDA_ARCH="$CUDA_ARCH" -DKokkos_ARCH_${KOKKOS_ARCH}=ON
       -DCMAKE_CUDA_HOST_COMPILER=${CUDAHOSTCXX:-g++})
fi
B=$(mktemp -d)
cmake -S $SRC -B $B -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$P \
  -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_Fortran_COMPILER=mpif90 \
  -DERF_ENABLE_MPI=ON -DERF_ENABLE_NETCDF=ON -DERF_ENABLE_HDF5=OFF \
  -DERF_ENABLE_NOAHMP=ON -DERF_ENABLE_RRTMGP=ON -DERF_ENABLE_TESTS=OFF "${GPU[@]}"
cmake --build $B -j$J
cmake --install $B
EXE=$(ls $P/bin/erf_exec 2>/dev/null || find $P $B -name erf_exec -type f | head -1)
mkdir -p $P/bin; [ "$EXE" = "$P/bin/erf_exec" ] || cp "$EXE" $P/bin/erf_exec
# Run-time data every case needs: Noah-MP table, sample namelist, RRTMGP coefficients
mkdir -p $P/data
cp $SRC/Submodules/Noah-MP/parameters/NoahmpTable.TBL $P/data/
cp $SRC/Docs/sphinx_doc/namelist.erf $P/data/namelist.erf.sample
# (erf-borah's inputs_drycreek uses rrtmgp-data-*-2018-12-04.nc; ERF's RegTests use rrtmgp-gas-*.nc)
find $SRC/Submodules/RRTMGP -name 'rrtmgp-data-*-2018-12-04.nc' -o -name 'rrtmgp-gas-*.nc' \
     -o -name 'rrtmgp-cloud-optics-coeffs-*.nc' | xargs -r cp -t $P/data/
ls $P/data
ldd $P/bin/erf_exec | grep -iE "netcdf|hdf5|cuda|mpi" || true
rm -rf $B
