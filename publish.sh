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
rm -f pubspec.yaml.bak

# --- 6. Update CHANGELOG.md ---
echo ""
echo "Prepending version entry to CHANGELOG.md..."
DATE=$(date +%Y-%m-%d)
CHANGELOG_ENTRY="## $NEW_VERSION — $DATE"
if ! grep -q "## $NEW_VERSION" CHANGELOG.md 2>/dev/null; then
  sed -i.bak "1s/^/$CHANGELOG_ENTRY\n\n- \n\n/" CHANGELOG.md
  rm -f CHANGELOG.md.bak
  echo "Added placeholder entry. Edit CHANGELOG.md now if you want to add details."
  read -rp "Press Enter to continue..."
fi

# --- 7. Run analysis and tests ---
echo ""
echo "Running analysis..."
flutter analyze

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

# --- 10. Git commit and tag ---
echo ""
echo "Committing version bump and tagging..."
git add -A
git commit -m "v$NEW_VERSION"
git tag "v$NEW_VERSION"

# --- 11. Done ---
echo ""
echo "========================================"
echo "  Published traceway v$NEW_VERSION"
echo "========================================"
echo ""
echo "Don't forget to push commits and tags:"
echo "  git push && git push --tags"
