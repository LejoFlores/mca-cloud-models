#!/bin/bash
# SCHNAPS unit tests and the Standard integration case (schnaps-borah run/test_cpu.slurm).
#   docker run --rm schnaps:1.1.1-cpu /opt/schnaps/run-tests.sh
# Unit tests run on 4 ranks. The integration runner (tests/scripts/lib/mpi_np.sh) takes
# `nproc --all`, halves it above 8 and clamps it to 2-10, so 4 ranks on a 4-core machine and 10 on
# a Borah node. Test outputs go to the image's
# writable layer (or, under Apptainer, use --writable-tmpfs).
set -uo pipefail
cd ${SCHNAPS_SRC:?}
export OMP_NUM_THREADS=1
ctest --test-dir build -L unit --output-on-failure; u=$?
start=$(date +%s)
ctest --test-dir build -R 'integration\.Standard$' --output-on-failure; s=$?
echo "Standard case: exit $s after $(( $(date +%s) - start )) s"
if [ $s -ne 0 ]; then
  for f in tests/Test_Cases/input/Standard.err tests/Test_Cases/input/Standard.out; do
    [ -f $f ] && { echo "===== tail $f"; tail -n 40 $f; }
  done
fi
[ $u -eq 0 ] && [ $s -eq 0 ] && echo "SCHNAPS TESTS PASSED" || { echo "SCHNAPS TESTS FAILED (unit $u, Standard $s)"; exit 1; }
