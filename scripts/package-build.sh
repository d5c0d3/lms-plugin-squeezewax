#!/usr/bin/env bash
#
# scripts/package-build.sh — build and package SqueezeWax for distribution.
#
# Implements docs/dev-repo-workflow.md. Builds SqueezeWax/ at the current git
# commit (via `git archive HEAD`, so an uncommitted edit is never silently
# packaged), adds the repo root's LICENSE to it, zips it, hashes it, and writes
# repo.xml pointing at that zip.
#
# Refuses to run on `master`: testers install from master's repo.xml, and a
# build there would publish an unchecked zip to them (decisions §15.36 part 1).
# Builds reach master only through scripts/promote-master.sh, which merges a
# hardware-checked package commit and never rebuilds.
#
# LICENSE: GPL-2 asks that recipients get a copy with the program, so the
# root LICENSE is copied into the packaged SqueezeWax/ (decisions §15.36
# part 2). The build fails if LICENSE is not committed at HEAD.
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
# Version rules (decisions §15.37 part 2):
#   - Bump: add 1 to the trailing number of the last part.
#       1.0.0b7 -> 1.0.0b8   1.0.0 -> 1.0.1   2.0.0a3 -> 2.0.0a4
#       0.0.0.24 -> 0.0.0.25
#   - --version X uses X instead. X must match ^\d+\.\d+\.\d+([ab]\d+)?$ (never a
#     hyphen: 1.0.0-beta1 compares EQUAL to 1.0.0 in LMS, so an update would
#     silently not be offered) and must be higher than repo.xml's version by
#     Slim::Utils::Versions->compareVersions, loaded from refs/slimserver/.
#   - Line guard: on a branch named vN-buildout the new version's first number
#     must be N. Other branch names warn and continue; master is refused.
#   - aN is a dev build and is never promoted; bN is a beta; plain is a release.
#
# Usage:
#   scripts/package-build.sh [--dry-run] [--publish] [--version X]
#
# --dry-run   Build in a temp dir only. Never writes repo.xml or dist/*.zip to
#             disk — prints the file tree, a leftover-naming grep, and
#             `unzip -l` so the artifact can be inspected before it exists
#             anywhere.
# --version X Use version X instead of bumping (rules above).
# --publish   After building, `git add`/`commit`/`push` repo.xml and the new
#             zip. Without this flag the script never calls git — the files
#             land on disk uncommitted for review. Mutually exclusive with
#             --dry-run.
#
# The <url> this script writes is always the raw.githubusercontent.com URL
# for the *current* branch — GitHub Pages only serves the default branch, so
# a build line's zip is unreachable there. The zip <url> stays on raw even on
# master (decisions §15.37 part 3); scripts/promote-master.sh rewrites the
# branch segment.

set -euo pipefail

DRY_RUN=0
PUBLISH=0
WANT_VERSION=""
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--publish) PUBLISH=1 ;;
		--version)
			if [ $# -lt 2 ]; then
				echo "error: --version needs a value" >&2
				exit 1
			fi
			WANT_VERSION="$2"
			shift
			;;
		*)
			echo "error: unknown argument: $1" >&2
			exit 1
			;;
	esac
	shift
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

if [ "$GH_BRANCH" = "master" ]; then
	echo "error: refusing to build on master: testers install from master's repo.xml," >&2
	echo "       so a build here would publish an unchecked zip. Builds reach master" >&2
	echo "       only through scripts/promote-master.sh (decisions §15.36 part 1)." >&2
	exit 1
fi

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
if ! git cat-file -e "HEAD:LICENSE" 2>/dev/null; then
	echo "error: LICENSE is not committed at HEAD — the zip must carry it" >&2
	exit 1
fi
git archive HEAD -- "${NAME}" LICENSE | tar -x -C "$TMP_DIR"

BUILD_DIR="$TMP_DIR/$NAME"
if [ ! -d "$BUILD_DIR" ]; then
	echo "error: git archive produced no ${NAME}/ at HEAD — is it committed?" >&2
	exit 1
fi
mv "$TMP_DIR/LICENSE" "$BUILD_DIR/LICENSE"

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

# compareVersions: prints -1, 0 or 1 for $1 <=> $2, using LMS's own rule.
compare_versions() {
	perl -I"$REPO_ROOT/refs/slimserver" -MSlim::Utils::Versions \
		-e 'print Slim::Utils::Versions->compareVersions($ARGV[0], $ARGV[1])' "$1" "$2"
}

if [ -n "$WANT_VERSION" ]; then
	if ! printf '%s' "$WANT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([ab][0-9]+)?$'; then
		echo "error: --version ${WANT_VERSION}: must look like 1.0.0, 1.0.0b1 or 2.0.0a1 (no hyphen:" >&2
		echo "       1.0.0-beta1 compares equal to 1.0.0 in LMS, decisions §15.37 part 2)" >&2
		exit 1
	fi
	if [ ! -f "$REPO_ROOT/refs/slimserver/Slim/Utils/Versions.pm" ]; then
		echo "error: --version compares with Slim::Utils::Versions, but refs/slimserver/ is missing" >&2
		exit 1
	fi
	if [ "$(compare_versions "$CUR_VERSION" "$WANT_VERSION")" != "-1" ]; then
		echo "error: --version ${WANT_VERSION} is not higher than the current ${CUR_VERSION}" >&2
		exit 1
	fi
	NEW_VERSION="$WANT_VERSION"
else
	NEW_VERSION="$(perl -e '
		my $v = $ARGV[0];
		$v =~ s/(\d+)$/$1 + 1/e or die "version has no trailing number: $v\n";
		print $v;
	' "$CUR_VERSION")"
fi

# Line guard: vN-buildout builds N.x.x only.
case "$GH_BRANCH" in
	v[0-9]*-buildout)
		LINE="${GH_BRANCH#v}"
		LINE="${LINE%%-*}"
		if [ "${NEW_VERSION%%.*}" != "$LINE" ]; then
			echo "error: ${GH_BRANCH} builds ${LINE}.x.x versions, not ${NEW_VERSION} (decisions §15.37 part 2)" >&2
			exit 1
		fi
		;;
	*)
		echo "warning: branch ${GH_BRANCH} is not vN-buildout; the version line was not checked" >&2
		;;
esac

echo "==> Version: ${CUR_VERSION} -> ${NEW_VERSION}"

# Only the packaged (temp, git-archived) copy's <version> is set — the
# committed SqueezeWax/install.xml is left at its own value. repo.xml's
# version is the user-visible one (decisions §15.37; docs/dev-repo-workflow.md §2).
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
# <link> is the project website; the website links to the issues page.
SITE_URL="https://${GH_USER}.github.io/${GH_REPO}/"

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
			<link>${SITE_URL}</link>
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
