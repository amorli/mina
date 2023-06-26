#!/bin/bash

set -eox pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <release-branch>"
    exit 1
fi

source ~/.profile

echo "--- Make build"
export LIBP2P_NIXLESS=1 PATH=/usr/lib/go/bin:$PATH GO=/usr/lib/go/bin/go
time make build

base_branch=${BUILDKITE_PULL_REQUEST_BASE_BRANCH}
pr_branch=${BUILDKITE_BRANCH}
release_branch=$1

echo "--- Run Python version linter"
./scripts/version-linter.py ${pr_branch} ${base_branch} ${release_branch}