#!/usr/bin/env bash
#
# Copy the files the chart mounts out of the tree they belong to.
#
# Helm cannot read outside a chart directory, so charts/promovolve/files/ holds
# copies of files whose originals live elsewhere in this repository. Copies
# drift. Upstream avoided the problem by having kustomize reference the
# originals in place -- which is why its base needs
# `--load-restrictor LoadRestrictionsNone`, a flag that turns off the check
# stopping a kustomization from reading arbitrary paths.
#
# So the copies stay, and this script plus a CI step makes drift loud instead:
#
#   ./charts/sync-files.sh
#   git diff --exit-code charts/promovolve/files/
#
# A pull request that edits an original and not its copy fails there rather
# than deploying yesterday's configuration.
set -euo pipefail

cd "$(dirname "$0")/.."

dest=charts/promovolve/files
mkdir -p "$dest"

# The HOCON overlay the api pods load, and the debug logging config that
# api.debugLogging mounts.
cp k8s/application-app.conf "$dest/"
cp k8s/application-single.conf "$dest/"
cp k8s/logback-debug.xml "$dest/"

# Only read when postgresql.bundled is true. Kept in sync anyway: a bundled
# database that initialises from a stale schema is worse than one that does not
# start.
cp docker/init-db.sql "$dest/"

echo "synced $(ls -1 "$dest" | wc -l | tr -d ' ') files into $dest"
