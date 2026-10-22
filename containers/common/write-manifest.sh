#!/bin/bash
# Appends the build facts to /opt/manifest.txt inside the image (CLAUDE.md: record versions in a
# manifest inside each image). Extra "key value" lines can be piped in on stdin.
#   write-manifest.sh <image-name> [extra files to append...]  < extra-lines
set -uo pipefail
M=/opt/manifest.txt
{
  echo "image $1"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "base_image ${BASE_IMAGE:-unknown}"
  echo "os $(. /etc/os-release && echo "$PRETTY_NAME") glibc $(ldd --version | head -1 | awk '{print $NF}')"
  for c in gfortran gcc nvfortran nvcc mpif90 mpicc cmake; do
    command -v $c >/dev/null 2>&1 && echo "$c $($c --version 2>&1 | grep -m1 -E '[0-9]+\.[0-9]+' | tr -s ' ')"
  done
  command -v ompi_info >/dev/null 2>&1 && echo "openmpi $(ompi_info --version 2>/dev/null | head -1)"
  [ -f /opt/deps/STACK_VERSIONS ] && sed 's/^/stack /' /opt/deps/STACK_VERSIONS
  [ -t 0 ] || cat
  shift; for f in "$@"; do [ -f "$f" ] && cat "$f"; done
} >> $M
command -v dpkg-query >/dev/null && dpkg-query -W -f='${Package}=${Version}\n' > /opt/manifest-packages.txt
cat $M
