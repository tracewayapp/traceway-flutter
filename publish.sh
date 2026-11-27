#!/usr/bin/env bash
set -e

# --- 1. Read current version from pubspec.yaml ---
CURRENT_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //')
echo "Current version: $CURRENT_VERSION"

# --- 2. Prompt for new version and validate semver ---
read -rp "Enter new version: " NEW_VERSION

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$ ]]; then
  echo "Error: '$NEW_VERSION' is not a valid version (e.g. 0.1.0 or 1.0.0-beta.1)"
  exit 1
fi

# --- 3. Check dart pub auth ---
echo ""
echo "Checking pub.dev authentication..."
if ! dart pub token list 2>/dev/null | grep -q "pub.dev"; then
  echo "Not logged in to pub.dev. Running dart pub login..."
  dart pub login
fi

# --- 4. Show summary and confirm ---
echo ""
echo "========================================"
echo "  Publish traceway Flutter SDK"
echo "========================================"
echo "  Version: $CURRENT_VERSION → $NEW_VERSION"
echo "  Package: traceway"
echo "  Target:  pub.dev"
echo "========================================"
echo ""
read -rp "Proceed? (y/N) " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# --- 5. Bump version in pubspec.yaml ---
echo ""
echo "Bumping version to $NEW_VERSION..."
sed -i.bak "s/^version: .*/version: $NEW_VERSION/" pubspec.yaml
sed -i.bak "s/^const String tracewaySdkVersion = .*/const String tracewaySdkVersion = '$NEW_VERSION';/" lib/src/sdk_version.dart
# The video add-on ships with the same version.
sed -i.bak "s/^version: .*/version: $NEW_VERSION/" packages/traceway_video/pubspec.yaml
rm -f pubspec.yaml.bak lib/src/sdk_version.dart.bak packages/traceway_video/pubspec.yaml.bak

# --- 6. Update CHANGELOG.md ---
echo ""
echo "What changed in this version? (one change per line, empty line to finish):"
CHANGES=""
while true; do
  read -rp "  - " CHANGE
  if [[ -z "$CHANGE" ]]; then
    break
  fi
  CHANGES="$CHANGES- $CHANGE\n"
done

if [[ -z "$CHANGES" ]]; then
  echo "Error: at least one changelog entry is required."
  exit 1
fi

NOTES_FILE=$(mktemp)
echo -e "$CHANGES" > "$NOTES_FILE"
# "## Unreleased" or "## $NEW_VERSION — unreleased" becomes this release's
# heading; there is never a second one.
bash tool/update_changelog.sh "$NEW_VERSION" "$NOTES_FILE"
rm -f "$NOTES_FILE"
echo ""
echo "CHANGELOG.md updated."

# --- 6b. Commit version bump before publish ---
echo ""
echo "Committing version bump and changelog..."
git add pubspec.yaml CHANGELOG.md lib/src/sdk_version.dart packages/traceway_video/pubspec.yaml
git commit -m "v$NEW_VERSION"

# --- 7. Run analysis and tests ---
echo ""
echo "Running analysis..."
flutter analyze --no-fatal-infos

echo ""
echo "Running tests..."
flutter test

# --- 8. Dry run ---
echo ""
echo "Running publish dry run..."
dart pub publish --dry-run

echo ""
read -rp "Dry run passed. Publish for real? (y/N) " CONFIRM2
if [[ "$CONFIRM2" != "y" && "$CONFIRM2" != "Y" ]]; then
  echo "Aborted. Version bump is still in pubspec.yaml — revert if needed."
  exit 0
fi

# --- 9. Publish ---
echo ""
echo "Publishing to pub.dev..."
dart pub publish --force

# --- 10. Git tag ---
echo ""
echo "Tagging v$NEW_VERSION..."
git tag "v$NEW_VERSION"

# --- 11. Done ---
echo ""
echo "========================================"
echo "  Published traceway v$NEW_VERSION"
echo "========================================"
echo ""
echo "Publish the video add-on with the same version once traceway is live:"
echo "  (cd packages/traceway_video && dart pub publish)"
echo ""
echo "Don't forget to push commits and tags:"
echo "  git push && git push --tags"
