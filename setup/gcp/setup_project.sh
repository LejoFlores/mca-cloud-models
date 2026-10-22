#!/usr/bin/env bash
# One-time setup of a Google Cloud project for SCHNAPS and ERF benchmarks.
#
# Run in Google Cloud Shell as the project owner, after you have
#   1. created the project and linked a billing account (console: Billing),
#   2. set a budget with email alerts (console: Billing > Budgets & alerts).
#
# It creates two service accounts:
#   bench-vm       the identity benchmark VMs run as; may write to the results bucket only
#   claude-runner  the identity Claude Code uses; may create and delete VMs that run as
#                  bench-vm, and read and write the results bucket, nothing else
#
# Usage: PROJECT_ID=my-project bash setup_project.sh
set -euo pipefail

PROJECT_ID=${PROJECT_ID:?set PROJECT_ID}
REGION=${REGION:-us-central1}
BUCKET=${BUCKET:-${PROJECT_ID}-bench}

gcloud config set project "$PROJECT_ID"
gcloud services enable compute.googleapis.com storage.googleapis.com

# Results bucket. Benchmark VMs write CSVs and logs here; Claude reads them back.
gcloud storage buckets create "gs://$BUCKET" --location="$REGION" --uniform-bucket-level-access

# VM runtime identity
gcloud iam service-accounts create bench-vm --display-name="Benchmark VM runtime"
VM_SA="bench-vm@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$VM_SA" --role=roles/storage.objectAdmin

# Claude Code identity
gcloud iam service-accounts create claude-runner --display-name="Claude Code runner"
RUN_SA="claude-runner@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA" --role=roles/compute.instanceAdmin.v1 --condition=None
gcloud iam service-accounts add-iam-policy-binding "$VM_SA" \
  --member="serviceAccount:$RUN_SA" --role=roles/iam.serviceAccountUser
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$RUN_SA" --role=roles/storage.objectAdmin

cat <<EOF

Done. Next:
  1. Request GPU quota (console: IAM & Admin > Quotas). New projects start at zero.
       GPUs (all regions)                         2
       NVIDIA L4 GPUs, $REGION                    1   (also the Preemptible variant)
       NVIDIA A100 GPUs, $REGION                  1   (also the Preemptible variant)
  2. Create a key for claude-runner:
       gcloud iam service-accounts keys create claude-runner.json --iam-account=$RUN_SA
     Paste the file's contents into the cloud environment's settings as the secret
     GCP_SA_KEY_JSON, then delete the local file:  rm claude-runner.json
     If key creation is refused, your organization blocks service-account keys
     (constraint iam.disableServiceAccountKeyCreation); ask Boise State IT for an exception
     on this project.
  3. Tell Claude: project $PROJECT_ID, region $REGION, bucket gs://$BUCKET.
EOF
