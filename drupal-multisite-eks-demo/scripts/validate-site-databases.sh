#!/usr/bin/env bash
# Validate the site-to-database mapping used by the runbook (Phases 3, 14 and 17).
#
# Usage: scripts/validate-site-databases.sh [--sites "site_a site_b"] [--acquia-dbs FILE] CSV
#
#   --sites       Site directories that must each appear exactly once (default: $SITES).
#   --acquia-dbs  File with one real Acquia database name per line, for example from
#                 `acli api:environments:database-list APP.ENV | jq -r '.[].name'`.
#                 Every acquia_database in the CSV must be in this list.
#
# Exit status is 0 only when every check passes. Every problem is reported, not just the first.
set -euo pipefail

sites="${SITES:-}"; acquia_dbs=""; csv=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sites) sites="$2"; shift 2 ;;
    --acquia-dbs) acquia_dbs="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) csv="$1"; shift ;;
  esac
done
[ -n "$csv" ] || { echo "usage: $0 [--sites LIST] [--acquia-dbs FILE] CSV" >&2; exit 2; }
[ -f "$csv" ] || { echo "ERROR: $csv not found" >&2; exit 2; }
[ -z "$acquia_dbs" ] || [ -f "$acquia_dbs" ] || { echo "ERROR: $acquia_dbs not found" >&2; exit 2; }

awk -F, -v sites="$sites" -v dbfile="$acquia_dbs" '
  function err(msg) { printf "ERROR line %d: %s\n", NR, msg; bad++ }
  BEGIN {
    if (dbfile != "") while ((getline l < dbfile) > 0) { gsub(/[ \t\r]/, "", l); if (l != "") known[l] = 1 }
    n = split(sites, want, /[ \t]+/)
    for (i = 1; i <= n; i++) if (want[i] != "") wanted[want[i]] = 1
  }
  /\r$/ { err("Windows line ending (CRLF); save the file with LF endings"); sub(/\r$/, "") }
  NR == 1 {
    if ($0 != "site,acquia_database,target_database,verified_on")
      err("header must be: site,acquia_database,target_database,verified_on")
    next
  }
  /^[ \t]*$/ { err("blank line"); next }
  {
    if (NF != 4) { err("expected 4 columns, found " NF); next }
    site = $1; src = $2; dst = $3; when = $4; rows++
    if (site !~ /^[a-z0-9_]+$/)          err("site \"" site "\" must be a lowercase site directory name")
    if (src !~ /^[A-Za-z0-9_]{1,64}$/)   err("acquia_database \"" src "\" is not a valid MySQL database name")
    if (dst !~ /^[A-Za-z0-9_]{1,64}$/)   err("target_database \"" dst "\" is not a valid MySQL database name")
    if (length(dst "_user") > 32)        err("target_database \"" dst "\" is too long: the user " dst "_user exceeds MySQL'"'"'s 32 characters")
    if (when !~ /^20[0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/)
      err("site " site " is not verified: verified_on must be a YYYY-MM-DD date")
    if (site in seen_site) err("site " site " appears more than once (also line " seen_site[site] ")"); else seen_site[site] = NR
    if (src in seen_src)   err("acquia_database " src " is mapped twice (also line " seen_src[src] ")"); else seen_src[src] = NR
    if (dst in seen_dst)   err("target_database " dst " is mapped twice (also line " seen_dst[dst] ")"); else seen_dst[dst] = NR
    if (dbfile != "" && !(src in known)) err("acquia_database " src " is not in " dbfile)
    if (n > 0 && !(site in wanted))      err("site " site " is not in the site list (" sites ")")
  }
  END {
    for (s in wanted) if (!(s in seen_site)) { printf "ERROR: site %s has no database mapping\n", s; bad++ }
    if (rows == 0) { print "ERROR: no mappings found"; bad++ }
    if (bad) { printf "FAILED: %d problem(s) in %s\n", bad, FILENAME; exit 1 }
    printf "OK: %d site(s) mapped, each to exactly one verified database\n", rows
  }
' "$csv"
