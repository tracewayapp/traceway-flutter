#!/usr/bin/env bash
# export_video_addon.sh DEST [REF]: copies packages/traceway_video as
# committed at REF (HEAD by default) into the new directory DEST, without the
# path override used for development, ready for `dart pub publish`.
#
# The add-on is not published from inside the repository: pub applies the
# repository's ignore files to every package in it, and the root .pubignore
# keeps packages/ out of the traceway package, so in a checkout the add-on's
# own files are hidden ("The pubspec is hidden, probably by .gitignore or
# pubignore"). DEST must therefore be outside the repository.
set -eu
dest=$1
ref=${2:-HEAD}
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "$dest" ]; then
  echo "$dest already exists" >&2
  exit 1
fi
mkdir -p "$dest"
if git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rmdir "$dest"
  echo "$dest is inside a git repository: export to a directory outside it" >&2
  exit 1
fi
git -C "$root" archive --format=tar "$ref:packages/traceway_video" | tar -x -C "$dest"
rm -f "$dest/pubspec_overrides.yaml"
