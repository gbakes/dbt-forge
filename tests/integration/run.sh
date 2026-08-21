#!/usr/bin/env bash
# Drives the lineage end-to-end test in headless Neovim.
# Exits non-zero if any check fails.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for suite in lineage_e2e lineage_float_e2e; do
  nvim --headless --clean \
    --cmd "set runtimepath+=${repo_root}" \
    -l "${repo_root}/tests/integration/${suite}.lua"
done
