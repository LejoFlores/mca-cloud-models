# Running the benchmarks on AWS (g6e.xlarge spot)

How to start a g6e.xlarge (1 NVIDIA L40S) spot instance, get the images onto it, and run
`bench/`. This costs money. Run it only after the PI approves, under an account and budget the PI
names. Never put access keys in this repository. Use `aws configure sso` or a named profile in
`~/.aws/`.

| | g6e.xlarge |
| --- | --- |
| GPU | 1x L40S, 48 GB, compute capability 8.9 |
| vCPU / RAM | 4 / 32 GB |
| Local NVMe | 250 GB instance store (erased on stop or termination) |
| Price, us-west-2 | $1.861/h on demand (AWS Price List, effective 2026-10-01). Spot $1.22-1.83/h in third-party snapshots, so check it live (below) |

Same steps for the other targets: `g5.xlarge` (A10G, cc 8.6; $1.006/h on demand) and
`p4d.24xlarge` (8x A100 40 GB, cc 8.0; $21.96/h). These prices are the ones `cost/cost_model.py` uses.

Images for the L40S:
- SCHNAPS: the GPU image, which already carries cc89.
- ERF: build with `--build-arg CUDA_ARCH=8.9 --build-arg KOKKOS_ARCH=ADA89`. The default sm_80
  image also runs on cc 8.9, but it is not tuned for the L40S, so it is a fair benchmark only for the A100.
- ERF defaults to double precision, and the L40S runs FP64 at 1/64 rate. Expect it to be slow
  for ERF; the cost model's `ERF_REL` already assumes that.

## 1. One-time account setup

- Service quota: spot G instances are limited by "All G and VT Spot Instance Requests" (vCPUs).
  It is often 0 on new accounts. g6e.xlarge needs 4. Request it in Service Quotas for the region.
- Region: us-west-2 (Oregon), which the cost model prices. The HRRR archive lives in us-east-1.
  Reading this public dataset needs no credentials and is not billed to the reader.

## 2. Launch (AWS CLI v2)

```bash
export AWS_PROFILE=<profile-the-PI-approved> AWS_REGION=us-west-2

# Current spot price for the instance type
aws ec2 describe-spot-price-history --instance-types g6e.xlarge \
  --product-descriptions "Linux/UNIX" --start-time $(date -u +%FT%TZ) \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output table

# AWS Deep Learning Base GPU AMI (Ubuntu 22.04): NVIDIA driver, Docker, NVIDIA Container Toolkit
AMI=$(aws ssm get-parameter --name \
  /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
  --query Parameter.Value --output text)

aws ec2 create-key-pair --key-name mca-key --query KeyMaterial --output text > ~/.ssh/mca-key.pem
chmod 600 ~/.ssh/mca-key.pem
SG=$(aws ec2 create-security-group --group-name mca-ssh --description "ssh from PI" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 \
  --cidr $(curl -s https://checkip.amazonaws.com)/32

ID=$(aws ec2 run-instances --image-id $AMI --instance-type g6e.xlarge --count 1 \
  --key-name mca-key --security-group-ids $SG \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}' \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mca-bench-g6e},{Key=project,Value=nsf-mca-2121108}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $ID
IP=$(aws ec2 describe-instances --instance-ids $ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh -i ~/.ssh/mca-key.pem ubuntu@$IP
```

Notes:
- Spot can be interrupted with a 2-minute notice. The Dry Creek 12 h case is short, so just
  rerun it if that happens. An interrupted run leaves no `ok` row, so nothing wrong enters the
  cost model.
- The 200 GB gp3 root volume holds the images (NVHPC is large) and the case. The 250 GB NVMe
  instance store is faster scratch, but it is erased when the instance stops. On the Deep Learning
  AMI it is usually mounted at `/opt/dlami/nvme`; check with `lsblk` and `df -h`.

## 3. On the instance

```bash
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv   # CUDA 12.4 images need >= 550.54.14
git clone https://github.com/LejoFlores/mca-cloud-models.git && cd mca-cloud-models
# images: docker pull from GHCR once the PI approves the push, or build here (about 1 h for the
# GPU images on 4 vCPU; it needs nvcr.io, codeberg.org and git.wsl.ch), or docker load a copy
docker build -f containers/schnaps/Dockerfile.gpu -t schnaps:1.1.1-gpu-cuda12.4 containers/
docker build -f containers/erf/Dockerfile.gpu --build-arg CUDA_ARCH=8.9 --build-arg KOKKOS_ARCH=ADA89 \
  -t erf:5fa15bd-cuda12.4-sm89 containers/
docker run --rm --gpus all schnaps:1.1.1-gpu-cuda12.4 nvidia-smi

export CASE_DIR=/opt/dlami/nvme/drycreek SCHNAPS_BORAH=~/schnaps-borah ERF_BORAH=~/erf-borah
bench/stage_drycreek.sh schnaps erf-hrrr
GEOG_DIR=/opt/dlami/nvme/WPS_GEOG WPS_IMAGE=wps-real:4.6.0-4.7.1 bench/stage_drycreek.sh erf-wps

# State the price you actually paid: the spot price at launch, from describe-spot-price-history
export PRICE_PER_HOUR=<spot $/h> PRICE_UNIT=USD PRICE_SOURCE="EC2 spot us-west-2 <AZ> <date>"
IMAGE=schnaps:1.1.1-gpu-cuda12.4 NGPU=1 VARIANT=50m bench/schnaps_drycreek.sh
IMAGE=erf:5fa15bd-cuda12.4-sm89  NGPU=1 bench/erf_drycreek.sh
python3 cost/cost_model.py --measured
```

`bench/` reads the instance type from the instance metadata service, so `INSTANCE` is filled in
automatically. Copy `bench/results/*.csv` off the instance (`scp`) before terminating it.

## 4. Clean up

```bash
aws ec2 terminate-instances --instance-ids $ID
aws ec2 wait instance-terminated --instance-ids $ID
aws ec2 delete-security-group --group-id $SG
aws ec2 delete-key-pair --key-name mca-key
```

The root volume is deleted with the instance (`DeleteOnTermination`). Check the console for
leftover volumes and snapshots.
