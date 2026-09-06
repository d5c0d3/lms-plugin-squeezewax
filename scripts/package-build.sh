#!/usr/bin/env bash
#
# scripts/package-build.sh — build and package SqueezeWax for distribution.
#
# Implements docs/dev-repo-workflow.md. Builds SqueezeWax/ at the current git
# commit (via `git archive HEAD`, so an uncommitted edit is never silently
# packaged), zips it, hashes it, and writes repo.xml pointing at that zip.
#
# This never renames anything. SqueezeWax ships as itself on every branch:
# Slim::Utils::ExtensionsManager::findUpdates keys candidates by plugin name
# across every configured repository and keeps whichever has the higher
# version, regardless of which repo it came from
# (Slim/Utils/ExtensionsManager.pm:366-401, public/9.1 — the merge happens in
# appsQuery at :261-286, which flattens every configured repo's results into
# one list before findUpdates ever runs). A second, differently-named package
# doesn't avoid a collision under that mechanism; it just hides one, and only
# once did anyone run both at once. See docs/dev-repo-workflow.md §1-2.
#
# Usage:
#   scripts/package-build.sh [--dry-run] [--publish]
#
# --dry-run   Build in a temp dir only. Never writes repo.xml or dist/*.zip to
#             disk — prints the file tree, a leftover-naming grep, and
#             `unzip -l` so the artifact can be inspected before it exists
#             anywhere.
# --publish   After building, `git add`/`commit`/`push` repo.xml and the new
#             zip. Without this flag the script never calls git — the files
#             land on disk uncommitted for review. Mutually exclusive with
#             --dry-run.
#
# The <url> this script writes is always the raw.githubusercontent.com URL
# for the *current* branch — GitHub Pages only serves the default branch, so
# a feature branch's zip is unreachable there. A release repo.xml pointing at
# Pages is a separate, later, explicitly-scripted step that doesn't exist yet
# because SqueezeWax has not shipped (docs/dev-repo-workflow.md §5).

set -euo pipefail

DRY_RUN=0
PUBLISH=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--publish) PUBLISH=1 ;;
		*)
			echo "error: unknown argument: $arg" >&2
			exit 1
			;;
	esac
done

if [ "$DRY_RUN" -eq 1 ] && [ "$PUBLISH" -eq 1 ]; then
	echo "error: --dry-run and --publish are mutually exclusive" >&2
	exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

NAME="SqueezeWax"
REAL_INSTALL_XML="$REPO_ROOT/${NAME}/install.xml"
REPO_XML="$REPO_ROOT/repo.xml"
DIST_DIR="$REPO_ROOT/dist"

GH_USER="d5c0d3"
GH_REPO="lms-plugin-squeezewax"
GH_BRANCH="$(git branch --show-current)"

if [ ! -f "$REAL_INSTALL_XML" ]; then
	echo "error: $REAL_INSTALL_XML not found" >&2
	exit 1
fi

# --- 1. Build from SqueezeWax/ at the current commit into a temp dir --------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/squeezewax-build.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

COMMIT="$(git rev-parse --short HEAD)"
echo "==> Extracting ${NAME}/ from commit ${COMMIT} into ${TMP_DIR}"
git archive HEAD -- "${NAME}" | tar -x -C "$TMP_DIR"

BUILD_DIR="$TMP_DIR/$NAME"
if [ ! -d "$BUILD_DIR" ]; then
	echo "error: git archive produced no ${NAME}/ at HEAD — is it committed?" >&2
	exit 1
fi

# --- 2. Bump the version -----------------------------------------------------
if [ -f "$REPO_XML" ]; then
	CUR_VERSION="$(perl -ne 'print $1 and exit if /<plugin\b[^>]*\bversion="([^"]+)"/' "$REPO_XML")"
	if [ -z "${CUR_VERSION:-}" ]; then
		echo "error: could not find version=\"...\" in $REPO_XML" >&2
		exit 1
	fi
else
	echo "==> No repo.xml yet — bootstrapping at 0.0.0.0 (first build will be 0.0.0.1)"
	CUR_VERSION="0.0.0.0"
fi

NEW_VERSION="$(perl -e '
	my @p = split /\./, $ARGV[0];
	$p[-1]++;
	print join(".", @p);
' "$CUR_VERSION")"

echo "==> Version: ${CUR_VERSION} -> ${NEW_VERSION}"

# Only the packaged (temp, git-archived) copy's <version> is bumped — the
# committed SqueezeWax/install.xml is left at its own value. The 0.0.0.N
# series tracked here is a build/test artifact, disconnected from
# install.xml's own version until SqueezeWax's first real release, per
# docs/dev-repo-workflow.md §5.
BUILD_INSTALL_XML="$BUILD_DIR/install.xml"
perl -pi -e "s#(<version>)[^<]*(</version>)#\${1}${NEW_VERSION}\${2}#" "$BUILD_INSTALL_XML"

# Read minVersion/maxVersion/category from the packaged commit's own
# install.xml (not the live working tree, which can disagree on an
# uncommitted edit) so repo.xml can't silently drift from what's shipping.
MIN_TARGET="$(perl -ne 'print $1 and exit if /<minVersion>([^<]*)<\/minVersion>/' "$BUILD_INSTALL_XML")"
MAX_TARGET="$(perl -ne 'print $1 and exit if /<maxVersion>([^<]*)<\/maxVersion>/' "$BUILD_INSTALL_XML")"
CATEGORY="$(perl -ne 'print $1 and exit if /<category>([^<]*)<\/category>/' "$BUILD_INSTALL_XML")"

for v in "$MIN_TARGET" "$MAX_TARGET" "$CATEGORY"; do
	if [ -z "$v" ]; then
		echo "error: could not read minVersion/maxVersion/category out of $BUILD_INSTALL_XML" >&2
		exit 1
	fi
done

# Title/desc: repo.xml wants literal display text, not the PLUGIN_* string
# tokens install.xml carries, so read the EN lines out of the packaged
# commit's own strings.txt.
BUILD_STRINGS="$BUILD_DIR/strings.txt"
TITLE="$(perl -ne '$b=1 if /^PLUGIN_SQUEEZEWAX_NAME$/; if ($b && /^\tEN\t(.+)$/) { print $1; exit } $b=0 if /^\S/ && !/^PLUGIN_SQUEEZEWAX_NAME$/' "$BUILD_STRINGS")"
DESC="$(perl -ne '$b=1 if /^PLUGIN_SQUEEZEWAX_DESC$/; if ($b && /^\tEN\t(.+)$/) { print $1; exit } $b=0 if /^\S/ && !/^PLUGIN_SQUEEZEWAX_DESC$/' "$BUILD_STRINGS")"

for v in "$TITLE" "$DESC"; do
	if [ -z "$v" ]; then
		echo "error: could not read PLUGIN_SQUEEZEWAX_NAME/DESC EN text out of $BUILD_STRINGS" >&2
		exit 1
	fi
done

# --- 3. Zip -------------------------------------------------------------------
# Filename uses underscores, not dots — matches the reference project's
# released zips (FilterMusic_2_3_1.zip) — and carries the version, per the
# official packaging requirement, so LMS doesn't reuse a cached copy on
# "upgrade."
VERSION_SLUG="${NEW_VERSION//./_}"
ZIP_NAME="${NAME}_${VERSION_SLUG}.zip"
( cd "$TMP_DIR" && zip -r -q "$ZIP_NAME" "$NAME" )
ZIP_PATH="$TMP_DIR/$ZIP_NAME"
echo "==> Zipped ${ZIP_NAME}"

# --- 4. Hash ------------------------------------------------------------------
# sha1sum's digest is what LMS's Extension Downloader verifies before
# extracting — confirmed against a real install (docs/dev-repo-workflow.md §5).
SHA1="$(sha1sum "$ZIP_PATH" | awk '{print $1}')"
echo "==> sha1: ${SHA1}"

# --- 5. Verification (always printed, dry-run or not) ------------------------
echo
echo "==> Build file tree:"
find "$BUILD_DIR" -type f | sed "s#^${TMP_DIR}/##" | sort

echo
echo "==> grep -ri squeezewaxdev over the build (no matches expected — nothing renames anymore):"
grep -ri squeezewaxdev -r "$BUILD_DIR" || echo "(no matches)"

echo
echo "==> Zip contents:"
unzip -l "$ZIP_PATH"

if [ "$DRY_RUN" -eq 1 ]; then
	echo
	echo "==> --dry-run: not writing repo.xml or dist/${ZIP_NAME} to disk."
	exit 0
fi

# --- 6. Write repo.xml --------------------------------------------------------
ZIP_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/dist/${ZIP_NAME}"
ISSUES_URL="https://github.com/${GH_USER}/${GH_REPO}/issues"

cat > "$REPO_XML" <<XML
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">${GH_USER} plug-in repository</title>
	</details>
	<plugins>
		<plugin name="${NAME}" version="${NEW_VERSION}" minTarget="${MIN_TARGET}" maxTarget="${MAX_TARGET}">
			<title lang="EN">${TITLE}</title>
			<desc lang="EN">${DESC}</desc>
			<creator>${GH_USER}</creator>
			<category>${CATEGORY}</category>
			<url>${ZIP_URL}</url>
			<link>${ISSUES_URL}</link>
			<sha>${SHA1}</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "==> Wrote ${REPO_XML} (branch: ${GH_BRANCH})"

# --- 7. Move the zip into dist/ ----------------------------------------------
mkdir -p "$DIST_DIR"
cp "$ZIP_PATH" "$DIST_DIR/$ZIP_NAME"
echo "==> Copied zip to ${DIST_DIR}/${ZIP_NAME}"

# --- 8. git add/commit/push, only with --publish -----------------------------
if [ "$PUBLISH" -eq 0 ]; then
	echo
	echo "==> Not committing (pass --publish to commit and push)."
	echo "==> ${REPO_XML} and ${DIST_DIR}/${ZIP_NAME} are on disk, uncommitted."
else
	git add "$REPO_XML" "$DIST_DIR/$ZIP_NAME"

	if ! git commit -m "Package build ${NAME} ${NEW_VERSION}"; then
		echo "error: git commit failed — repo.xml and the zip are staged but not committed" >&2
		exit 1
	fi

	if ! git push; then
		echo "error: git push failed — check credentials (git remote -v, SSH agent / PAT)." >&2
		echo "       ${NAME} ${NEW_VERSION} is committed locally on ${GH_BRANCH} but NOT pushed." >&2
		exit 1
	fi

	echo "==> Committed and pushed ${NAME} ${NEW_VERSION} on ${GH_BRANCH}"
fi
