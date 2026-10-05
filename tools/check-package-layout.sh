#!/usr/bin/env bash
# Asserts a packaged zip unpacks to LedgerLink/LedgerLink.toc at its top level and
# holds nothing but the .toc, the files it loads, LICENSE and the packager's
# generated CHANGELOG.md: no nested
# LedgerLink/LedgerLink/, no spec, tools, contract, README or CI files.
# Usage: tools/check-package-layout.sh LedgerLink-<version>.zip
set -euo pipefail

zip="${1:?usage: $0 <zip>}"
entries=$(unzip -Z1 "$zip" | grep -v '/$') # files only
echo "$entries"

if ! grep -qx 'LedgerLink/LedgerLink.toc' <<<"$entries"; then
  echo "FAIL: LedgerLink/LedgerLink.toc is not at the top level" >&2
  exit 1
fi

allowed=$(printf '%s\n' LedgerLink/LedgerLink.toc LedgerLink/LICENSE LedgerLink/CHANGELOG.md
  unzip -p "$zip" LedgerLink/LedgerLink.toc | tr -d '\r' | grep -Ev '^(#|[[:space:]]*$)' | sed -e 's#\\#/#g' -e 's#^#LedgerLink/#')
fail=0

extra=$(grep -vxF -f <(echo "$allowed") <<<"$entries" || true)
[ -z "$extra" ] || { echo "FAIL: files not loaded by the .toc:" >&2; echo "$extra" >&2; fail=1; }
missing=$(grep -vxF -f <(echo "$entries") <<<"$allowed" | grep -Ev '^LedgerLink/(LICENSE|CHANGELOG.md)$' || true)
[ -z "$missing" ] || { echo "FAIL: .toc lists files missing from the zip:" >&2; echo "$missing" >&2; fail=1; }

# The packager must have substituted every @project-...@ keyword (e.g. the version).
leftover=$(unzip -p "$zip" '*.toc' '*.lua' | grep -o '@project-[a-z-]*@' | sort -u || true)
[ -z "$leftover" ] || { echo "FAIL: unsubstituted keywords: $leftover" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "OK: $zip layout"
exit "$fail"
