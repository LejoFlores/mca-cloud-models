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

## Task 2: ERF CPU and GPU images, WPS/real.exe image (`containers/erf/`, `containers/wps/`)

- Elapsed: about 1 h 25 min (04:35-06:00 UTC), mostly builds: ERF CPU 16 min, WRF + WPS 18 min per attempt (three attempts).
- Built:
  - `erf/Dockerfile.cpu`: ERF `5fa15bdc5e7f` with MPI, NetCDF, Noah-MP and RRTMGP, using the same CMake options as erf-borah `compile.sh`. The image is 3.4 GB.
  - `erf/Dockerfile.gpu`: nvcc 12.4 on `nvidia/cuda` (by digest) with a GCC 12 host compiler, and a slim runtime stage on `nvidia/cuda:*-runtime`. `CUDA_ARCH`/`KOKKOS_ARCH` give one architecture per image, because Kokkos (used through EKAT for RRTMGP) targets exactly one.
  - `wps/Dockerfile`: WPS 4.6.0 and WRF 4.7.1 `real.exe` (GNU dmpar), plus JasPer 2.0.33.
  - `erf/run-example.sh`: two ERF regression cases.
- Validated on CPU:
  - The ERF Radiation regression test (RRTMGP + moisture) ran 20 steps on 4 ranks in 10 s.
  - The NoahMP_Ideal test ran its 2 steps on 1 rank.
  - The same Radiation test ran through `bench/erf_drycreek.sh CASE=smoke` under Docker and under Apptainer (SIF built from `containers/erf/erf-cpu.def`). Those two rows in `bench/results/erf.csv` are harness checks labeled as such; the cost model ignores them.
  - WPS: `geogrid.exe`, `ungrib.exe`, `metgrid.exe` and `real.exe` all link. In a debug container with the same build commands, `ungrib.exe` decoded a real HRRR hour (2015-12-18 18Z, f06, from erf-borah `hrrr_wps.py`). Every `Vtable.raphrrr` field was present: 50 native levels, the surface fields, and 9 soil levels.
  - SCHNAPS forcing staging (`bench/stage_drycreek.sh schnaps`) wrote all 13 hourly HRRR files for the 12 h window (69 MB). Hour 2015-12-19 03Z fell back to the 7 h lead because the 6 h forecast is missing from the archive.
- Not run: the ERF Dry Creek case itself. It needs `wrfinput_d0*`/`wrfbdy_d01`, which need geogrid, which needs the WPS static geography from www2.mmm.ucar.edu (blocked).
- Broke, and fixed:
  1. EKAT's submodules (Catch2, kokkos, spdlog, yaml-cpp) use `git@github.com:` URLs. In a container without SSH keys the clone hung, then failed after 12 min. A first fix through `GIT_CONFIG_COUNT` worked on the host only, because the sandbox proxy rewrites SSH there; git does not pass those variables to submodule clones. The fix that works is a temporary global gitconfig with `url.https://github.com/.insteadOf`.
  2. ERF's Radiation regression inputs name `rrtmgp-gas-*.nc` coefficient files, which are not in ERF's tree at this commit. The example uses the 2018 files that ERF ships, the same ones erf-borah uses.
  3. `run-example.sh` first ran the NoahMP_Ideal 4x4 column for 20 steps on 4 ranks. MOST then failed to converge at step 3. That was my misuse: the case is meant for 1 rank and 2 steps.
  4. WRF 4.7.1 failed to link `-lhdf5_fortran` because `HDF5=/opt/deps` was set. That variable makes WRF link HDF5's Fortran libraries, and the stack builds HDF5 C-only. WRF's netCDF-4 support does not need it, so it was dropped.
  5. WPS 4.6 `configure` adds `-lnetcdff` only when it finds a static `libnetcdff.a`, so geogrid and metgrid failed with undefined `nf_*`. The Dockerfile now adds it to `configure.wps`.
  6. Disk: the sandbox allowance is 27 GB, and the `nvidia/cuda` devel base alone takes 11 GB once unpacked. The CPU images and the build cache were deleted before the GPU build.

### ERF GPU (part of task 2)

- sm_80 / Kokkos AMPERE80, CUDA 12.4.1: compiled in 56 min on 4 cores. `cuobjdump --list-elf` shows `erf_exec.1.sm_80.cubin` and `erf_exec.2.sm_80.cubin`, and `ldd` resolves every library except `libcuda.so.1`, which the driver supplies. The slim runtime stage on `nvidia/cuda:12.4.1-runtime` ran its own `ldd` check. Then exporting the image ran out of sandbox disk ("no space left on device"), so there is no local image to `docker run`. GPU runtime is PENDING.
- sm_89 / Kokkos ADA89 (L40S), same CUDA: built with `--output type=cacheonly` (no image export, to stay within disk) in 65 min. `cuobjdump` shows `erf_exec.1.sm_89.cubin` and `erf_exec.2.sm_89.cubin`, and the runtime stage's `ldd` check and manifest passed. The manifest lists `CUDA 12.4 CUDA_ARCH=8.9 Kokkos_ARCH_ADA89` and `min_driver 550.54.14`. GPU runtime is PENDING.
- Broke:
  1. `mpi.h: No such file or directory`. nvcc compiles AMReX's `.cu` files without the MPI wrapper. Fixed by putting `mpicxx --showme:incdirs` on `CPATH`.
  2. The link check counted `libcuda.so.1` as missing. It belongs to the driver, so it is now excluded.
  3. The runtime manifest read the CUDA version from `/usr/local/cuda-*`, which matches two directories, so the minimum-driver line was wrong. It now reads `$CUDA_VERSION`.

## Task 3: Apptainer

- Elapsed: about 10 min.
- Built: a `.def` file next to every Dockerfile, bootstrapping `docker-daemon://` from the local image, and `apptainer build ... docker-daemon://...` documented in `containers/README.md`. Apptainer 1.4.5 was installed in the sandbox from its GitHub release `.deb` to test them.
- Validated: `apptainer build --notest erf-cpu.sif containers/erf/erf-cpu.def` gave a 984 MB SIF. `bench/erf_drycreek.sh CASE=smoke` ran the Radiation regression test in it with `RUNTIME=apptainer`.
- Broke, sandbox only: the `%test` section and plain `apptainer exec` fail as root here with "Requesting capability set ... while permitted capability set is ...". As a normal user, squashfuse cannot open `/dev/fuse`. `--no-privs` works as root, so the harness has `APPTAINER_FLAGS` for it. A Jetstream2 instance should not need it.

## Task 4: Benchmark harness and cost-model hook (`bench/`, `cost/cost_model.py`)

- Elapsed: about 35 min.
- Built:
  - `schnaps_drycreek.sh` (`VARIANT=50m` matched to ERF, or `250m` for Borah's CPU case) and `erf_drycreek.sh` (1 km / 250 m / 50 m). Both cover the 2015-12-18 18Z to 2015-12-19 06Z window.
  - `stage_drycreek.sh`, which stages schnaps-borah domains and namelists, HRRR for SCHNAPS, HRRR GRIB2 for WPS, and WPS + real.exe in the WPS image.
  - `common.sh`, which handles the CSV, hardware and instance detection, the image digest, and Docker or Apptainer launch.
  - `python3 cost/cost_model.py --measured [DIR]`, which replaces the assumed SCHNAPS L40S rate and ERF's "WRF cores per A100" with measured Dry Creek rates, normalized per column-step and per GPU type.
- Validated:
  - Without `--measured`, the cost model's output is byte-identical to `cost/output.txt`.
  - With a synthetic CSV in a temporary directory (not committed), the hook replaced both values (160 → 268 WRF cores per A100, for example) and the scenario tables changed.
  - The ERF smoke rows were written under both runtimes.
  - SCHNAPS forcing staging ran end to end.
- Not run: any Dry Creek benchmark. SCHNAPS cannot be built here, and ERF needs WPS static data. No rate in `bench/results/` is a benchmark.
- Broke: the AWS metadata probe got an error page from the sandbox proxy, and the instance column recorded that text. It now uses `curl -f` and checks the instance-type format.

## Tasks 5-6: Jetstream2 and AWS guides (`docs/jetstream2.md`, `docs/aws.md`)

- Elapsed: about 20 min.
- docs.jetstream-cloud.org did not resolve from this session. The Jetstream2 facts were read from the docs' source repository (gitlab.com/jetstream-cloud/jetstream2/docs, commit of 2026-10-13): flavors, vGPU versus passthrough, featured images, Docker and the NVIDIA toolkit, `module load apptainer`, Exosphere steps, `exouser` and `ubuntu`, and the CLI commands.
- The AWS guide uses the Deep Learning Base OSS NVIDIA driver AMI (Ubuntu 22.04) through its SSM parameter, a one-time spot request, and the prices already cited in `cost/cost_model.py`.
- No cloud resources were created, and no images were pushed.

## Task 7: Second session, reachability recheck (2026-10-22, from 13:41 UTC)

- Elapsed: about 10 min.
- Same sandbox shape (4 cores, 15 GB RAM, about 31 GB free disk at start, Docker 29.9.1, no GPU), different network policy. Checked with `curl -sI` and `git ls-remote`:

| Host | Result |
| --- | --- |
| `codeberg.org` | Reachable. `git ls-remote` sees SCHNAPS `v1.1.1` at `648b00e148f2` |
| `git.wsl.ch` | Reachable over git (`git ls-remote snow-models/snowpack.git` works; a bare `curl -I` on the repo URL gets 403 from the server, not the proxy) |
| `support.hdfgroup.org` | Reachable (200) |
| `developer.download.nvidia.com` | Reachable (`/hpc-sdk/24.5/` answers 307) |
| `nvcr.io` | Denied (proxy 403 on CONNECT). `containers/pin-digests.sh` cannot pin the NVHPC base |
| `www2.mmm.ucar.edu` | Denied (proxy 403) |
| `www.fftw.org` | Denied (proxy 403) |
| Docker Hub (`registry-1.docker.io`) | Reachable but answering 429 Too Many Requests (anonymous pull limit), so `pin-digests.sh` printed UNREACHABLE for every image |

- Workaround for Docker Hub: `mirror.gcr.io/library/ubuntu@sha256:0a9887931b0e...` is Google's Docker Hub mirror and serves the same content-addressed digest the Dockerfiles pin. As before, a local copy of that base got the proxy CA and HTTPS apt sources (sandbox only, never pushed), passed as `BASE_IMAGE`; the manifest of images built here therefore names that local base.

## Task 8: SCHNAPS CPU image built and tested (2026-10-22, 13:43-14:12 UTC)

- Elapsed: about 30 min. Build 20 min (apt 4 min, HDF5/netCDF stack 8 min, source fetch 42 s, SCHNAPS compile and tester 5 min, image export 2 min), tests 7 min.
- Built `schnaps:1.1.1-cpu` (2.95 GB) from `containers/schnaps/Dockerfile.cpu` unchanged, with SCHNAPS, its Noah-MP fork and the test data from codeberg.org and SNOWPACK from git.wsl.ch. The schnaps-borah SNOWPACK tarball was not needed. The tree checks passed: SCHNAPS at `v1.1.1` (`f4218edbb0d3`), SNOWPACK at `2a099259447c`.
- The manifest records rte-rrtmgp v1.9.2, rrtmgp-data v1.9, icar_supporting_files `8b20ace82edb`, test-drive v0.6.1, noahmp `a3c314771e7b` and test-data `832b5714246c`, plus HDF5 1.14.6, netcdf-c 4.10.0, netcdf-fortran 4.6.1, gfortran 12.3.0 and Open MPI 4.1.2.
- `docker run --rm schnaps:1.1.1-cpu /opt/schnaps/run-tests.sh`:
  - 20 of 20 unit tests passed, on 4 ranks, in 54 s.
  - `integration.Standard` passed in 338 s on 4 ranks. SCHNAPS's `tests/scripts/lib/mpi_np.sh` sizes the run from `nproc --all`, halving it above 8 and clamping it to 2-10.
  - Borah's reference is 82 s on 10 ranks. In rank-seconds that is 820 on Borah against 1,350 here, on a 4-core cloud sandbox while an HRRR download ran alongside. This is a correctness check, not a benchmark.
- Broke:
  1. Docker Hub rate limiting (429), worked around with `mirror.gcr.io` at the same digest (task 7).
  2. Nothing in the SCHNAPS build itself.
  3. `run-tests.sh`'s header said the integration case uses min(nproc/2, 10) ranks, which was wrong; corrected. Inside the image `nproc` prints 1, because GNU `nproc` honors `OMP_NUM_THREADS=1`. SCHNAPS uses `nproc --all`, so it is unaffected.

## Task 9: ERF Dry Creek inputs staged (2026-10-22, 13:47-15:31 UTC)

- Elapsed: about 1 h 45 min, overlapping task 8. HRRR download 45 min including retries, WPS image build 51 min, WPS + real.exe 2 min per attempt (four attempts).
- www2.mmm.ucar.edu was opened by the PI partway through the session. TLS verification then failed, because the proxy passes UCAR's own certificate through and the sandbox CA store (122 certificates) lacks its root, emSign Root CA - G1. The download was verified against the Mozilla bundle from Ubuntu 22.04's `ca-certificates` package (20260816ubuntu0.22.04.1, 242 certificates), installed through apt. Verification was never turned off.
- Staged into `CASE_DIR` (not in git):
  - WPS static data: `geog_high_res_mandatory.tar.gz` (2,772,782,816 bytes, sha256 `89b026b9db0a...`). Only the tiles over Dry Creek plus 0.7° were unpacked, 149 MB instead of about 29 GB, with the new `bench/geog_subset.py`.
  - HRRR: 13 hours from the AWS archive via erf-borah `hrrr_wps.py`, 580 records each. Hours 22Z and 03Z came from the 7 h lead. The hours were cropped with wgrib2 3.6.0, built from source because Ubuntu has no package, from 5.1 GB to 45 MB.
  - geogrid, ungrib, metgrid and real.exe ran in `wps-real:4.6.0-4.7.1` through `bench/stage_drycreek.sh erf-wps`. They wrote `wrfinput_d01` (123x123), `wrfinput_d02` (128x136) and `wrfinput_d03` (240x280), each with 60 levels, and `wrfbdy_d01` with 12 boundary times and QCLOUD/QRAIN/QICE/QSNOW/QGRAUP boundaries. "SUCCESS COMPLETE REAL_EM INIT" on 4 ranks.
- Not run: ERF on these inputs. The ERF CPU image is not in this sandbox, a 12 h 50 m case is GPU-sized, and the brief asked for staging only.
- Broke:
  1. HRRR byte-range reads were cut off through the proxy seven times (IncompleteRead, RemoteDisconnected, SSL EOF). `hrrr_wps.py` has no retry, so a wrapper fetched one hour at a time with up to 4 attempts. erf-borah would benefit from a retry in `get()`.
  2. My first wrapper used `date -d "2015-12-18 18:00 +3 hour"`, which GNU date reads as a +3 timezone offset, so it fetched 15-17Z. Those were deleted and refetched with epoch arithmetic.
  3. ungrib on uncropped HRRR writes 4.2 GB per hour. The disk filled after four hours (about 16 GB of intermediates), which took the session's temp space with it. Freed by deleting the intermediates and the geography tarball, then cropping with wgrib2.
  4. real.exe: "Both km_opt and diff_opt need to be set". erf-borah's `namelist.input` sets neither, and real.exe had not run on Borah yet (erf-borah README). The staged copy got `diff_opt = 2, 2, 2`, `km_opt = 4, 4, 2`. WRF 4.7.1's source shows real.exe only checks that they are set and consistent (`share/module_check_a_mundo.F`); only wrf.exe's time stepping reads them, so ERF's inputs do not depend on them. With the PI's approval the same values went to erf-borah on branch `namelist-diff-km-opt` (commit `6041575`, not merged).
  5. real.exe: "pal, linear is about as low as we go", with `lagrange_order` 1 or 2. Cause: no sea-level pressure in met_em. `Vtable.raphrrr` reads MSLMA (0/3/198), while `hrrr_wps.py` fetches PRMSL (0/3/1). `bench/inner/wps_real.sh` now links a Vtable copy with PMSL mapped to PRMSL. The fix was validated end to end through the committed script.
  6. `wps_real.sh` sized MPI with `nproc`, which prints 1 inside the images (`OMP_NUM_THREADS=1`). It now uses `nproc --all`, so real.exe ran on 4 ranks.

## Task 10: SCHNAPS GPU image, not attempted (2026-10-22)

- nvcr.io is still denied (proxy 403), so `containers/pin-digests.sh` cannot pin `nvcr.io/nvidia/nvhpc:24.5-devel-cuda12.4-ubuntu22.04`, and the NVHPC base cannot be pulled. The SCHNAPS GPU build, its cc80/86/89 `cuobjdump` link check and its digest pin remain to do.
- developer.download.nvidia.com is reachable and serves the HPC SDK 24.5 / CUDA 12.4 tarball (6.8 GB). A local base built from it could stand in for the link check, but that changes how the image is made. It was not done; it is for the PI to decide.
- Later the same day the PI opened nvcr.io. `containers/pin-digests.sh` then returned the NVHPC digests, and the Dockerfile now pins them: 24.5-devel-cuda12.4-ubuntu22.04 at `sha256:17b2fe8eebc7...` (amd64 `sha256:0e57ca811c92...`), and 26.3-devel-cuda13.1-ubuntu24.04 at `sha256:a7beb2a5f701...`. The image is 7.05 GB compressed. Its pull still failed: nvcr.io redirects layer downloads to `layers.nvcr.io`, which the proxy denies (403 on CONNECT). So the SCHNAPS GPU build and its link check still wait on access to `layers.nvcr.io`. To make room, the validated `schnaps:1.1.1-cpu` and `wps-real` images and the build cache were deleted from the sandbox; both rebuild from the committed Dockerfiles.
