#!/usr/bin/env bash
# Tests for scripts/validate-site-databases.sh. Run from the demo folder.
set -uo pipefail
v=scripts/validate-site-databases.sh; d=tests/site-databases; S="site_a site_b"; fail=0
# shellcheck disable=SC2001
expect() { # expect pass|fail description -- args...
  want=$1; desc=$2; shift 3
  if out=$("$v" "$@" 2>&1); then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then echo "ok   - $desc"; else echo "FAIL - $desc (expected $want)"; echo "$out" | sed 's/^/       /'; fail=1; fi
}
expect pass "example mapping is valid"            -- --sites "$S" migration/site-databases.example.csv
expect fail "duplicate site row"                  -- --sites "$S" $d/duplicate-site.csv
expect fail "two sites share one Acquia DB"       -- --sites "$S" $d/duplicate-source-db.csv
expect fail "a site has no mapping"               -- --sites "$S" $d/missing-site.csv
expect fail "mapping not verified"                -- --sites "$S" $d/unverified.csv
expect fail "MySQL user name over 32 chars"       -- --sites "$S" $d/user-too-long.csv
expect fail "wrong header"                        -- --sites "$S" $d/wrong-header.csv
expect fail "CRLF line endings"                   -- --sites "$S" $d/crlf.csv
expect fail "site not in the site list"           -- --sites "site_a" migration/site-databases.example.csv
expect fail "Acquia DB not in acli output"        -- --sites "$S" --acquia-dbs $d/acquia-dbs-partial.txt migration/site-databases.example.csv
exit $fail
