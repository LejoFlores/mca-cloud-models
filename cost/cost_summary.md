# Snake River CESM-LE downscaling: cost estimate (prices as of 2026-10-22)

Produced by `cost_model.py` (output in `output.txt`). Every input is a named, tagged and cited constant in the script.

## Headline (central estimate, 2020–2100 plus 1 spin-up year, 25% development overhead, USD)

| Scenario | AWS on-demand | AWS spot | GCP on-demand | GCP spot | Archive (storage+egress/yr) | Jetstream2 |
|---|---|---|---|---|---|---|
| a) 4 km | $0.77M (range 0.30–2.6M) | $0.42M | $0.67M | $0.63M | 122 TB: $14k | 15.7M SU; 2.9M GPU SU (Accelerate if WRF-Hydro runs on Borah) |
| b) 1 km | $8.0M (1.3–65M) | $6.1M | $10.2M | $5.2M | 291 TB: $28k | 201M SU (Maximize); about 42 wall-years at 8 A100s |
| c) 1 km + 250 m Boise nest | $14.7M (2.2–124M) | $11.5M | $19.0M | $9.6M | 333 TB: $31k | 376M SU (Maximize); not feasible |

Running 2006–2100 adds about 17%. The tiered 100 TB plan (10% S3 Standard, 30% Standard-IA, 60% Deep Archive, plus 50 TB/yr of egress) costs about $12k/yr, against $28k/yr all in Standard. The Jetstream2 dollar value equals the AWS on-demand column.

## How the numbers are built
- **Scaling formula.** Cost per simulated hour = rate × Σᵢ Nᵢ × (1000 m / dxᵢ). Here Nᵢ is the number of grid columns in domain i, and the time step is assumed proportional to dx (CFL). Vertical levels stay at the benchmark values (SCHNAPS 40; WRF/ERF 51).
- **Domain.** The 41.5–46 N, 109.5–118.5 W box plus a 50 km buffer is 850 × 600 km: 32k columns at 4 km and 511k at 1 km. WRF-Hydro runs on the box without the buffer: 376k cells at 1 km and 6.0M routing cells at 250 m.
- **SCHNAPS rates.**
  - Dry Creek on CPU works out to 3.8e-5 core-h per 1-km column-step equivalent per simulated hour.
  - Wolverine on one L40S implies that one GPU equals about 1,800 cores. The Standard case implies about 26 cores.
  - Central uses their geometric mean (about 220 cores per L40S), low uses Wolverine and high uses Standard. **This 70× spread is the main uncertainty.**
- **WRF and ERF anchor.** CONUS404 (1368×1016×51, dt 20 s) at about 0.57M core-h per simulated year gives 9.4e-4 core-s per column-step. For ERF, one A100 is taken to replace 160 WRF cores (80–480), from the "~5×" result in Lattanzi et al. 2025 with 4 A100s against 128 cores per node. The 1 km ERF runs include a 4 km parent domain.
- **WRF-Hydro.** No published per-year throughput was found. The rate comes from NWM operations: more than 100k CPU-h/day over 283M routing cells and an assumed 6,000 simulated hours per day (range 3,000–12,000). That is about 3,900 core-h per member-year, and it **dominates scenario (a)**.
- **Cross-check.** Dry Creek SCHNAPS costs about 1/5 of WRF per column, not ICAR's 1/140–1/800 (Gutmann et al. 2016). Only the low bound is ICAR-like.

## Key findings
1. Scenario (a) is affordable anywhere. Going to 1 km multiplies atmospheric cost by about 64× (16× more columns, 4× more steps), and the 250 m nest roughly doubles it again. That puts (b) and (c) at around $5–15M of cloud time.
2. SCHNAPS on GPU decides scenarios (b) and (c). **Run `run/drycreek_storm_gpu.slurm` on the same Dry Creek case first.** That one measurement collapses the 70× uncertainty band.
3. WRF-Hydro (CPU) is about 85% of scenario (a)'s cost. Masking it to the basin, or benchmarking it, could cut that substantially.
4. Spot pricing saves 40–50% on A100, A10G and CPU, but only about 15% on g6e (L40S). GCP has no L40S, so the GCP rows rest on assumed relative GPU speeds.
5. ERF is double precision by default, so run it on A100 or H100 (L40S assumed about 0.4× an A100).

## Jetstream2 (NSF ACCESS)
- **Charge rates.** 1 ACCESS credit = 1 SU. CPU (m3) costs 1 SU per vCPU-h; Large Memory (r3) and GPU cost 2 SU per vCPU-h. The GPU flavors:

  | Flavor | GPU | SU/h | Availability |
  |---|---|---|---|
  | g3.medium | ¼ A100, 10 GB | 16 | Partial GPU |
  | g3.large | ½ A100, 20 GB | 32 | Partial GPU |
  | g3.xl | full A100, 40 GB | 64 | Capped at 2 cards (Explore) or 4 (Discover and up) |
  | g4.xl | L40S, 48 GB | 84 | NAIRR only (cap 0 for every ACCESS tier) |
  | g5.xl | H100, 80 GB | 128 | 2 cards, Discover and up |

- **Tiers.** Explore allows up to 400k credits with an abstract and fast review. Discover allows 1.5M with a 1-page description. Accelerate allows 3M with a 3-page description and panel review. Maximize has no fixed limit: it takes a 10-page proposal with scaling data and is reviewed twice a year (next window reported as 15 Dec 2026–31 Jan 2027; unverified). Projects last 12 months or the length of the supporting grant, and can be supplemented or renewed.
- **Storage.** Every project gets 1 TB by default; more is bought at 1 credit per GB, with caps of about 5, 10, 20 and 40 TB by tier. Space can be moved between volumes, Manila shares and the S3-compatible object store. **Jetstream2 cannot hold 100 TB.**
- **Software.** Docker and Apptainer are on the featured images. Kubernetes is available through Magnum with Cluster API, and there are documented guides for Zero to JupyterHub, GPU JupyterHub and the Dask Operator (Zonca).
- **Eligibility.** A Boise State PI is eligible: ACCESS requires a U.S.-based researcher or educator, and since 2025 an institutional email address.

**Strategy.** Run WRF-Hydro on Borah and request Jetstream2 GPU time only for the atmosphere.
1. Start with **Explore** to benchmark SCHNAPS on g3.large against g3.xl and to port ERF.
2. Scenario (a)'s 2.9M GPU SU then fits in **Accelerate**, worth about $0.1M of commercial GPU time.
3. Use partial g3.large instances to scale out, since they have no per-tier card cap.
4. Request **Maximize** only after the Dry Creek GPU result. Even then, (b) and (c) are not realistic on shared Jetstream2 GPUs (decades of wall time at about 8 A100s). They would need a Maximize request on larger GPU systems, or a cut-down ensemble or period.
5. Host the archive through the **AWS Open Data Sponsorship** program (it covers S3 storage and egress; reviewed quarterly; 2-year initial term) or on OSN (10–50 TB at 1 credit per GB).

## Flagged / unverified
- The task's 188,000 km² basin area is too small: published figures give about 280,000 km², and the requested box leaves out the Clearwater and lower Snake (+45% columns to include them).
- Boise Middle Fork plus South Fork is about 4,380 km², not 5,000. The Middle Fork figure is my subtraction between sources.
- These came only from search summaries or third parties, not the papers themselves: the CONUS404 core-hour figure (Sha et al. 2026), the ERF Section 5.2 numbers, the WRF-Hydro rate, all spot prices (undated snapshots; spot is volatile) and the c7a spot price (assumed 50% off).
- GCP prices are for us-central1, not us-west1. The relative GPU speeds, GPU memory per cell, output volumes and development factor are my assumptions.

## Sources
Full URLs are in the comments of `cost_model.py`:
- AWS Price List bulk files (us-west-2, effective 2026-10-01)
- Google Cloud pricing pages
- Jetstream2 docs (GitLab source of docs.jetstream-cloud.org)
- ACCESS project types and allocations policy
- AWS Open Data FAQ; OSN allocation docs
- Papers: Rasmussen et al. 2023 (BAMS); Sha et al. 2026 (arXiv 2602.18646); Lattanzi et al. 2025 (JAMES); Gutmann et al. 2016 (J. Hydrometeorology)
- NCAR NWM status briefing (2019)
- runs-on.com and DoiT spot snapshots
