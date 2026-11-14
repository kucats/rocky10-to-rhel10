#!/usr/bin/env bash
# Look for things that must never be committed: non-documentation IPv4
# addresses, private keys, public keys and crypt hashes. Run before pushing.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
hits=$(git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' -- . ':!tools/scan-secrets.sh' \
  | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|127\.0\.0\.1|0\.0\.0\.0')
[ -z "$hits" ] || { echo "== IPv4 addresses outside RFC 5737:"; echo "$hits"; rc=1; }
hits=$(git grep -nE 'BEGIN .*PRIVA''TE KEY|ssh-(rsa|ed25519|dss) AAAA|ecdsa-sha2-[a-z0-9]+ AAAA|\$(6|y|5|2[aby])\$' -- . ':!tools/scan-secrets.sh')
[ -z "$hits" ] || { echo "== keys or password hashes:"; echo "$hits"; rc=1; }
hits=$(git grep -nEi '([0-9a-f]{2}:){5}[0-9a-f]{2}' -- . ':!tools/scan-secrets.sh' | grep -vi '52:54:00:')
[ -z "$hits" ] || { echo "== MAC addresses outside 52:54:00:"; echo "$hits"; rc=1; }
[ $rc = 0 ] && echo "scan: clean"
exit $rc
