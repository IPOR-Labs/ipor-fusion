#!/usr/bin/env bash
# Reproducible verification of the vendored transport dependencies (CROSSCHAIN_AUDIT_FIX_PLAN §7).
#
# Recomputes the sha256 of every vendored Solidity file and compares it against the pinned manifest
# `CHECKSUMS.sha256`. Exit code 0 means no unrecorded differences; nonzero means a vendored file was
# added, removed or modified without updating the manifest (and, by policy, README.md).
#
# Usage: contracts/vendor/verify.sh   (run from anywhere)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# 1. Every file in the manifest must still hash identically.
sha256sum -c CHECKSUMS.sha256

# 2. Every vendored .sol (except the local compile-check shim) must appear in the manifest — catches a
#    newly added file that was never recorded.
missing=0
while IFS= read -r f; do
  rel="${f#./}"
  if ! grep -q "  ${rel}\$" CHECKSUMS.sha256; then
    echo "UNRECORDED vendored file (not in CHECKSUMS.sha256): ${rel}" >&2
    missing=1
  fi
done < <(find . -name '*.sol' ! -name 'VendorCompileCheck.sol')

if [ "$missing" -ne 0 ]; then
  echo "Vendor verification FAILED: unrecorded file(s) present." >&2
  exit 1
fi

echo "Vendor verification OK: all vendored files match CHECKSUMS.sha256."
