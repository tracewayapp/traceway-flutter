#!/usr/bin/env bash
# Prepare the working tree for both pub packages. No commit or publication.
set -eu
version=$1
notes=$2
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$ ]]; then
  echo "Invalid release version: $version" >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/tags/v$version"; then
  echo "Tag v$version already exists" >&2
  exit 1
fi
if ! grep -q '[^[:space:]]' "$notes"; then
  echo "Release notes are empty" >&2
  exit 1
fi
update="$(cd "$(dirname "$0")" && pwd)/update_changelog.sh"
video=packages/traceway_video
sed -i.bak "s/^version: .*/version: $version/" pubspec.yaml "$video/pubspec.yaml"
sed -i.bak "s/^  traceway: .*/  traceway: ^$version/" "$video/pubspec.yaml"
sed -i.bak "s/^const String tracewaySdkVersion = .*/const String tracewaySdkVersion = '$version';/" lib/src/sdk_version.dart
rm -f pubspec.yaml.bak "$video/pubspec.yaml.bak" lib/src/sdk_version.dart.bak
bash "$update" "$version" "$notes"
(cd "$video" && bash "$update" "$version" <(echo "- Compatible with traceway $version."))
