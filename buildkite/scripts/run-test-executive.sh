#!/bin/bash
set -o pipefail -x

TEST_NAME="$1"
MINA_IMAGE="gcr.io/o1labs-192920/mina-daemon-instrumented:$MINA_DOCKER_TAG-berkeley"
ARCHIVE_IMAGE="gcr.io/o1labs-192920/mina-archive-instrumented:$MINA_DOCKER_TAG-berkeley"

if [[ "${TEST_NAME:0:15}" == "block-prod-prio" ]] && [[ "$RUN_OPT_TESTS" == "" ]]; then
  echo "Skipping $TEST_NAME"
  exit 0
fi

./test_executive.exe cloud "$TEST_NAME" \
  --mina-image "$MINA_IMAGE" \
  --archive-image "$ARCHIVE_IMAGE" \
  --mina-automation-location ./automation \
  --generate-coverage \
  | tee "$TEST_NAME.test.log" \
  | ./logproc.exe -i inline -f '!(.level in ["Debug", "Spam"])'
