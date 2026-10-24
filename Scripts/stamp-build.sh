#!/bin/sh
# Stamps the built Info.plist with the commit count as the build number, plus the short SHA.
# Runs on the *built* copy, so the repository is never dirtied by a build.
set -e

cd "$SRCROOT" || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

count=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
# A trailing + means the build carried uncommitted changes.
[ -n "$(git status --porcelain)" ] && commit="${commit}+"

plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$plist" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $count" "$plist"
/usr/libexec/PlistBuddy -c "Set :KeoCommit $commit" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :KeoCommit string $commit" "$plist"

echo "note: build $count ($commit)"
