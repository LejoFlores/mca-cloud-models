# Running the benchmarks on Jetstream2

How to start a Jetstream2 GPU instance, get the images onto it, and run `bench/`. Creating an
instance spends ACCESS credits (SUs), so do it only once the PI has approved.

Sources: the Jetstream2 documentation source at
[gitlab.com/jetstream-cloud/jetstream2/docs](https://gitlab.com/jetstream-cloud/jetstream2/docs),
commit of 2026-10-13. These pages publish at
[docs.jetstream-cloud.org](https://docs.jetstream-cloud.org): `general/instance-flavors.md`,
`general/featured.md`, `general/docker.md`, `faq/gpu.md`, `ui/exo/create_instance.md`,
`ui/exo/access-instance.md`, `ui/cli/launch.md`, `ui/cli/manage.md`, `ui/cli/security_group.md` and
`ui/cli/managing-ssh-keys.md`.

## Which flavor

| Flavor | vCPU | RAM | GPU | SU/h | Notes |
| --- | --- | --- | --- | --- | --- |
| `g3.large` | 16 | 60 GB | 50% of an A100 (20 GB), NVIDIA vGPU | 32 | Proprietary vGPU driver. Compute is a minimum: it can run faster when the rest of the card is idle, so repeat a benchmark before trusting its number. CUDA debugging and some profiling don't work under vGPU (`faq/gpu.md`) |
| `g3.xl` | 32 | 120 GB | full A100 40 GB, PCI passthrough | 64 | Generic NVIDIA driver, installed at first boot, so the first launch is slow. Don't resize full-card instances |

- Both flavors need a "Jetstream2 GPU" ACCESS allocation, which is separate from Jetstream2 (CPU).
- Both are compute capability 8.0. Use the SCHNAPS GPU image (cc80 is in it) and the ERF image
  built with `CUDA_ARCH=8.0`, the default.
- The root disk is 60 GB on both. The SCHNAPS GPU image, built on NVHPC, is large (the NVHPC
  devel base alone is several GB), so pick a volume-backed root disk of about 200 GB (Exosphere: "Choose a Root
  Disk Size"; CLI: `--boot-from-volume 200`). That storage counts against the allocation's
  storage quota.

## Driver check

Featured images include NVIDIA drivers, Docker and the NVIDIA Container Toolkit. Apptainer comes
from the software collection (`module load apptainer`). The docs don't give driver versions, so
check on the instance:

```bash
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv
```

The CUDA 12.4 images need driver 550.54.14 or newer, or 525.60.13 or newer through CUDA
minor-version compatibility. CUDA 13.1 builds (`NVHPC 26.3`) need driver 580 or newer. Record the
driver; `bench/` writes it into the CSV row.

## Option A: Exosphere (web)

1. Log in at <https://jetstream2.exosphere.app> with ACCESS and pick the GPU allocation.
2. Choose **Create**, then **Instance**. Under **By Type**, choose Ubuntu 22.04 (`Featured-Ubuntu22`).
3. Name it, for example `mca-bench-g3xl`. Choose the flavor `g3.xl` (or `g3.large`), and set a
   custom root disk size of 200 GB (volume-backed).
4. Leave Web Desktop off. Under **Advanced options**, select your SSH public key and leave
   **Public IP** at Automatic.
5. Choose **Create**. When the instance is ready, connect with **Web Shell** or with
   `ssh exouser@<public-ip>`. Exosphere instances use the user `exouser`, and its passphrase is on
   the instance page under **Credentials**.
6. When you are done, **Shelve** it (shelved instances cost no SUs; the disk is kept) or
   **Delete** it.

## Option B: OpenStack CLI

Create an application credential for the GPU allocation in Horizon and download its `openrc`.
The secret is shown only once. Each allocation needs its own credential. Source the file in a
fresh shell; a shell that already sourced another openrc gives "Application credentials cannot
request a scope". Never commit the openrc file.

```bash
pip install python-openstackclient
source ~/app-cred-<allocation>-openrc.sh

openstack keypair create --public-key ~/.ssh/id_ed25519.pub mca-key
openstack security group create --description "ssh and icmp enabled" mca-ssh
openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip <your-ip>/32 mca-ssh
openstack security group rule create --protocol icmp mca-ssh

openstack flavor list | grep g3
openstack image list | grep Featured-Ubuntu22
openstack server create mca-bench-g3xl \
  --flavor g3.xl --image Featured-Ubuntu22 --boot-from-volume 200 \
  --key-name mca-key --security-group mca-ssh --wait
# add --nic net-id=<network> if the allocation has more than one network

openstack floating ip create public
openstack server add floating ip mca-bench-g3xl <floating-ip>
ssh ubuntu@<floating-ip>                 # CLI-created Ubuntu instances use the user "ubuntu"

# afterwards: stop SU charges, or remove everything
openstack server shelve mca-bench-g3xl
openstack server delete mca-bench-g3xl
openstack floating ip delete <floating-ip>
```

Narrow `--remote-ip` to your own address rather than `0.0.0.0/0`.

## On the instance: get the images

Images are not on a registry yet, because pushing to GHCR waits for PI approval. Use one of these:

```bash
git clone https://github.com/LejoFlores/mca-cloud-models.git && cd mca-cloud-models
# (a) once pushed:  docker pull ghcr.io/lejoflores/schnaps:1.1.1-gpu-cuda12.4
# (b) build on the instance (needs nvcr.io, codeberg.org and git.wsl.ch; check with curl first)
docker build -f containers/schnaps/Dockerfile.gpu -t schnaps:1.1.1-gpu-cuda12.4 containers/
docker build -f containers/erf/Dockerfile.gpu -t erf:5fa15bd-cuda12.4-sm80 containers/
docker build -f containers/wps/Dockerfile -t wps-real:4.6.0-4.7.1 containers/
# (c) copy a built image:  docker save IMAGE | zstd > img.tar.zst ; scp ; zstd -dc img.tar.zst | docker load
```

Apptainer instead of Docker:

```bash
module load apptainer
apptainer build schnaps-gpu.sif docker-daemon://schnaps:1.1.1-gpu-cuda12.4
export RUNTIME=apptainer IMAGE=$PWD/schnaps-gpu.sif
```

Check GPU access first:

```bash
docker run --rm --gpus all schnaps:1.1.1-gpu-cuda12.4 nvidia-smi
docker run --rm --gpus all schnaps:1.1.1-gpu-cuda12.4 cat /opt/manifest.txt
```

## Run the benchmark

```bash
# Inputs: the schnaps-borah domain files and namelists (a private repo: use a deploy key or copy
# setup/drycreek over), plus HRRR from AWS. For ERF, also the WPS static geography
# (geog_high_res_mandatory from www2.mmm.ucar.edu, about 29 GB unpacked).
git clone https://github.com/LejoFlores/erf-borah.git ~/erf-borah
export CASE_DIR=/media/volume/data/drycreek SCHNAPS_BORAH=~/schnaps-borah ERF_BORAH=~/erf-borah
bench/stage_drycreek.sh schnaps erf-hrrr
GEOG_DIR=/media/volume/data/WPS_GEOG WPS_IMAGE=wps-real:4.6.0-4.7.1 bench/stage_drycreek.sh erf-wps

# Price: SU per hour from general/instance-flavors.md (g3.xl 64, g3.large 32)
export INSTANCE=g3.xl PRICE_PER_HOUR=64 PRICE_UNIT=SU PRICE_SOURCE="Jetstream2 instance-flavors 2026-10-13"
IMAGE=schnaps:1.1.1-gpu-cuda12.4 NGPU=1 VARIANT=50m bench/schnaps_drycreek.sh
IMAGE=erf:5fa15bd-cuda12.4-sm80  NGPU=1 bench/erf_drycreek.sh
python3 cost/cost_model.py --measured        # uses the rows just written
```

`bench/` detects the instance type only on AWS, so set `INSTANCE` on Jetstream2. On `g3.large`,
the cost model counts the GPU as `A100-half`. Copy `bench/results/*.csv` back and commit the rows.
