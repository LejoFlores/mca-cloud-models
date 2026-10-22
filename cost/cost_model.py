#!/usr/bin/env python3
"""
Transparent cost model: Snake River Basin CESM-LE downscaling (ERF member 1, SCHNAPS members
2-40, WRF-Hydro for all 40) on AWS, Google Cloud and Jetstream2 (NSF ACCESS).

Run:  python3 cost_model.py            (standard library only, Python >= 3.8)
      python3 cost_model.py --measured [DIR]   replace the assumed SCHNAPS GPU rate and ERF/WRF
                                         ratio with Dry Creek rates measured by bench/ (DIR defaults
                                         to ../bench/results; see apply_measured below)

Everything that drives a number is a named constant below, with a comment saying where it came
from. Tags used in comments:
  [SRC]   value read from a cited page or price file (retrieved 2026-10-21/22)
  [BENCH] PI's own Borah measurement (Oct 2026)
  [DERIV] arithmetic on other constants (shown in code)
  [ASSUME] engineering judgement, NOT verified -- change these first when better data arrive
Low / central / high always mean low / central / high COST.
"""
import csv
import glob
import math
import os
import sys

# =============================================================================================
# 1. GEOMETRY
# =============================================================================================
# Requested box around the Snake River Basin (task statement).  NOTE [SRC]: the full Snake basin
# is ~278,000-282,000 km^2 (Britannica https://www.britannica.com/place/Snake-River ; Wikipedia
# https://en.wikipedia.org/wiki/Snake_River), not 188,000 km^2, and reaches ~47 N / ~119 W
# (Clearwater, lower Snake to Pasco).  188,000 km^2 is closer to the basin above Hells Canyon.
# The box below therefore leaves out the Clearwater/lower Snake; see FULL_BASIN_* for that case.
BASIN_LAT_S, BASIN_LAT_N = 41.5, 46.0
BASIN_LON_W, BASIN_LON_E = -118.5, -109.5
BUFFER_KM = 50.0                       # lateral buffer for the atmospheric domains (task)
FULL_BASIN_LAT_S, FULL_BASIN_LAT_N = 41.0, 47.3     # [ASSUME] approx. full-basin extent
FULL_BASIN_LON_W, FULL_BASIN_LON_E = -119.3, -109.5  # [ASSUME]
KM_PER_DEG_LAT = 111.2
KM_PER_DEG_LON_EQ = 111.32

# Boise River headwaters nest (scenario c). [SRC] South Fork 1,314 mi^2 (Digital Atlas of Idaho);
# Middle Fork ~377 mi^2 = 759 mi^2 North/Middle Fork subbasin (Idaho DEQ) - 382 mi^2 North Fork
# (Digital Atlas).  The MF figure is our subtraction (unverified). Total ~4,380 km^2, i.e. a bit
# under the "~5,000 km^2" in the brief (~5,370 km^2 if the North Fork is included).
SQKM_PER_SQMI = 2.58999
BOISE_SF_MF_KM2 = (1314 + 377) * SQKM_PER_SQMI
NEST_RECT_FACTOR = 1.7    # [ASSUME] bounding rectangle + ~5 km relaxation zone vs basin area

# =============================================================================================
# 2. TIME
# =============================================================================================
YEARS_MAIN = 81                 # 2020-2100
YEARS_ALT = 95                  # 2006-2100 (CESM-LE RCP8.5 period)
SPINUP_YEARS = 1                # [ASSUME] one spin-up year per member chain (WRF-Hydro soils
                                # may need more; restart from a spun-up state otherwise)
HOURS_PER_YEAR = 8766.0         # 365.25 d
N_MEMBERS = 40
DEV_FACTOR = {"low": 1.10, "central": 1.25, "high": 1.50}   # [ASSUME] tests, failed/re-run
                                # jobs, calibration; multiplies all compute

# =============================================================================================
# 3. BENCHMARKS AND ANCHORS
# =============================================================================================
# Cost scaling used for every model (the formula the brief asked for):
#   cost per simulated hour  =  rate  x  sum_i [ N_cols_i x (DX_REF / dx_i) ]
# N_cols_i = grid columns of domain i; DX_REF/dx_i = number of time steps relative to a 1 km
# grid, assuming the CFL-limited step is proportional to dx (dt = C * dx, same C in benchmark
# and target).  "1-km column-step equivalents" (units) are the sum.  Vertical levels are held at
# the benchmark value (SCHNAPS nz=40 in setup/drycreek/*.nml; WRF/ERF 51 as in CONUS404).
DX_REF_M = 1000.0

# --- SCHNAPS, CPU, Dry Creek  [BENCH] 1 km 123x123 + 250 m 111x112, HRRR, 13 sim-h / wall-h on
#     32 cores (run/drycreek_storm.slurm).
DRY_D01_COLS, DRY_D01_DX = 123 * 123, 1000.0
DRY_D02_COLS, DRY_D02_DX = 111 * 112, 250.0
DRY_SIMH_PER_WALLH, DRY_CORES = 13.0, 32
# --- SCHNAPS, GPU, Wolverine Glacier [BENCH] 8 simulated days in ~4 h on one L40S.
#     Grid sizes [DERIV] from the ll/ur boxes in setup/wolverine/wolverine_50m_setup.yml:
#     d01 1 km 58.90-60.90 N x 150.2-146.6 W ~222x201; d02 250 m ~80x78; d03 50 m ~222x210.
WOL_DOMAINS = [(222 * 201, 1000.0), (80 * 78, 250.0), (222 * 210, 50.0)]
WOL_SIMH, WOL_GPUH = 8 * 24.0, 4.0
# --- SCHNAPS, GPU vs CPU, "Standard" case [BENCH]: L40S 31 s total (~6 s time steps) vs 82 s on
#     10 CPU ranks => 1 L40S ~ 26 cores end-to-end on a tiny case (a floor on GPU benefit).
STD_GPU_S, STD_CPU_S, STD_CPU_RANKS = 31.0, 82.0, 10

# --- WRF anchor: CONUS404 [SRC] 1368 x 1016 x 51 levels, dt = 20 s, 4 km (Rasmussen et al. 2023,
#     BAMS 104(8), https://journals.ametsoc.org/view/journals/bams/104/8/BAMS-D-21-0326.1.xml).
#     Cost: "~95 wall-clock hours on 6016 CPU cores (~0.57 M core-h) per simulated year" on
#     Derecho, from Sha et al. 2026 (https://arxiv.org/abs/2602.18646) as seen in a search
#     snippet only -- [UNVERIFIED against full text].  BAMS paper: 43 yr took >11 months on Denali.
C404_COLS, C404_DT_S = 1368 * 1016, 20.0
C404_COREH_PER_YEAR = 95.0 * 6016
WRF_DT_S_PER_KM = C404_DT_S / 4.0          # dt = 5 s per km of dx (CFL), held for ERF too
WRF_RATE_MULT = {"low": 0.8, "central": 1.0, "high": 1.6}   # [ASSUME] physics/IO/hardware

# --- ERF vs WRF [SRC, partly UNVERIFIED]: Lattanzi et al. 2025, JAMES, doi:10.1029/2024MS004884
#     abstract: ~5x speedup GPU-ERF vs CPU-WRF, squall line.  Section 5.2 numbers as summarised
#     at https://github.com/pkjha-aero/portfolio/pull/20 (third party, not checked against paper):
#     4.5-5.5x per step, 12.9-51 M cells, 2-8 Perlmutter nodes (4x A100 vs 128 cores per node);
#     5-15x per node.  => WRF cores replaced by one A100 = speedup * 128 / 4.
WRF_CORES_PER_A100 = {"low": 15 * 32, "central": 5 * 32, "high": 2.5 * 32}
#     high case [ASSUME]: Kessler squall line flatters GPU; full physics (Thompson, Noah-MP,
#     RRTMG) and a small 4 km grid (~1.6 M cells/GPU) run less efficiently.
ERF_PARENT_BUFFER_KM = 300.0     # [ASSUME] 4 km parent domain for 1 km ERF runs (CESM ~1 deg ->
ERF_PARENT_DX = 4000.0           #  1 km in one jump is too large a ratio for a dynamical model)

# --- ICAR cross-check [SRC]: Gutmann et al. 2016, J. Hydrometeor. 17, 957-973,
#     doi:10.1175/JHM-D-15-0155.1: WRF needed 140-800x more computational resources than ICAR.
ICAR_WRF_RATIO = (140.0, 800.0)

# --- WRF-Hydro anchor [SRC, rough]: NWM operational ">100,000 CPU-hours per day", ~360 M
#     computational elements (NCAR/OWP briefing, Mar 2019,
#     https://ral.ucar.edu/sites/default/files/public/9WRFHydro_NWM_Status_Mar_2019_b.pdf).
#     NWM CONUS 250 m routing grid 18432 x 15360 = 283 M cells [SRC, NWM domain spec].
#     Simulated CONUS hours per day across all cycles [ASSUME]: 6,000 (3,000-12,000).
#     No published per-year WRF-Hydro throughput was found -- [UNVERIFIED]; benchmark it.
NWM_COREH_PER_DAY = 100_000.0
NWM_RT_CELLS = 18432 * 15360
NWM_SIMH_PER_DAY = {"low": 12_000.0, "central": 6_000.0, "high": 3_000.0}
HYDRO_LSM_DX_M, HYDRO_RT_DX_M = 1000.0, 250.0   # brief; routing dt 15 s per WRF-Hydro guide

# --- GPU throughput relative to the benchmark GPU [ASSUME, UNVERIFIED]. SCHNAPS mostly single
#     precision & memory-bandwidth bound (L40S 864 GB/s, A100-40GB 1555, A10G 600, L4 300,
#     RTX PRO 6000 1792, H100 ~2000-3350).  ERF defaults to double precision (L40S/L4/A10G FP64
#     is 1/64 rate), so it is referenced to A100.
SCHNAPS_REL = {"L40S": 1.0, "A100": 1.3, "A100-half": 0.65, "A10G": 0.6, "L4": 0.35,
               "RTXPRO6000": 1.5, "H100": 2.0}
ERF_REL = {"A100": 1.0, "A100-half": 0.5, "H100": 2.0, "L40S": 0.4, "RTXPRO6000": 0.4,
           "A10G": 0.2, "L4": 0.1}
BYTES_PER_CELL_SCHNAPS = 1500   # [ASSUME] GPU memory per 3-D cell; decides GPUs per member

# =============================================================================================
# 4. PRICES (USD per hour, per GPU or per physical core)
# =============================================================================================
# AWS us-west-2 on-demand [SRC]: AWS Price List bulk file, effective 2026-10-01,
# https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-west-2/index.csv
#   g6e.xlarge (1 L40S) 1.8610; p4d.24xlarge (8 A100-40GB) 21.95764; g5.xlarge (1 A10G) 1.006;
#   c7a.48xlarge (192 vCPU = 192 physical cores, no SMT) 9.85344.
# AWS spot [SRC, third-party snapshots, undated -> volatile, UNVERIFIED]: g6e.xlarge 1.22-1.83
#   (https://go.runs-on.com/instances/ec2/g6e , https://sparecores.com/server/aws/g6e.xlarge);
#   p4d.24xlarge 10.71-13.42 (https://www.doit.com/compute/spot/us-west-2/p4d.24xlarge);
#   g5.xlarge 0.53-0.77 (https://www.doit.com/compute/spot/us-west-2/g5.xlarge);
#   c7a spot not looked up: [ASSUME] 50% of on-demand.
# Google Cloud [SRC]: https://cloud.google.com/products/compute/pricing/accelerator-optimized and
#   .../compute-optimized (static tables render Iowa us-central1; Oregon may differ: UNVERIFIED)
#   g2-standard-8 (1 L4) 0.853624 OD / 0.510832 spot; a2-highgpu-1g (1 A100-40GB) 3.673385 OD /
#   2.20401 spot; g4-standard-48 (1 RTX PRO 6000) 4.49993 OD / 1.6635 spot;
#   h4d-standard-192 (192 cores) 7.85376 OD (no spot); c2d-standard-112 (56 cores) spot 2.45728.
# Jetstream2 [SRC]: https://docs.jetstream-cloud.org/general/instance-flavors/ (source:
#   gitlab.com/jetstream-cloud/jetstream2/docs, docs/general/instance-flavors.md):
#   g3.large 16 vCPU, 50% A100, 32 SU/h; g3.xl full A100 64 SU/h; g4.xl L40S 84 SU/h;
#   g5.xl H100 128 SU/h; m3.* 1 SU per vCPU-h.  1 ACCESS credit = 1 SU (docs/general/access.md).
GPU_PRICES = {   # platform -> GPU -> (on-demand, spot_low, spot_central, spot_high) USD/GPU-h
    "AWS":  {"L40S": (1.8610, 1.22, 1.60, 1.83),
             "A100": (21.95764 / 8, 10.7148 / 8, 12.07 / 8, 13.4208 / 8),
             "A10G": (1.006, 0.5307, 0.65, 0.7682)},
    "GCP":  {"L4": (0.853624, 0.510832, 0.510832, 0.510832),
             "A100": (3.673385, 2.20401, 2.20401, 2.20401),
             "RTXPRO6000": (4.49993, 1.6635, 1.6635, 1.6635)},
}
CPU_PRICE_CORE_H = {   # (on-demand, spot) USD per physical core-hour
    "AWS": (9.85344 / 192, 0.5 * 9.85344 / 192),
    "GCP": (7.85376 / 192, 2.45728 / 56),
}
JS2_SU_PER_H = {"A100-half": 32, "A100": 64, "L40S": 84, "H100": 128}
JS2_SU_PER_CORE_H = 1.0        # m3 flavors; [ASSUME] 1 vCPU ~ 1 core for WRF-Hydro MPI

# =============================================================================================
# 5. JETSTREAM2 / ACCESS RULES [SRC] docs/alloc/overview.md, docs/faq/alloc.md,
#    docs/general/quotas.md (gitlab mirror of docs.jetstream-cloud.org)
# =============================================================================================
ACCESS_TIERS = [("Explore", 400_000), ("Discover", 1_500_000), ("Accelerate", 3_000_000),
                ("Maximize", math.inf)]
JS2_GPU_QUOTA_THRESHOLD_SU = 600_000   # GPU vCPU quota scales linearly above this
JS2_GPU_DEFAULT_VCPU = 64
JS2_FULL_A100_CAP = {"Explore": 2, "Discover": 4, "Accelerate": 4, "Maximize": 4}
# L40S (g4.*) cap is 0 for every ACCESS tier (NAIRR only); H100 2 for Discover and up.
JS2_STORAGE_MAX_TB = {"Explore": 5, "Discover": 10, "Accelerate": 20, "Maximize": 40}
JS2_STORAGE_CREDIT_PER_GB = 1.0
JS2_REALISTIC_A100_EQ = {"low": 16, "central": 8, "high": 4}   # [ASSUME] concurrent A100-
                                # equivalents one project can actually hold (shared, scarce GPUs);
                                # the quota formula alone would allow far more than exists.
SCHNAPS_GPU_CHOICE = {"AWS": "L40S", "GCP": None}   # AWS: price on the benchmarked L40S (g6e);
                                # GCP has no L40S, so take the cheapest per unit of work under
                                # the [ASSUME] SCHNAPS_REL factors.
STORAGE_YEARS = 5               # [ASSUME] retention period quoted alongside the per-year cost

# =============================================================================================
# 6. STORAGE [SRC] AWS Price List AmazonS3 / AmazonS3GlacierDeepArchive / AWSDataTransfer,
#    us-west-2, effective 2026-10-01 (USD per GB-month; egress per GB)
# =============================================================================================
S3 = {"Standard": 0.023, "Standard-IA": 0.0125, "Glacier-IR": 0.004,
      "Glacier-Flexible": 0.0036, "Deep-Archive": 0.00099}
S3_EGRESS_PER_GB = 0.09        # first 10 TB/month to internet (0.085 next 40 TB)
GCS = {"Standard": 0.02, "Nearline": 0.01, "Coldline": 0.004, "Archive": 0.0012}  # [SRC]
GCS_EGRESS_PER_GB = 0.12       # https://cloud.google.com/storage/pricing (us-central1 table)
TIER_MIX = {"hot": 0.10, "warm": 0.30, "cold": 0.60}   # [ASSUME] share of archive per tier
EGRESS_TB_PER_YEAR = 50.0      # [ASSUME] public downloads
PLAN_TB = 100.0                # proposal's tiered ~100 TB plan
# Output volume [ASSUME]: float32, netCDF4 compression ratio 2.5
BYTES, COMPRESS = 4, 2.5
SCH_2D = (3, 9)                # SCHNAPS members: (hourly, 3-hourly) 2-D variables
ERF_2D, ERF_3D, ERF_NZ = (25, 0), 6, 51   # member 1: 25 hourly 2-D, 6 x 6-hourly 3-D vars
HYD_LDAS_3H, HYD_RT_DAILY, HYD_REACHES, HYD_CHRT_VARS = 12, 3, 60_000, 3

# =============================================================================================
# HELPERS
# =============================================================================================
LEVELS = ("low", "central", "high")


def box_km(lat_s, lat_n, lon_w, lon_e, buffer_km=0.0):
    """Rectangle (km) covering a lat/lon box; width taken at the southern (widest) edge."""
    h = (lat_n - lat_s) * KM_PER_DEG_LAT + 2 * buffer_km
    w = (lon_e - lon_w) * KM_PER_DEG_LON_EQ * math.cos(math.radians(lat_s)) + 2 * buffer_km
    return w, h


def cols(w_km, h_km, dx_m):
    return math.ceil(w_km * 1000 / dx_m) * math.ceil(h_km * 1000 / dx_m)


def units(domains):
    """sum_i N_cols_i * DX_REF/dx_i  (1-km column-step equivalents per unit time)."""
    return sum(n * DX_REF_M / dx for n, dx in domains)


def tier_for(su):
    for name, cap in ACCESS_TIERS:
        if su <= cap:
            return name


def fmt(x, d=0):
    if x is None:
        return "-"
    if abs(x) >= 1e6:
        return f"{x/1e6:,.2f}M"
    if abs(x) >= 1e4:
        return f"{x/1e3:,.0f}k"
    return f"{x:,.{d}f}"


def table(title, header, rows):
    print(f"\n{title}")
    w = [max(len(str(h)), *(len(str(r[i])) for r in rows)) for i, h in enumerate(header)]
    print("  " + "  ".join(str(h).ljust(w[i]) for i, h in enumerate(header)))
    print("  " + "  ".join("-" * w[i] for i in range(len(header))))
    for r in rows:
        print("  " + "  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)))


# =============================================================================================
# DERIVED RATES
# =============================================================================================
dry_units = units([(DRY_D01_COLS, DRY_D01_DX), (DRY_D02_COLS, DRY_D02_DX)])
SCH_CPU_RATE = (DRY_CORES / DRY_SIMH_PER_WALLH) / dry_units      # core-h per unit-simhour
wol_units = units(WOL_DOMAINS)
SCH_GPU_RATE_WOL = (WOL_GPUH / WOL_SIMH) / wol_units              # L40S-h per unit-simhour
STD_CORES_PER_GPU = STD_CPU_S * STD_CPU_RANKS / STD_GPU_S         # ~26
wol_cores_per_gpu = SCH_CPU_RATE / SCH_GPU_RATE_WOL
SCH_CORES_PER_GPU = {"low": wol_cores_per_gpu,                    # best case (big domain)
                     "central": math.sqrt(wol_cores_per_gpu * STD_CORES_PER_GPU),
                     "high": STD_CORES_PER_GPU}                   # worst case (tiny domain)
SCH_GPU_RATE = {k: SCH_CPU_RATE / v for k, v in SCH_CORES_PER_GPU.items()}

C404_COLSTEPS_PER_YEAR = C404_COLS * HOURS_PER_YEAR * 3600 / C404_DT_S
WRF_CORE_S_PER_COLSTEP = C404_COREH_PER_YEAR * 3600 / C404_COLSTEPS_PER_YEAR

HYD_RATE = {k: NWM_COREH_PER_DAY / v / NWM_RT_CELLS for k, v in NWM_SIMH_PER_DAY.items()}
# core-h per 250 m routing cell per simulated hour (includes the 1 km LSM and channel routing)

# =============================================================================================
# MEASURED RATES HOOK  (python3 cost_model.py --measured [DIR])
# =============================================================================================
# bench/schnaps_drycreek.sh and bench/erf_drycreek.sh append rows to DIR/*.csv. Only GPU rows with
# status "ok" for the Dry Creek 12 h cases are used; the median rate per model wins. Each rate is
# converted to the same per-unit form the assumed values use, so every scenario scales as before:
#   SCHNAPS: L40S-h per unit-simhour = (1 / measured sim-h per wall-h) / units(case domains),
#            divided by SCHNAPS_REL of the measured GPU -> replaces SCH_GPU_RATE (all levels).
#   ERF:     A100-h per column-step = (1 / rate) * ERF_REL[gpu] / column-steps per sim-hour of the
#            case (dt as in erf-borah inputs_drycreek), turned into the WRF_CORES_PER_A100 that
#            reproduces it at each level's WRF_RATE_MULT -> replaces the Lattanzi et al. ratio.
BENCH_DOMAINS = {   # sim cases -> [(columns, dx_m)] (schnaps-borah setup/README.md, erf-borah README)
    "drycreek_dec2015_12h_250m": [(DRY_D01_COLS, 1000.0), (DRY_D02_COLS, 250.0)],
    "drycreek_dec2015_12h_50m": [(DRY_D01_COLS, 1000.0), (DRY_D02_COLS, 250.0), (227 * 268, 50.0)],
}
ERF_BENCH_LEVELS = {"drycreek_dec2015_12h_1km-250m-50m": [(123 * 123, 5.0), (128 * 136, 1.25),
                                                          (240 * 280, 0.25)]}   # (columns, dt_s)


def gpu_key(hardware, instance=""):
    """Map the CSV hardware string (nvidia-smi name) to the GPU keys used in the price tables.
    Jetstream2 g3.large is half an A100 through vGPU (its name reads like "GRID A100X-20C")."""
    h = hardware.upper()
    if "A100" in h:
        half = "MIG" in h or "GRID" in h or "-20C" in h or instance in ("g3.large", "g3.medium")
        return "A100-half" if half else "A100"
    for k in ("L40S", "A10G", "H100", "L4", "RTX PRO 6000"):
        if k in h:
            return "RTXPRO6000" if k == "RTX PRO 6000" else k
    return None


def read_bench(path):
    rows = []
    for f in sorted(glob.glob(os.path.join(path, "*.csv"))):
        with open(f, newline="") as fh:
            rows += [r for r in csv.DictReader(fh)]
    return [r for r in rows if r.get("status") == "ok" and int(r.get("gpus") or 0) > 0
            and r.get("sim_hours_per_wall_hour")]


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def apply_measured(path):
    """Swap the assumed GPU rates for measured ones. Returns report rows (empty if none found)."""
    global SCH_GPU_RATE, WRF_CORES_PER_A100
    rows, report = read_bench(path), []
    sch = []
    for r in rows:
        g = gpu_key(r["hardware"], r.get("instance", ""))
        if r["model"] == "schnaps" and r["case"] in BENCH_DOMAINS and g in SCHNAPS_REL:
            per_gpu = float(r["sim_hours_per_wall_hour"]) / int(r["gpus"])
            sch.append((1.0 / per_gpu) / units(BENCH_DOMAINS[r["case"]]) / SCHNAPS_REL[g])
    if sch:
        old = SCH_GPU_RATE["central"]
        SCH_GPU_RATE = {k: median(sch) for k in LEVELS}
        report.append(["SCHNAPS L40S-h per unit-simhour", f"{old:.3e} (central)",
                       f"{SCH_GPU_RATE['central']:.3e}", f"{len(sch)} run(s)"])
    erf = []
    for r in rows:
        g = gpu_key(r["hardware"], r.get("instance", ""))
        if r["model"] == "erf" and r["case"] in ERF_BENCH_LEVELS and g in ERF_REL:
            per_gpu = float(r["sim_hours_per_wall_hour"]) / int(r["gpus"])
            colsteps = sum(n * 3600.0 / dt for n, dt in ERF_BENCH_LEVELS[r["case"]])
            erf.append((1.0 / per_gpu) * ERF_REL[g] / colsteps)
    if erf:
        a100_h_per_colstep = median(erf)
        old = WRF_CORES_PER_A100["central"]
        wrf_core_h_per_colstep = WRF_CORE_S_PER_COLSTEP / 3600
        WRF_CORES_PER_A100 = {k: wrf_core_h_per_colstep * WRF_RATE_MULT[k] / a100_h_per_colstep
                              for k in LEVELS}
        report.append(["WRF cores replaced by one A100 (ERF)", f"{old:.0f} (central)",
                       f"{WRF_CORES_PER_A100['central']:.0f}", f"{len(erf)} run(s)"])
    return report

# =============================================================================================
# DOMAINS AND SCENARIOS
# =============================================================================================
ATM_W, ATM_H = box_km(BASIN_LAT_S, BASIN_LAT_N, BASIN_LON_W, BASIN_LON_E, BUFFER_KM)
HYD_W, HYD_H = box_km(BASIN_LAT_S, BASIN_LAT_N, BASIN_LON_W, BASIN_LON_E, 0.0)
FB_W, FB_H = box_km(FULL_BASIN_LAT_S, FULL_BASIN_LAT_N, FULL_BASIN_LON_W, FULL_BASIN_LON_E,
                    BUFFER_KM)
NEST_KM2 = BOISE_SF_MF_KM2 * NEST_RECT_FACTOR
NEST_COLS_250 = math.ceil(NEST_KM2 * 16)
PAR_W, PAR_H = ATM_W + 2 * ERF_PARENT_BUFFER_KM, ATM_H + 2 * ERF_PARENT_BUFFER_KM

SCENARIOS = {
    "a) 4 km": {"sch": [(cols(ATM_W, ATM_H, 4000), 4000.0)],
                "erf": [(cols(ATM_W, ATM_H, 4000), 4000.0)]},
    "b) 1 km": {"sch": [(cols(ATM_W, ATM_H, 1000), 1000.0)],
                "erf": [(cols(PAR_W, PAR_H, ERF_PARENT_DX), ERF_PARENT_DX),
                        (cols(ATM_W, ATM_H, 1000), 1000.0)]},
    "c) 1 km+250 m": {"sch": [(cols(ATM_W, ATM_H, 1000), 1000.0), (NEST_COLS_250, 250.0)],
                      "erf": [(cols(PAR_W, PAR_H, ERF_PARENT_DX), ERF_PARENT_DX),
                              (cols(ATM_W, ATM_H, 1000), 1000.0), (NEST_COLS_250, 250.0)]},
}
HYD_LSM_CELLS = cols(HYD_W, HYD_H, HYDRO_LSM_DX_M)
HYD_RT_CELLS = cols(HYD_W, HYD_H, HYDRO_RT_DX_M)


def compute_scenario(sc, years):
    """Return dict level -> workload numbers for one scenario and period."""
    yrs = years + SPINUP_YEARS
    simh = yrs * HOURS_PER_YEAR
    out = {}
    for lv in LEVELS:
        f = DEV_FACTOR[lv]
        u_s = units(sc["sch"])
        sch_l40s_h = u_s * simh * SCH_GPU_RATE[lv] * (N_MEMBERS - 1) * f
        sch_cpu_h = u_s * simh * SCH_CPU_RATE * (N_MEMBERS - 1) * f
        # WRF core-h: core-s per column-step * columns * steps (dt = 5 s/km * dx_km)
        wrf_core_h = sum(n * (simh * 3600 / (WRF_DT_S_PER_KM * dx / 1000))
                         for n, dx in sc["erf"]) * WRF_CORE_S_PER_COLSTEP / 3600
        wrf_core_h *= WRF_RATE_MULT[lv] * f
        erf_a100_h = wrf_core_h / WRF_CORES_PER_A100[lv]
        hyd_core_h = HYD_RT_CELLS * simh * HYD_RATE[lv] * N_MEMBERS * f
        out[lv] = dict(sch_l40s_h=sch_l40s_h, sch_cpu_h=sch_cpu_h, wrf_core_h=wrf_core_h,
                       erf_a100_h=erf_a100_h, hyd_core_h=hyd_core_h)
    return out


def storage_tb(sc, years):
    yrs = years
    cols_s = sum(n for n, _ in sc["sch"])
    cols_e = sum(n for n, _ in sc["erf"][-2:]) if len(sc["erf"]) > 1 else sc["erf"][0][0]
    if len(sc["erf"]) == 3:          # parent not archived; 1 km + nest
        cols_e = sc["erf"][1][0] + sc["erf"][2][0]
    elif len(sc["erf"]) == 2:
        cols_e = sc["erf"][1][0]
    h, h3, h6 = HOURS_PER_YEAR, HOURS_PER_YEAR / 3, HOURS_PER_YEAR / 6
    sch = cols_s * (SCH_2D[0] * h + SCH_2D[1] * h3) * BYTES * yrs * (N_MEMBERS - 1)
    erf = cols_e * (ERF_2D[0] * h + ERF_3D * ERF_NZ * h6) * BYTES * yrs
    hyd = (HYD_LSM_CELLS * HYD_LDAS_3H * h3 + HYD_RT_CELLS * HYD_RT_DAILY * 365.25
           + HYD_REACHES * HYD_CHRT_VARS * h) * BYTES * yrs * N_MEMBERS
    return {k: v / COMPRESS / 1e12 for k, v in dict(SCHNAPS=sch, ERF=erf, WRFHydro=hyd).items()}


def storage_cost_yr(tb, platform="AWS"):
    gb = tb * 1000
    if platform == "AWS":
        st = gb * 12 * (TIER_MIX["hot"] * S3["Standard"] + TIER_MIX["warm"] * S3["Standard-IA"]
                        + TIER_MIX["cold"] * S3["Deep-Archive"])
        eg = EGRESS_TB_PER_YEAR * 1000 * S3_EGRESS_PER_GB
    else:
        st = gb * 12 * (TIER_MIX["hot"] * GCS["Standard"] + TIER_MIX["warm"] * GCS["Nearline"]
                        + TIER_MIX["cold"] * GCS["Archive"])
        eg = EGRESS_TB_PER_YEAR * 1000 * GCS_EGRESS_PER_GB
    return st, eg


def platform_costs(w, lv):
    """Compute cost in USD (or SU for Jetstream2) for one workload level."""
    r = {}
    # AWS: SCHNAPS on cheapest of L40S/A10G per unit of work; ERF on A100 (p4d); CPU c7a
    for plat in ("AWS", "GCP"):
        for mode, idx in (("on-demand", 0), ("spot", {"low": 1, "central": 2, "high": 3}[lv])):
            p = GPU_PRICES[plat]
            sch_gpu = SCHNAPS_GPU_CHOICE[plat] or min(p, key=lambda g: p[g][idx] / SCHNAPS_REL[g])
            sch = w["sch_l40s_h"] / SCHNAPS_REL[sch_gpu] * p[sch_gpu][idx]
            erf = min(w["erf_a100_h"] / ERF_REL[g] * p[g][idx] for g in p)
            cpu = w["hyd_core_h"] * CPU_PRICE_CORE_H[plat][0 if mode == "on-demand" else 1]
            r[(plat, mode)] = dict(sch=sch, erf=erf, cpu=cpu, total=sch + erf + cpu,
                                   sch_gpu=sch_gpu)
    # Jetstream2: SCHNAPS & ERF on A100 (g3.large / g3.xl: same SU per A100-equivalent)
    su_sch = w["sch_l40s_h"] / SCHNAPS_REL["A100"] * JS2_SU_PER_H["A100"]
    su_erf = w["erf_a100_h"] * JS2_SU_PER_H["A100"]
    su_cpu = w["hyd_core_h"] * JS2_SU_PER_CORE_H
    r[("Jetstream2", "SU")] = dict(sch=su_sch, erf=su_erf, cpu=su_cpu,
                                   total=su_sch + su_erf + su_cpu)
    return r


def js2_wall_years(a100_h, gpu_su, tier, lv):
    """Wall-clock years on Jetstream2.  Quota: g3.large (half A100, 16 vCPU) limited only by the
    GPU vCPU quota (64 by default, scaled by SU/600k); full A100 capped per tier.  Then capped
    again by JS2_REALISTIC_A100_EQ because the hardware is shared."""
    vcpu = JS2_GPU_DEFAULT_VCPU * max(1.0, gpu_su / JS2_GPU_QUOTA_THRESHOLD_SU)
    quota_eq = max(vcpu / 16 * 0.5, min(JS2_FULL_A100_CAP[tier], vcpu / 32))
    a100_eq = min(quota_eq, JS2_REALISTIC_A100_EQ[lv])
    return a100_h / a100_eq / HOURS_PER_YEAR, a100_eq


# =============================================================================================
# REPORT
# =============================================================================================
def main(measured=None):
    report = apply_measured(measured) if measured else []
    print("=" * 96)
    print("SNAKE RIVER CESM-LE DOWNSCALING: COST MODEL (prices retrieved 2026-10-21/22)")
    print("=" * 96)
    if measured:
        if report:
            table(f"MEASURED rates from {measured} replace these assumptions",
                  ["quantity", "assumed", "measured", "from"], report)
        else:
            print(f"\n--measured: no usable GPU Dry Creek rows in {measured}; assumptions kept.")
    table("Geometry", ["item", "value"], [
        ["atmos box incl. 50 km buffer (km)", f"{ATM_W:.0f} x {ATM_H:.0f}"],
        ["  columns at 4 km / 1 km", f"{cols(ATM_W, ATM_H, 4000):,} / {cols(ATM_W, ATM_H, 1000):,}"],
        ["WRF-Hydro box, no buffer (km)", f"{HYD_W:.0f} x {HYD_H:.0f}"],
        ["  1 km LSM cells / 250 m routing cells", f"{HYD_LSM_CELLS:,} / {HYD_RT_CELLS:,}"],
        ["Boise MF+SF area (km2) / nest rect (km2)", f"{BOISE_SF_MF_KM2:,.0f} / {NEST_KM2:,.0f}"],
        ["  250 m nest columns", f"{NEST_COLS_250:,}"],
        ["ERF 4 km parent (km), columns", f"{PAR_W:.0f} x {PAR_H:.0f}, {cols(PAR_W, PAR_H, 4000):,}"],
        ["full-basin box (to 47.3N,119.3W) cost multiplier",
         f"x{(FB_W * FB_H) / (ATM_W * ATM_H):.2f} on atmos columns"],
    ])
    table("Benchmark-derived rates (formula: cost/simhour = rate * sum N_i*(1000/dx_i))",
          ["quantity", "value"], [
        ["Dry Creek units (1-km col-step equiv.)", f"{dry_units:,.0f}"],
        ["SCHNAPS CPU rate (core-h per unit-simhour)", f"{SCH_CPU_RATE:.3e}"],
        ["Wolverine units", f"{wol_units:,.0f}"],
        ["SCHNAPS L40S rate, Wolverine (GPU-h/unit-simh)", f"{SCH_GPU_RATE_WOL:.3e}"],
        ["implied cores per L40S: Wolverine / Standard / geo-mean",
         f"{wol_cores_per_gpu:,.0f} / {STD_CORES_PER_GPU:.0f} / {SCH_CORES_PER_GPU['central']:.0f}"],
        ["WRF core-s per column-step (CONUS404, 51 lev)", f"{WRF_CORE_S_PER_COLSTEP:.2e}"],
        ["WRF-Hydro core-h per 250 m cell per simh (L/C/H)",
         " / ".join(f"{HYD_RATE[k]:.2e}" for k in LEVELS)],
    ])
    # cross-check: SCHNAPS CPU vs WRF at 1 km for the same domain
    n1 = cols(ATM_W, ATM_H, 1000)
    sch_yr = n1 * HOURS_PER_YEAR * SCH_CPU_RATE
    wrf_yr = n1 * HOURS_PER_YEAR * 3600 / (WRF_DT_S_PER_KM) * WRF_CORE_S_PER_COLSTEP / 3600
    print(f"\nCross-check, 1 km box, per member-year: WRF ~{fmt(wrf_yr)} core-h; SCHNAPS (Dry Creek "
          f"CPU rate) ~{fmt(sch_yr)} core-h = 1/{wrf_yr/sch_yr:.0f} of WRF;\n  an ICAR-like 1/140-1/800 "
          f"would be {fmt(wrf_yr/ICAR_WRF_RATIO[0])}-{fmt(wrf_yr/ICAR_WRF_RATIO[1])} core-h. "
          f"Wolverine-rate GPU-h: {n1*HOURS_PER_YEAR*SCH_GPU_RATE_WOL:,.0f} L40S-h.")

    headline, js2_rows = [], []
    for years in (YEARS_MAIN, YEARS_ALT):
        for name, sc in SCENARIOS.items():
            W = compute_scenario(sc, years)
            st = storage_tb(sc, years)
            st_tot = sum(st.values())
            rows = []
            for lv in LEVELS:
                w = W[lv]
                rows.append([lv, fmt(w["sch_l40s_h"]), fmt(w["sch_cpu_h"]), fmt(w["wrf_core_h"]),
                             fmt(w["erf_a100_h"]), fmt(w["hyd_core_h"])])
            table(f"[{name}, {years} yr + {SPINUP_YEARS} spin-up] workload "
                  f"(x dev factor {DEV_FACTOR['low']}/{DEV_FACTOR['central']}/{DEV_FACTOR['high']})",
                  ["level", "SCHNAPS L40S-h", "(SCHNAPS if CPU core-h)", "WRF core-h (mem1)",
                   "ERF A100-h", "WRF-Hydro core-h"], rows)
            print(f"  archive (compressed): SCHNAPS {st['SCHNAPS']:.1f} TB, ERF {st['ERF']:.1f} TB, "
                  f"WRF-Hydro {st['WRFHydro']:.1f} TB, total {st_tot:.1f} TB")
            rows = []
            for lv in LEVELS:
                pc = platform_costs(W[lv], lv)
                for key in (("AWS", "on-demand"), ("AWS", "spot"), ("GCP", "on-demand"),
                            ("GCP", "spot")):
                    c = pc[key]
                    s_cost, e_cost = storage_cost_yr(st_tot, key[0])
                    rows.append([lv, f"{key[0]} {key[1]}", c["sch_gpu"], fmt(c["sch"]),
                                 fmt(c["erf"]), fmt(c["cpu"]), fmt(c["total"]),
                                 fmt(s_cost + e_cost), fmt(c["total"] + s_cost + e_cost)])
                    if years == YEARS_MAIN and lv == "central":
                        headline.append([name, f"{key[0]} {key[1]}", fmt(c["total"]),
                                         f"{st_tot:.0f} TB: {fmt(s_cost + e_cost)}",
                                         fmt(c["total"] + STORAGE_YEARS * (s_cost + e_cost))])
                j = pc[("Jetstream2", "SU")]
                tier = tier_for(j["total"] + st_tot * 1000 * JS2_STORAGE_CREDIT_PER_GB)
                wall, eq = js2_wall_years(W[lv]["erf_a100_h"] + W[lv]["sch_l40s_h"]
                                          / SCHNAPS_REL["A100"], j["sch"] + j["erf"], tier, lv)
                aws_val = pc[("AWS", "on-demand")]["total"]
                rows.append([lv, "Jetstream2 (SU)", "A100", fmt(j["sch"]), fmt(j["erf"]),
                             fmt(j["cpu"]), fmt(j["total"]),
                             f"{min(st_tot, JS2_STORAGE_MAX_TB['Maximize']):.0f}TB cap",
                             f"{tier}; ~{wall:.1f} wall-yr @{eq:.0f} A100-eq; AWS value ${fmt(aws_val)}"])
                if years == YEARS_MAIN and lv == "central":
                    headline.append([name, "Jetstream2", f"{fmt(j['total'])} SU ({tier})",
                                     "ODP $0 / OSN <=50 TB", f"~{wall:.1f} wall-yr; worth ~${fmt(aws_val)}"])
                    js2_rows.append([name, fmt(j["sch"] + j["erf"]), tier_for(j["sch"] + j["erf"]),
                                     fmt(j["cpu"]), fmt(j["total"]), tier])
            table(f"[{name}, {years} yr] cost (USD; Jetstream2 in SU). storage/yr = tiered "
                  f"{TIER_MIX} + {EGRESS_TB_PER_YEAR:.0f} TB egress",
                  ["level", "platform", "SCH GPU", "SCHNAPS", "ERF", "WRF-Hydro CPU",
                   "compute", "storage/yr", "compute+1yr storage / notes"], rows)

    table(f"HEADLINE (central, 2020-2100 + spin-up; USD; compute one-off)",
          ["scenario", "platform", "compute", "archive: storage+egress/yr",
           f"total (compute + {STORAGE_YEARS} yr storage)"], headline)
    table("Jetstream2 tier needed (central, 81 yr): GPU-only (WRF-Hydro on Borah) vs everything",
          ["scenario", "GPU SU (SCHNAPS+ERF)", "tier", "CPU SU (WRF-Hydro)", "all SU",
           "tier (all + storage)"], js2_rows)
    eff = [[f, f"{JS2_SU_PER_H[g]}", f"{SCHNAPS_REL[g]}", f"{JS2_SU_PER_H[g]/SCHNAPS_REL[g]:.0f}",
            note] for f, g, note in (("g3.large", "A100-half", "no per-tier card cap"),
                                     ("g3.xl", "A100", "2-4 cards per project"),
                                     ("g4.xl", "L40S", "NAIRR only (0 for ACCESS tiers)"),
                                     ("g5.xl", "H100", "2 cards, Discover and up"))]
    table("Jetstream2 GPU flavors for SCHNAPS", ["flavor", "SU/h", "rel. speed vs L40S [ASSUME]",
                                                 "SU per L40S-hour", "availability"], eff)

    rows = []
    for tb in (PLAN_TB,):
        for plat in ("AWS", "GCP"):
            s, e = storage_cost_yr(tb, plat)
            rows.append([f"{tb:.0f} TB", plat, fmt(s), fmt(e), fmt(s + e)])
        rows.append([f"{tb:.0f} TB", "AWS all-Standard", fmt(tb * 1000 * 12 * S3["Standard"]),
                     fmt(EGRESS_TB_PER_YEAR * 1000 * S3_EGRESS_PER_GB), "-"])
        rows.append([f"{tb:.0f} TB", "AWS Open Data Sponsorship", "0", "0", "0 (if accepted)"])
    table("Proposal ~100 TB tiered plan, per year", ["size", "option", "storage", "egress",
                                                      "total"], rows)


if __name__ == "__main__":
    if "--measured" in sys.argv:
        i = sys.argv.index("--measured")
        d = sys.argv[i + 1] if len(sys.argv) > i + 1 else os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "bench", "results")
        main(measured=d)
    else:
        main()
