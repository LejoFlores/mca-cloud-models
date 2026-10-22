#!/bin/bash
# ERF at a pinned commit with the submodules the Dry Creek setup needs (erf-borah build/fetch_sources.sh):
# AMReX, Noah-MP, RRTMGP, and EKAT (which brings Kokkos) recursively. Submodule commits are the
# ones the ERF commit records.   fetch_erf.sh <commit> <dest>
set -euo pipefail
# EKAT's own submodules (Catch2, kokkos, ...) use SSH URLs; fetch them over HTTPS instead.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false \
       GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_1=git@github.com:
C=$1; D=$2
git init -q $D && cd $D
git remote add origin https://github.com/erf-model/ERF.git
git fetch -q --depth 1 origin $C && git checkout -q FETCH_HEAD
git submodule update -q --init Submodules/AMReX Submodules/Noah-MP Submodules/RRTMGP
git submodule update -q --init --recursive Submodules/ekat
[ "$(git rev-parse HEAD)" = "$C" ] || { echo "ERF is at $(git rev-parse HEAD), expected $C"; exit 1; }
git submodule status --recursive
