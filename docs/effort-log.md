# Effort log

One entry per task: what it was, elapsed time, what broke. Times are wall-clock in a Claude Code
cloud session (4 cores, 15 GB RAM, about 27 GB of free disk, Docker, no GPU). Builds ran with
`--network host` through the session's egress proxy. That proxy's CA was added to a local copy of
each base image, which was never pushed, so the committed Dockerfiles carry no proxy settings.

## Environment facts (2026-10-22)

The session's network policy refused these hosts (HTTP 403 on CONNECT):

| Host | Needed for | Workaround |
| --- | --- | --- |
| `codeberg.org` | SCHNAPS source, its Noah-MP fork, its test data | None found. The archived `HICAR-Model/HICAR` on GitHub is SCHNAPS's predecessor (its `v1.1.1` is 2023 HICAR), not a mirror. The Dockerfiles accept the sources as a build context instead (`containers/README.md`) |
| `git.wsl.ch` | SNOWPACK | `--build-context snowpack-tarball=` schnaps-borah `build/`. The tarball holds the v1.1.1 pin `2a099259447c`, checked |
| `nvcr.io`, `developer.download.nvidia.com` | NVHPC (nvfortran) for the SCHNAPS GPU image | None. Docker Hub has third-party NVHPC re-uploads (`kitware/nvidia-nvhpc`, 10-15 GB compressed), but they are not NVIDIA's own and would not fit on this disk next to the other builds |
| `support.hdfgroup.org`, `www.fftw.org` | HDF5, FFTW tarballs | HDF5 from its GitHub release asset. FFTW from Ubuntu (3.3.8, not Borah's 3.3.10) |
| `codeload.github.com` (GitHub archive tarballs) | netcdf-c and netcdf-fortran tarballs | `git clone --depth 1 -b <tag>` instead |
| `www2.mmm.ucar.edu` | WPS static geography (`geog_high_res_mandatory`) | None. geogrid cannot run here |

These hosts were reachable: GitHub (git and release assets), Docker Hub (including `nvidia/cuda`),
the Ubuntu archive over HTTPS, PyPI, and the HRRR bucket `noaa-hrrr-bdp-pds.s3.amazonaws.com`.

## Task 1: SCHNAPS CPU and GPU images (`containers/schnaps/`)

- Elapsed: about 20 min of writing plus build time (dependency stage 7 min).
- Built:
  - `common/build-netcdf-stack.sh`: parallel HDF5 1.14.6, netcdf-c 4.10.0 and netcdf-fortran 4.6.1, shared by all images.
  - `schnaps/Dockerfile.cpu`: Ubuntu 22.04 by digest, gfortran 12.3, Open MPI 4.1.2.
  - `schnaps/Dockerfile.gpu`: NVHPC, with the CUDA version chosen at build time through the NVHPC image (default 24.5 / CUDA 12.4), and `GPU_CC=cc80,cc86,cc89` in one binary.
  - `fetch_sources.sh`: a port of schnaps-borah's. It reads every pin from the SCHNAPS ref's own CMake files.
  - `run-tests.sh`: unit tests plus the Standard case.
- Validated: the CPU dependency stage builds, and an `mpi_f08` program built with gfortran 12 against Ubuntu's Open MPI runs on 2 ranks. Both Dockerfiles pass `docker buildx build --check` (the GPU one with a stand-in base, because nvcr.io is blocked).
- Broke:
  1. The SCHNAPS build stops at `git clone https://codeberg.org/SCHNAPS-Model/SCHNAPS.git`: "Received HTTP code 403 from proxy after CONNECT". So SCHNAPS was not compiled here, the unit tests and the Standard case did **not** run, and the cc80/cc89 link check did **not** run. These are the first things to do on a machine that can reach codeberg.org, or with Borah's source tree handed in through `--build-context schnaps-sources=`.
  2. The GPU image cannot be built here: there is no NVHPC (nvcr.io and the NVIDIA download site are blocked). Its NVHPC base is a tag, not a digest, until `containers/pin-digests.sh` runs somewhere with nvcr.io access.
  3. PnetCDF from git needs libtool 2.5.4 or newer, and Ubuntu 22.04 has 2.4.6, so PnetCDF was dropped. The Borah GPU build already runs without it.
  4. The first dependency build failed with curl error 60, because installing `ca-certificates` rewrote the bundle that held the proxy CA. This only affected the sandbox; the fix was in the local base image.
