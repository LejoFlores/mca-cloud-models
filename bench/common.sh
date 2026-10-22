# Sourced by bench/*_drycreek.sh. Container launch, hardware detection and the results CSV.
#
# Environment (all optional):
#   RUNTIME      docker (default) or apptainer
#   IMAGE        docker image ref, or a .sif path for apptainer
#   NGPU         GPUs to use (0 = CPU run)
#   NP           MPI ranks for CPU runs (default: physical cores)
#   INSTANCE     instance/flavor name for the CSV (auto-detected on AWS)
#   PRICE_PER_HOUR, PRICE_UNIT (USD or SU), PRICE_SOURCE   the stated price behind cost_per_sim_hour
#   RESULTS      CSV to append to (default bench/results/<model>.csv)
BENCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNTIME=${RUNTIME:-docker}
NGPU=${NGPU:-0}
CSV_HEADER="date_utc,model,case,hardware,instance,ranks,gpus,sim_hours,wall_seconds,sim_hours_per_wall_hour,price_per_hour,price_unit,price_source,cost_per_sim_hour,image,image_digest,runtime,status,notes"

physical_cores() {
  lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l
}

detect_instance() {
  [ -n "${INSTANCE:-}" ] && { echo "$INSTANCE"; return; }
  # AWS IMDSv2 (1 s timeout; nothing happens off AWS)
  local tok; tok=$(curl -s -m 1 -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
  if [ -n "$tok" ]; then
    curl -s -m 1 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/instance-type && return
  fi
  echo "unknown"
}

detect_hardware() {
  local cpu; cpu=$(lscpu | sed -n 's/^Model name: *//p' | head -1)
  if [ "$NGPU" -gt 0 ] && command -v nvidia-smi >/dev/null; then
    local g; g=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader -i 0 | tr -s ' ')
    echo "${NGPU}x ${g%%,*} (driver${g##*,}); host ${cpu}"
  else
    echo "${cpu} ($(physical_cores) cores)"
  fi
}

image_digest() {
  if [ "$RUNTIME" = apptainer ]; then
    echo "sha256:$(sha256sum "$IMAGE" | cut -d' ' -f1)"
  else
    # RepoDigest once pulled from a registry; otherwise the local image ID
    docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$IMAGE"
  fi
}

# run_in_image <case-dir> <cmd...>: case dir is mounted at /case, bench/ at /bench (read-only)
run_in_image() {
  local case=$1; shift
  if [ "$RUNTIME" = apptainer ]; then
    local nv=(); [ "$NGPU" -gt 0 ] && nv=(--nv)
    apptainer exec "${nv[@]}" --cleanenv --env NGPU=$NGPU,NP=${NP:-} \
      --bind "$case:/case" --bind "$BENCH:/bench:ro" "$IMAGE" "$@"
  else
    local gpus=(); [ "$NGPU" -gt 0 ] && gpus=(--gpus "$NGPU")
    docker run --rm "${gpus[@]}" --ipc=host --ulimit stack=-1 -u "$(id -u):$(id -g)" -e HOME=/tmp \
      -e NGPU=$NGPU -e NP=${NP:-} \
      -v "$case:/case" -v "$BENCH:/bench:ro" "$IMAGE" "$@"
  fi
}

# write_row <model> <case> <ranks> <sim_hours> <wall_seconds> <status> [notes]
write_row() {
  local model=$1 case=$2 ranks=$3 simh=$4 wall=$5 status=$6 notes=${7:-}
  local csv=${RESULTS:-$BENCH/results/$model.csv}
  mkdir -p "$(dirname "$csv")"
  [ -s "$csv" ] || echo "$CSV_HEADER" > "$csv"
  local rate cost=""
  rate=$(python3 -c "print(f'{$simh / ($wall / 3600):.4f}' if $wall > 0 else '')")
  if [ -n "${PRICE_PER_HOUR:-}" ] && [ -n "$rate" ]; then
    cost=$(python3 -c "print(f'{${PRICE_PER_HOUR} / $rate:.4f}')")
  fi
  local row
  row=$(python3 - "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model" "$case" "$(detect_hardware)" "$(detect_instance)" \
    "$ranks" "$NGPU" "$simh" "$wall" "$rate" "${PRICE_PER_HOUR:-}" "${PRICE_UNIT:-USD}" "${PRICE_SOURCE:-}" \
    "$cost" "$IMAGE" "$(image_digest)" "$RUNTIME" "$status" "$notes" <<'EOF'
import csv, io, sys
b = io.StringIO(); csv.writer(b, lineterminator="").writerow(sys.argv[1:]); print(b.getvalue())
EOF
)
  echo "$row" >> "$csv"
  echo "$CSV_HEADER"; echo "$row"
  echo "-> $csv"
}
