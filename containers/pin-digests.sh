#!/bin/bash
# Print the current digest of every base image the Dockerfiles use, to pin them (CLAUDE.md:
# base images by digest). Needs registry access; nvcr.io needs no login for these public images.
#   containers/pin-digests.sh
set -u
for ref in \
  ubuntu:22.04 \
  nvidia/cuda:12.4.1-devel-ubuntu22.04 nvidia/cuda:12.4.1-runtime-ubuntu22.04 \
  nvidia/cuda:12.8.1-devel-ubuntu22.04 nvidia/cuda:12.8.1-runtime-ubuntu22.04 \
  nvcr.io/nvidia/nvhpc:24.5-devel-cuda12.4-ubuntu22.04 \
  nvcr.io/nvidia/nvhpc:26.3-devel-cuda13.1-ubuntu24.04; do
  d=$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
  printf '%-58s %s\n' "$ref" "${d:-UNREACHABLE}"
done
