# containers/

Docker images for SCHNAPS, ERF and the WPS/real.exe preprocessing, each with an Apptainer
definition. The recipes are ports of the working Borah builds in
[schnaps-borah](https://github.com/LejoFlores/schnaps-borah) and
[erf-borah](https://github.com/LejoFlores/erf-borah). Build them with `containers/` as the build
context, so that `common/` is visible.

| Image (suggested tag) | Dockerfile | Model | Toolchain | GPU target | Min. driver |
| --- | --- | --- | --- | --- | --- |
| `schnaps:1.1.1-cpu` | `schnaps/Dockerfile.cpu` | SCHNAPS v1.1.1, SNOWPACK 2a09925 | gfortran 12.3, Open MPI 4.1.2 | none | n/a |
| `schnaps:1.1.1-gpu-cuda12.4` | `schnaps/Dockerfile.gpu` | same | NVHPC 24.5 nvfortran (OpenACC), HPC-X MPI, CUDA 12.4 | cc80, cc86, cc89 in one binary | 550.54.14 (525.60.13 with CUDA minor-version compatibility) |
| `erf:5fa15bd-cpu` | `erf/Dockerfile.cpu` | ERF 5fa15bd + MPI, NetCDF, Noah-MP, RRTMGP | GCC 12.3, Open MPI 4.1.2 | none | n/a |
| `erf:5fa15bd-cuda12.4-sm80` | `erf/Dockerfile.gpu` | same | nvcc 12.4 + GCC 12, Open MPI 4.1.2 | one arch per image (`CUDA_ARCH`) | 550.54.14 (525.60.13 with CUDA minor-version compatibility) |
| `wps-real:4.6.0-4.7.1` | `wps/Dockerfile` | WPS 4.6.0, WRF 4.7.1 `real.exe` | gfortran 12.3, Open MPI 4.1.2 (dmpar) | none | n/a |

Every image uses the same I/O stack, built from source by `common/build-netcdf-stack.sh`:
parallel HDF5 1.14.6, netcdf-c 4.10.0 and netcdf-fortran 4.6.1, the versions used on Borah.
Each image writes `/opt/manifest.txt` (base image, compilers, MPI, library versions, model commit
and pinned dependency commits, minimum driver) and `/opt/manifest-packages.txt` (every Debian package).

## Pinning

- Base images are pinned by digest. `pin-digests.sh` prints the current digests. The NVHPC
  digests for the SCHNAPS GPU base were added on 2026-10-22, once nvcr.io was reachable.
- Model sources are pinned by tag or commit and checked in the build: SCHNAPS `v1.1.1` (the build
  stops if the source is elsewhere), SNOWPACK `2a099259447c` (what v1.1.1's `cmake/snowpack.cmake`
  pins), ERF `5fa15bdc5e7f` with the submodule commits it records, WRF `v4.7.1` (`f52c197`), WPS
  `v4.6.0` (`335c76a`), and JasPer `version-2.0.33`.
- Ubuntu packages for the compilers, MPI and FFTW are pinned to exact versions. The rest come from
  the Ubuntu 22.04 archive at build time, and their versions are recorded in `/opt/manifest-packages.txt`.
- PnetCDF, which Borah loads as a module, is left out. Its git source needs libtool 2.5.4 or newer,
  and the working Borah GPU build already runs SCHNAPS without it (`NETCDF_ENABLE_PNETCDF=OFF`).
- FFTW is Ubuntu's 3.3.8, which includes single precision. Borah uses 3.3.10, but fftw.org was not
  reachable from the build machine.

## Build

```bash
cd mca-cloud-models
docker build -f containers/schnaps/Dockerfile.cpu -t schnaps:1.1.1-cpu containers/
docker build -f containers/schnaps/Dockerfile.gpu -t schnaps:1.1.1-gpu-cuda12.4 containers/
docker build -f containers/erf/Dockerfile.cpu     -t erf:5fa15bd-cpu containers/
docker build -f containers/erf/Dockerfile.gpu     -t erf:5fa15bd-cuda12.4-sm80 containers/
docker build -f containers/wps/Dockerfile         -t wps-real:4.6.0-4.7.1 containers/
```

Useful build arguments:

| Image | Argument | Default | Notes |
| --- | --- | --- | --- |
| SCHNAPS GPU | `NVHPC_IMAGE`, `NVHPC_VER`, `CUDA_VER` | NVHPC 24.5, CUDA 12.4 | CUDA follows the NVHPC image. For newer drivers use `nvcr.io/nvidia/nvhpc:26.3-devel-cuda13.1-ubuntu24.04`, `NVHPC_VER=26.3` and `CUDA_VER=13.1` (driver 580 or newer; this matches upstream's prebuilt image). Borah's driver 550 needs CUDA 12.4 or older |
| SCHNAPS GPU | `GPU_CC` | `cc80,cc86,cc89` | A100, A10G and L40S in one binary. The build fails if `cuobjdump` does not find SASS for each one |
| ERF GPU | `CUDA_DEVEL`, `CUDA_RUNTIME` | `nvidia/cuda:12.4.1-*-ubuntu22.04@sha256:...` | The 12.8.1 digests are in the Dockerfile header |
| ERF GPU | `CUDA_ARCH`, `KOKKOS_ARCH` | `8.0`, `AMPERE80` | ERF's RRTMGP goes through EKAT and Kokkos, and Kokkos builds CUDA code for one architecture. Use `8.9 ADA89` for L40S and `8.6 AMPERE86` for A10G. sm_80 code also runs on 8.6 and 8.9, but is not tuned for them |
| all | `J` | 4 | Parallel compile jobs |

### When codeberg.org or git.wsl.ch is unreachable

SCHNAPS, its Noah-MP fork and its test data are on codeberg.org, and SNOWPACK is on git.wsl.ch.
The SCHNAPS Dockerfiles fetch them in a `schnaps-sources` stage (`schnaps/fetch_sources.sh`, a port
of schnaps-borah's `build/fetch_sources.sh`). Either part can be handed in from elsewhere:

```bash
# SNOWPACK only: schnaps-borah's fallback tarball (holds the v1.1.1 and main pins)
docker build --build-context snowpack-tarball=$HOME/schnaps-borah/build ...
# All SCHNAPS sources: any directory holding SCHNAPS/ and fetch/, e.g. Borah's tree after
# schnaps-borah build/fetch_sources.sh (copy /bsuscratch/$USER/schnaps/src off Borah first)
docker build --build-context schnaps-sources=/path/to/schnaps/src ...
```

The build cleans `SCHNAPS/build*` and `bin/` from a handed-in tree, resets local edits with
`git checkout -- .`, and checks that the tree is at `v1.1.1` and SNOWPACK is at the pinned commit.

## Test

```bash
docker run --rm schnaps:1.1.1-cpu /opt/schnaps/run-tests.sh         # unit tests + Standard case
docker run --rm erf:5fa15bd-cpu /opt/erf/run-example.sh             # RRTMGP and Noah-MP regression cases
docker run --rm IMAGE cat /opt/manifest.txt
```

GPU images need `--gpus all` (Docker) or `--nv` (Apptainer) and an NVIDIA driver at least as
new as the table above says.

## Apptainer

Each image has a definition file next to its Dockerfile that bootstraps from the local Docker
image:

```bash
apptainer build schnaps-1.1.1-cpu.sif containers/schnaps/schnaps-cpu.def
# or, without the definition file:
apptainer build schnaps-1.1.1-cpu.sif docker-daemon://schnaps:1.1.1-cpu
# from a registry, once images are pushed (after PI approval):
apptainer build schnaps-1.1.1-cpu.sif docker://ghcr.io/lejoflores/schnaps:1.1.1-cpu
apptainer exec --writable-tmpfs schnaps-1.1.1-cpu.sif /opt/schnaps/run-tests.sh
apptainer exec --nv erf-5fa15bd-cuda12.4-sm80.sif nvidia-smi
```

Run the MPI launcher inside the container (`apptainer exec IMAGE mpirun -np N ...`) on a single
node. Multi-node runs need the host MPI to match the container's Open MPI 4.1 (hybrid model). That
is untested.

Borah cannot use any of these, because its compute nodes have user namespaces disabled. Borah keeps
the source builds in the sibling repositories.

## Validation status

`docs/effort-log.md` has the dates, times and what broke. As of 2026-10-22:

| Image | Built here | Ran here | GPU runtime |
| --- | --- | --- | --- |
| SCHNAPS CPU | Yes (20 min, second session), with sources from codeberg.org and git.wsl.ch | 20/20 unit tests pass (4 ranks, 54 s), and the Standard integration case passes (4 ranks, 338 s; Borah: 82 s on 10 ranks) | n/a |
| SCHNAPS GPU | No. The NVHPC base is now pinned by digest, but its layers come from `layers.nvcr.io`, which this sandbox's proxy denies | No | PENDING |
| ERF CPU | Yes (16 min) | Radiation (RRTMGP) and NoahMP_Ideal regression cases pass, under Docker and Apptainer | n/a |
| ERF GPU, sm_80 | Yes (56 min). `cuobjdump` shows sm_80 cubins, and every library resolves except the driver's `libcuda.so.1`. The image export then ran out of sandbox disk | No GPU | PENDING |
| ERF GPU, sm_89 (`CUDA_ARCH=8.9 KOKKOS_ARCH=ADA89`) | Yes (65 min, cache-only build, no image export). sm_89 cubins, all libraries resolve, and the manifest records min driver 550.54.14 | No GPU | PENDING |
| WPS/real.exe | Yes (18 min; 51 min in the second session, sharing the CPU) | Second session: the full Dry Creek chain ran (geogrid on a 149 MB subset of the static data, ungrib and metgrid on 13 cropped HRRR hours, real.exe on 4 ranks), writing `wrfinput_d01..d03` (123x123, 128x136, 240x280, 60 levels) and `wrfbdy_d01` (12 times, with moisture). It needed two fixes, in `bench/README.md` | n/a |
