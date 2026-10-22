# mca-cloud-models

Portable containers and benchmarks for running SCHNAPS and ERF in the cloud (AWS, Google Cloud, Jetstream2) and on HPC systems. This repository supports the final phase of NSF MCA award 2121108, *Navigating the Clouds on the Horizon: Toward Cloud-Enabled Computational Hydrology*.

The goals:

1. Package [SCHNAPS](https://codeberg.org/SCHNAPS-Model/SCHNAPS) (the GPU successor to HICAR/ICAR) and [ERF](https://github.com/erf-model/ERF) (the GPU-native Energy Research and Forecasting model) as reproducible container images that run on cloud GPUs.
2. Benchmark both models on the same cases, starting with Dry Creek near Boise and then the Middle and South Forks of the Boise River, and report simulated hours per wall-clock hour and cost per simulated year.
3. Use those numbers to price the Snake River Basin climate ensemble the original proposal set out to build.

## Layout

| Path | What |
| --- | --- |
| `cost/` | Cost model for the full original ensemble across AWS, Google Cloud and Jetstream2 (`cost_model.py`, standard library only). `cost_summary.md` explains the estimates and `output.txt` holds the script's output |
| `containers/` | Dockerfiles and Apptainer definitions (in progress) |
| `bench/` | Benchmark harness and results (in progress) |

## Related repositories

- [schnaps-borah](https://github.com/LejoFlores/schnaps-borah): working SCHNAPS CPU and GPU builds and Dry Creek and Wolverine cases on Boise State's Borah cluster (private)
- [erf-borah](https://github.com/LejoFlores/erf-borah): ERF build and the Dry Creek HRRR → WPS → ERF chain on Borah

## Cost model

```bash
python3 cost/cost_model.py
```

Prices are as of 2026-10-22. Every input is a named constant in the script with its source cited. The benchmarks behind the scaling come from small domains, so read the estimates as ranges.
