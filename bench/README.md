# bench/

There is one script per model. Each runs a fixed case in a container and appends one CSV row to
`bench/results/<model>.csv`, which `cost/cost_model.py --measured` reads.

| Script | Case | Grids |
| --- | --- | --- |
| `schnaps_drycreek.sh` | Dry Creek, 2015-12-18 18Z to 2015-12-19 06Z (12 simulated hours, the storm's wettest window, as in erf-borah) | `VARIANT=50m` (default): 1 km 123x123 + 250 m 111x112 + 50 m 227x268 with Noah-MP snow (`drycreek_dec2015_50m_noahmp`), the same footprint as ERF. `VARIANT=250m`: 1 km + 250 m with SNOWPACK (`drycreek_dec2015`), the case behind Borah's 13 sim-h/wall-h CPU figure |
| `erf_drycreek.sh` | same window | 1 km 123x123 -> 250 m 128x136 -> 50 m 240x280 static refinement, 60 levels (erf-borah `setup/inputs_drycreek`). `CASE=smoke` instead runs ERF's 20-step Radiation regression test, to check the harness |

## Stage the inputs

```bash
git clone git@github.com:LejoFlores/schnaps-borah.git ~/schnaps-borah    # private
git clone https://github.com/LejoFlores/erf-borah.git ~/erf-borah
export CASE_DIR=/data/drycreek SCHNAPS_BORAH=~/schnaps-borah ERF_BORAH=~/erf-borah
bench/stage_drycreek.sh schnaps     # domains + namelists, and 13 hourly HRRR forcing files (~70 MB)
bench/stage_drycreek.sh erf-hrrr    # 13 HRRR GRIB2 hours for WPS (~420 MB each; ~3.5 MB with wgrib2 on PATH)
GEOG_DIR=/data/WPS_GEOG WPS_IMAGE=wps-real:4.6.0-4.7.1 bench/stage_drycreek.sh erf-wps
```

- **HRRR.** Both models use the same source: the public AWS bucket `noaa-hrrr-bdp-pds`, taking the
  6 h forecast valid each hour (falling back to 7-9 h), as on Borah. No AWS account is needed.
  The scripts are schnaps-borah `setup/hrrr_forcing.py` (SCHNAPS netCDF, cropped to
  42.7-44.7 N, 117.6-114.8 W) and erf-borah `setup/hrrr_wps.py` (GRIB2 records for `Vtable.raphrrr`).
  The Python steps make a venv in `$CASE_DIR/.venv` with numpy, netCDF4, requests and eccodes.
  Set `PYTHON=` to use an existing interpreter instead.
- **Domain files.** schnaps-borah `setup/drycreek/domains/` holds both the 250 m pair and the
  50 m set, built from Copernicus GLO-30 and ESA WorldCover (see its `setup/README.md`). They are
  copied, not regenerated.
- **WPS static data.** geogrid needs the WRF geography (`geog_high_res_mandatory`, from
  www2.mmm.ucar.edu), unpacked into `GEOG_DIR`. erf-borah's `setup/schnaps_topo_to_wps.py`
  optionally adds SCHNAPS's 30 m terrain; then set `GEOGRES=schnaps_topo+default` and `GEOGRID_TBL`.
  The full set is 2.8 GB to download and about 29 GB unpacked. Dry Creek needs 149 MB of it:
  list the tarball, unpack the `index` files, then unpack only the tiles over the domain:
  ```bash
  tar tzf geog_high_res_mandatory.tar.gz | grep -v '/\._' > members.txt
  tar xzf geog_high_res_mandatory.tar.gz -C $GEOG_PARENT --wildcards '*/index'
  python3 bench/geog_subset.py members.txt $GEOG_PARENT 42.0 -118.3 45.4 -114.1 > keep.txt
  tar xzf geog_high_res_mandatory.tar.gz -C $GEOG_PARENT -T keep.txt   # GEOG_DIR=$GEOG_PARENT/WPS_GEOG
  ```
- **Crop HRRR before WPS.** Put `wgrib2` on PATH for `erf-hrrr`. Without it, ungrib writes full-CONUS
  intermediate files of 4.2 GB per hour (about 55 GB for the 12 h window). Cropped, the 13 hours
  take 45 MB.
- **Sea-level pressure.** `inner/wps_real.sh` maps PMSL to HRRR's PRMSL (GRIB2 0/3/1), the field
  `hrrr_wps.py` fetches, because `Vtable.raphrrr` expects MSLMA (0/3/198). Without PMSL, real.exe
  4.7.1 stops with "pal, linear is about as low as we go".
- **`diff_opt` and `km_opt`.** WRF 4.7.1 real.exe refuses a namelist that lacks either. erf-borah's
  `setup/namelist.input` sets neither. They choose WRF's own turbulence closure, which ERF does not
  use, but the template needs them before real.exe runs. Pick values in erf-borah; the 2026-10-22 staging used
  `diff_opt = 2, 2, 2` and `km_opt = 4, 4, 2` in the staged copy only.

Layout after staging:

```
$CASE_DIR/schnaps/{domains/*.nc, drycreek_dec2015*.nml, forcing/hrrr_YYYYMMDD_HH.nc}
$CASE_DIR/erf/{hrrr/*.grib2, setup/namelist.{wps,input}, inputs_drycreek, namelist.erf,
               wrfinput_d01..d03, wrfbdy_d01}
$CASE_DIR/runs/<run>/          one directory per benchmark run, with logs and result.env
```

## Run

```bash
IMAGE=schnaps:1.1.1-gpu-cuda12.4 NGPU=1 bench/schnaps_drycreek.sh
IMAGE=schnaps:1.1.1-cpu NP=33 VARIANT=250m bench/schnaps_drycreek.sh     # 32 compute + 1 I/O rank, as on Borah
IMAGE=erf:5fa15bd-cuda12.4-sm80 NGPU=1 bench/erf_drycreek.sh
RUNTIME=apptainer IMAGE=$PWD/erf-gpu.sif NGPU=1 bench/erf_drycreek.sh
```

Variables (see `common.sh`):

| Variable | Meaning |
| --- | --- |
| `RUNTIME` | `docker` (default) or `apptainer` |
| `IMAGE` | Docker image, or a `.sif` path |
| `NGPU` | GPUs to use. `0` runs on the CPU |
| `NP` | MPI ranks for CPU runs (default: physical cores). SCHNAPS counts its I/O rank in this |
| `INSTANCE` | Flavor or instance type for the CSV. Read automatically on AWS |
| `PRICE_PER_HOUR`, `PRICE_UNIT`, `PRICE_SOURCE` | The stated price behind `cost_per_sim_hour`: instance price per hour, `USD` or `SU`, and where it came from |
| `START`, `END` | Override the simulated window |

Wall time is the model's `mpirun`, measured inside the container. Container start-up and staging
are excluded, except for `CASE=smoke`.

## CSV columns (`results/<model>.csv`)

`date_utc, model, case, hardware, instance, ranks, gpus, sim_hours, wall_seconds,
sim_hours_per_wall_hour, price_per_hour, price_unit, price_source, cost_per_sim_hour, image,
image_digest, runtime, status, notes`

- `hardware` comes from `nvidia-smi` (GPU name and driver) or `lscpu`.
- `image_digest` is the registry digest when the image was pulled, the local image ID otherwise,
  or the SIF file's sha256.
- `status` is `ok` only when the run exited 0 and wrote output. Other rows stay in the file as a
  record, and the cost model ignores them.

## Feeding the cost model

```bash
python3 cost/cost_model.py --measured            # reads bench/results/*.csv
python3 cost/cost_model.py --measured other/dir
```

The cost model uses `ok` GPU rows for the `drycreek_dec2015_12h_*` cases (median per model). It
replaces two assumptions:

1. SCHNAPS's L40S rate, which otherwise comes from the Wolverine and Standard cases.
2. ERF's "WRF cores per A100", which otherwise comes from Lattanzi et al.

Each measured rate is normalized by the domain's column-steps and by the measured GPU's relative
speed (`SCHNAPS_REL` and `ERF_REL`), so it carries over to the Snake River scenarios as before.
Without `--measured` the output is unchanged (`cost/output.txt`).
