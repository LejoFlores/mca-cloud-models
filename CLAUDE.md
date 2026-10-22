# Working in this repository

## Purpose

This repository builds portable container images for SCHNAPS and ERF, plus a benchmark harness, so the PI (Alejandro Flores, Boise State) can run and cost both models on cloud GPUs and on Jetstream2. Results feed the final report of NSF MCA award 2121108 and a planned ACCESS Jetstream2 allocation request.

## Ground truth to start from

The working build recipes are in two sibling repositories. Port what works there; don't re-derive it.

- `LejoFlores/schnaps-borah` (private). SCHNAPS v1.1.1:
  - CPU: gfortran 12 and OpenMPI.
  - GPU: NVHPC 24.5 nvfortran, CUDA 12.4, cc 8.9.
  - Dependencies: HDF5 1.14.6, netcdf-c 4.10.0, netcdf-fortran 4.6.1, FFTW, PnetCDF, and SNOWPACK pinned by the SCHNAPS ref. SNOWPACK lives on git.wsl.ch; a fallback tarball is in that repository.
  - Cases: Dry Creek Dec 2015 (HRRR → 1 km → 250 m → 50 m) and Wolverine Glacier.
- `LejoFlores/erf-borah` (public). ERF at commit 5fa15bd (2026-10-08), with MPI, NetCDF, Noah-MP and RRTMGP. The chain runs HRRR from AWS → WPS → real.exe → ERF on one L40S. The ERF grids match the SCHNAPS Dry Creek grids.

## Rules

- Pin every version: base images by digest, model source by tag or commit. Record versions in a manifest inside each image.
- GPU images must state their minimum NVIDIA driver and CUDA version. Targets:
  - Jetstream2: A100, cc 8.0.
  - AWS: g6e L40S (cc 8.9), g5 A10G (cc 8.6) and p4d A100.
  - Borah: L40S on driver 550, so CUDA 12.4 at most.
  - Build for several compute capabilities where the compiler allows it.
- This container has Docker (start it with `dockerd &` if the socket is missing) but no GPU. Build GPU images and check that they link. Run CPU images end to end. Mark GPU runtime validation as pending until it runs on real hardware.
- Every image also needs an Apptainer definition or a documented `apptainer build` from the Docker image. Borah's compute nodes cannot run Apptainer because user namespaces are off, so Borah keeps its source builds.
- Benchmarks report simulated hours per wall-clock hour, the hardware used, and cost per simulated hour from a stated price. Write results as CSV under `bench/results/` so `cost/cost_model.py` can read them.
- Don't push large binaries or model data. Push images to GHCR only after the PI approves.
- Keep a short log in `docs/effort-log.md` of each task: what it was, elapsed time, and what broke. It is evidence for the final report.
- Never commit credentials. Cloud resources are created only with explicit PI approval.
