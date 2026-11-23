#!/bin/sh
# Parquet's page decoder fuzzed (ADR-0112 §5): src/s3/parquet_fuzz_tests.cee's pagesFuzzed, built with ASan and UBSan,
# for SECONDS (default 600) from SEED (default 1). `ceesafec test` runs it for 1500 mutants without the sanitizers.
#   tools/page_fuzz.sh [SECONDS] [SEED]          (CEESAFEC=<compiler>, default ceesafec on PATH)
set -e
SECONDS_TO_RUN="${1:-600}"
SEED="${2:-1}"
cd "$(dirname "$0")/.."
COSMO_PAGE_FUZZ_SECONDS="$SECONDS_TO_RUN" COSMO_PAGE_FUZZ_SEED="$SEED" ASAN_OPTIONS=detect_leaks=0 \
    "${CEESAFEC:-ceesafec}" test --filter pagesFuzzed --timeout $((SECONDS_TO_RUN + 600)) --show-output \
    --cflag -O1 --cflag -g --cflag -fsanitize=address,undefined --cflag -fno-sanitize-recover=all
