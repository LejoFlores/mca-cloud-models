# syntax=docker/dockerfile:1.7
# Preprocessing for ERF: WPS 4.6.0 (geogrid, ungrib, metgrid) and WRF 4.7.1 real.exe, the
# versions erf-borah uses through Borah's modules (run/wps_real.slurm), built with gfortran 12 +
# Open MPI (dmpar) on the same NetCDF stack as the model images. CPU only.
#   docker build -f containers/wps/Dockerfile -t wps-real:4.6.0-4.7.1 containers/
ARG BASE_IMAGE=ubuntu:22.04@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956

# The deps stage is kept identical to containers/schnaps/Dockerfile.cpu so both share its layers.
# ---------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS deps
ARG BASE_IMAGE
ENV DEBIAN_FRONTEND=noninteractive BASE_IMAGE=${BASE_IMAGE}
# Ubuntu 22.04 packages pinned to the versions this was validated with (2026-10-22). The full
# package list lands in /opt/manifest-packages.txt.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-12=12.3.0-1ubuntu1~22.04.3 g++-12=12.3.0-1ubuntu1~22.04.3 gfortran-12=12.3.0-1ubuntu1~22.04.3 \
      libopenmpi-dev=4.1.2-2ubuntu1 openmpi-bin=4.1.2-2ubuntu1 libfftw3-dev=3.3.8-2ubuntu8 \
      zlib1g-dev git curl ca-certificates python3-pip make m4 autoconf automake libtool \
      pkg-config file perl \
 && rm -rf /var/lib/apt/lists/* \
 && for t in gcc g++ gfortran; do update-alternatives --install /usr/bin/$t $t /usr/bin/$t-12 100; done \
 && update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-12 100 \
 && update-alternatives --install /usr/bin/f95 f95 /usr/bin/gfortran-12 100 \
 && pip3 install --no-cache-dir cmake==3.31.6
# Open MPI's wrappers must call gfortran 12 (Ubuntu's Open MPI was built with gfortran 11; the
# .mod format is the same, checked by compiling an mpi_f08 program below).
ENV OMPI_CC=gcc-12 OMPI_CXX=g++-12 OMPI_FC=gfortran-12 \
    OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 OMP_NUM_THREADS=1
RUN printf 'program t\n use mpi_f08\n call MPI_Init()\n call MPI_Finalize()\nend program\n' > /tmp/t.f90 \
 && mpif90 /tmp/t.f90 -o /tmp/t && mpirun -np 2 /tmp/t && rm /tmp/t /tmp/t.f90
COPY common/build-netcdf-stack.sh common/write-manifest.sh /usr/local/bin/
# PnetCDF off: its git source needs libtool >= 2.5.4 (22.04 has 2.4.6), and the working Borah
# GPU build already runs SCHNAPS without it (netCDF-4 parallel I/O through HDF5 instead).
RUN PREFIX=/opt/deps CC=mpicc FC=mpif90 WITH_PNETCDF=0 build-netcdf-stack.sh
ENV PATH=/opt/deps/bin:$PATH LD_LIBRARY_PATH=/opt/deps/lib \
    PKG_CONFIG_PATH=/opt/deps/lib/pkgconfig CMAKE_PREFIX_PATH=/opt/deps

# ---------------------------------------------------------------------------------------------
FROM deps AS wps
ARG WRF_TAG=v4.7.1
ARG WRF_COMMIT=f52c197ed39d12e087d02c50f412d90d418f6186
ARG WPS_TAG=v4.6.0
ARG WPS_COMMIT=335c76a111f84503e8b963abaf273ea8053645bb
ARG JASPER_TAG=version-2.0.33
ARG J=4
RUN apt-get update && apt-get install -y --no-install-recommends libpng-dev csh tcsh time \
 && rm -rf /var/lib/apt/lists/*
# JasPer for ungrib's GRIB2 (JPEG2000) decoder; Ubuntu 22.04 no longer packages it.
RUN git -c advice.detachedHead=false clone -q --depth 1 -b ${JASPER_TAG} https://github.com/jasper-software/jasper.git /tmp/jasper \
 && cmake -S /tmp/jasper -B /tmp/jasper/b -DCMAKE_INSTALL_PREFIX=/opt/deps -DCMAKE_INSTALL_LIBDIR=lib \
      -DJAS_ENABLE_DOC=OFF -DJAS_ENABLE_PROGRAMS=OFF -DJAS_ENABLE_OPENGL=OFF -DJAS_ENABLE_LIBJPEG=OFF \
 && cmake --build /tmp/jasper/b -j${J} && cmake --install /tmp/jasper/b && rm -rf /tmp/jasper
# No HDF5=... here: with it set, WRF also links -lhdf5_fortran, which this C-only HDF5 lacks.
ENV NETCDF=/opt/deps JASPERLIB=/opt/deps/lib JASPERINC=/opt/deps/include \
    WRF_DIR=/opt/wrf/WRF WPS_DIR=/opt/wrf/WPS
# WRF: configure option 34 = GNU (gfortran/gcc) dmpar, nesting 1 = basic. Only real.exe is used.
RUN git -c advice.detachedHead=false clone -q --depth 1 --recurse-submodules --shallow-submodules \
      -b ${WRF_TAG} https://github.com/wrf-model/WRF.git ${WRF_DIR} \
 && cd ${WRF_DIR} && [ "$(git rev-parse HEAD)" = "${WRF_COMMIT}" ] \
 && printf '34\n1\n' | ./configure > configure.log 2>&1 \
 && ./compile -j ${J} em_real > compile.log 2>&1; \
    tail -n 20 ${WRF_DIR}/compile.log; ls -l ${WRF_DIR}/main/real.exe ${WRF_DIR}/main/wrf.exe
# WPS: configure option 3 = Linux x86_64, gfortran (dmpar)
RUN git -c advice.detachedHead=false clone -q --depth 1 -b ${WPS_TAG} https://github.com/wrf-model/WPS.git ${WPS_DIR} \
 && cd ${WPS_DIR} && [ "$(git rev-parse HEAD)" = "${WPS_COMMIT}" ] \
 && printf '3\n' | ./configure > configure.log 2>&1 \
 && ./compile > compile.log 2>&1; \
    tail -n 5 ${WPS_DIR}/compile.log; ls -l ${WPS_DIR}/geogrid.exe ${WPS_DIR}/ungrib.exe ${WPS_DIR}/metgrid.exe
RUN { echo "wrf ${WRF_TAG} $(git -C ${WRF_DIR} rev-parse HEAD) configure=34(GNU dmpar) target=em_real"; \
      echo "wps ${WPS_TAG} $(git -C ${WPS_DIR} rev-parse HEAD) configure=3(gfortran dmpar)"; \
      echo "jasper ${JASPER_TAG}"; echo "gpu none"; } | write-manifest.sh wps-real
ENV PATH=${WPS_DIR}:${WRF_DIR}/main:$PATH
WORKDIR /work
CMD ["cat", "/opt/manifest.txt"]
