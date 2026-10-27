#!/bin/bash
# =============================================================================
# install-all.sh — run the whole installation, step 00 to 07
# =============================================================================
# usage: scripts/install-all.sh [--from N] [--to N]
#   --from N   start at step N (after fixing a failed step)
#   --to N     stop after step N
# Every step is idempotent, so re-running the whole thing after a failure is
# also fine. Step 05 is interactive (the Nutanix installer UI).
# Total time: roughly 2-3 hours, most of it waiting for OCI and the installer.
# =============================================================================
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FROM=0; TO=7
while [ $# -gt 0 ]; do
  case $1 in
    --from) FROM=$2; shift 2 ;;
    --to)   TO=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
STEPS=(00-prereqs 01-fetch-iso 02-build-iso 03-import-image 04-launch-instance 05-install 06-finalize 07-create-cluster)
START=$(date +%s)
for s in "${STEPS[@]}"; do
  n=$((10#${s%%-*}))
  [ "$n" -lt "$FROM" ] && continue
  [ "$n" -gt "$TO" ] && break
  echo
  echo "#############################################################################"
  echo "# Step $s   ($(date +%H:%M))"
  echo "#############################################################################"
  bash "$HERE/$s.sh" || { echo; echo "Step $s failed. Fix the cause and continue with:  $0 --from $n"; exit 1; }
done
echo
echo "All steps done in $(( ($(date +%s) - START) / 60 )) minutes."
