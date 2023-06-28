#!/bin/bash

set -eox pipefail

# Don't prompt for answers during apt-get install
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y git apt-transport-https ca-certificates tzdata curl

git config --global --add safe.directory /workdir

source buildkite/scripts/export-git-env-vars.sh

MINA_COMMIT_SHA1=$(git rev-parse HEAD)
TYPE_SHAPE_FILE=${MINA_COMMIT_SHA1:0:7}-type_shape.txt
MAX_DEPTH=12

echo "--- Create type shapes git note for commit: ${MINA_COMMIT_SHA1:0:7}"
mina internal dump-type-shapes --max-depth ${MAX_DEPTH} > ${TYPE_SHAPE_FILE}

echo "--- Uploading ${TYPE_SHAPE_FILE} to mina-type-shapes bucket for consumption by the version linter"
gcloud storage cp ${TYPE_SHAPE_FILE} gs://mina-type-shapes

base_branch=${BUILDKITE_PULL_REQUEST_BASE_BRANCH}
pr_branch=${BUILDKITE_BRANCH}
release_branch=$1

echo "--- Run Python version linter with branches: ${pr_branch} ${base_branch} ${release_branch}"
./scripts/version-linter.py ${pr_branch} ${base_branch} ${release_branch}