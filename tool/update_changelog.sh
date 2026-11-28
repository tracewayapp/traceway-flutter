#!/usr/bin/env bash
# update_changelog.sh VERSION NOTES_FILE: dates the release in CHANGELOG.md
# (in the current directory). The notes collected under "## Unreleased" or
# "## VERSION — unreleased" belong to this release: that heading becomes
# "## VERSION — <today>" with NOTES_FILE's lines after it. Without such a
# heading, a new section is put on top.
set -e
VERSION="$1"
NOTES_FILE="$2"
DATE=$(date +%Y-%m-%d)
HEADING="## $VERSION — $DATE"
UNRELEASED='^## (Unreleased|[^ ]+ — unreleased)$'
# A prepared checkout may be validated or prepared again before it is tagged.
if awk -v version="$VERSION" '$1 == "##" && $2 == version && $4 ~ /^[0-9]/ {found=1} END {exit !found}' CHANGELOG.md; then
  exit 0
fi
if grep -Eq "$UNRELEASED" CHANGELOG.md; then
  HEADING="$HEADING" NOTES="$(cat "$NOTES_FILE")" PATTERN="$UNRELEASED" awk '
    !done && $0 ~ ENVIRON["PATTERN"] {
      print ENVIRON["HEADING"]; print ""; print ENVIRON["NOTES"]
      done = 1; next
    }
    { print }
  ' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md
else
  { printf '%s\n\n' "$HEADING"; cat "$NOTES_FILE"; echo; cat CHANGELOG.md; } > CHANGELOG.tmp
  mv CHANGELOG.tmp CHANGELOG.md
fi
