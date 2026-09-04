#!/usr/bin/env bash
#
# scripts/package-dev-build.sh — build the SqueezeWaxDev dev-repo package.
#
# Implements docs/dev-repo-workflow.md §5. Builds SqueezeWax/ at the current
# git commit into a temp dir, applies the §2 rename table, bumps the version
# in repo-dev.xml, zips, hashes, and (unless --dry-run) commits + pushes the
# zip and updated repo-dev.xml.
#
# Usage:
#   scripts/package-dev-build.sh [--dry-run]
#
# --dry-run   Do everything except the git add/commit/push in step 8 — the
#             zip lands in dist/ and repo-dev.xml is rewritten on disk, both
#             left uncommitted for inspection.

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		*)
			echo "error: unknown argument: $arg" >&2
			exit 1
			;;
	esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REAL_NAME="SqueezeWax"
DEV_NAME="SqueezeWaxDev"

# --- §2 rename table, as literal substitution pairs -------------------------
REAL_PKG="Plugins::${REAL_NAME}::"        # package namespace (covers install.xml <module>/<importmodule> too)
DEV_PKG="Plugins::${DEV_NAME}::"
REAL_WEBPATH="plugins/${REAL_NAME}/"      # web paths
DEV_WEBPATH="plugins/${DEV_NAME}/"
REAL_TOKEN="PLUGIN_SQUEEZEWAX_"           # string token prefix
DEV_TOKEN="PLUGIN_SQUEEZEWAXDEV_"
REAL_NS="plugin.squeezewax"               # Slim::Utils::Prefs namespace + log category
DEV_NS="plugin.squeezewaxdev"
# Display title ("SqueezeWax (Dev)") is handled separately below — it's a
# value, not an identifier, so it isn't a blanket find/replace.

REAL_INSTALL_XML="$REPO_ROOT/${REAL_NAME}/install.xml"
REPO_DEV_XML="$REPO_ROOT/repo-dev.xml"
DIST_DIR="$REPO_ROOT/dist"

GH_USER="d5c0d3"
GH_REPO="lms-plugin-squeezewax"
GH_BRANCH="$(git branch --show-current)"

if [ ! -f "$REAL_INSTALL_XML" ]; then
	echo "error: $REAL_INSTALL_XML not found" >&2
	exit 1
fi

# --- 1. Build from SqueezeWax/ at the current commit into a temp dir --------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/squeezewax-dev-build.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

COMMIT="$(git rev-parse --short HEAD)"
echo "==> Extracting ${REAL_NAME}/ from commit ${COMMIT} into ${TMP_DIR}"
git archive HEAD -- "${REAL_NAME}" | tar -x -C "$TMP_DIR"

if [ ! -d "$TMP_DIR/$REAL_NAME" ]; then
	echo "error: git archive produced no ${REAL_NAME}/ at HEAD — is it committed?" >&2
	exit 1
fi

mv "$TMP_DIR/$REAL_NAME" "$TMP_DIR/$DEV_NAME"
DEV_DIR="$TMP_DIR/$DEV_NAME"

# --- 2. Apply the §2 renames, mechanically -----------------------------------
echo "==> Applying §2 renames"

while IFS= read -r -d '' f; do
	perl -pi -e "
		s#\Q${REAL_PKG}\E#${DEV_PKG}#g;
		s#\Q${REAL_WEBPATH}\E#${DEV_WEBPATH}#g;
		s#\Q${REAL_TOKEN}\E#${DEV_TOKEN}#g;
		s#\Q${REAL_NS}\E#${DEV_NS}#g;
	" "$f"
done < <(find "$DEV_DIR" -type f -print0)

# The web path is a directory name on disk as well as a string in Settings.pm.
# The substitution above rewrote page()'s "plugins/SqueezeWax/settings.html" to
# "plugins/SqueezeWaxDev/settings.html", but HTML/EN/plugins/SqueezeWax/ is still
# called SqueezeWax - so without this the dev build's settings page is a 404,
# and only in the dev build, which is the worst place to find out.
if [ -d "$DEV_DIR/HTML" ]; then
	while IFS= read -r d; do
		mv "$d" "$(dirname "$d")/$DEV_NAME"
	done < <(find "$DEV_DIR/HTML" -type d -name "$REAL_NAME")
fi

# Display title: after the token-prefix rename above, strings.txt's
# PLUGIN_SQUEEZEWAXDEV_NAME block still carries the bare display value
# ("SqueezeWax") for each language line. Append " (Dev)" inside that one
# token's block only — this is a value, so it isn't part of the blanket
# substitution list above.
STRINGS_FILE="$DEV_DIR/strings.txt"
if [ -f "$STRINGS_FILE" ]; then
	awk -v token="${DEV_TOKEN}NAME" '
		$0 == token { in_block = 1; print; next }
		in_block && /^\t[A-Za-z]{2}\t/ {
			if ($0 !~ / \(Dev\)$/) { $0 = $0 " (Dev)" }
			print
			next
		}
		{ in_block = 0; print }
	' "$STRINGS_FILE" > "$STRINGS_FILE.tmp"
	mv "$STRINGS_FILE.tmp" "$STRINGS_FILE"
fi

# --- 3. Bump the version -----------------------------------------------------
if [ -f "$REPO_DEV_XML" ]; then
	CUR_VERSION="$(perl -ne 'print $1 and exit if /<plugin\b[^>]*\bversion="([^"]+)"/' "$REPO_DEV_XML")"
	if [ -z "${CUR_VERSION:-}" ]; then
		echo "error: could not find version=\"...\" in $REPO_DEV_XML" >&2
		exit 1
	fi
else
	echo "==> No repo-dev.xml yet — bootstrapping at 0.0.0.0 (first build will be 0.0.0.1)"
	CUR_VERSION="0.0.0.0"
fi

NEW_VERSION="$(perl -e '
	my @p = split /\./, $ARGV[0];
	$p[-1]++;
	print join(".", @p);
' "$CUR_VERSION")"

echo "==> Version: ${CUR_VERSION} -> ${NEW_VERSION}"

DEV_INSTALL_XML="$DEV_DIR/install.xml"
perl -pi -e "s#(<version>)[^<]*(</version>)#\${1}${NEW_VERSION}\${2}#" "$DEV_INSTALL_XML"

# Track the real install.xml's target range and category rather than
# hardcoding them, per §4's "don't let this drift" note. Read these from
# DEV_INSTALL_XML (the git-archived-at-HEAD copy that's about to be zipped),
# not REAL_INSTALL_XML (the live working tree) — the two can disagree
# whenever there's an uncommitted edit, which would let repo-dev.xml and the
# zip's own install.xml ship different values for the same build.
MIN_TARGET="$(perl -ne 'print $1 and exit if /<minVersion>([^<]*)<\/minVersion>/' "$DEV_INSTALL_XML")"
MAX_TARGET="$(perl -ne 'print $1 and exit if /<maxVersion>([^<]*)<\/maxVersion>/' "$DEV_INSTALL_XML")"
CATEGORY="$(perl -ne 'print $1 and exit if /<category>([^<]*)<\/category>/' "$DEV_INSTALL_XML")"

for v in "$MIN_TARGET" "$MAX_TARGET" "$CATEGORY"; do
	if [ -z "$v" ]; then
		echo "error: could not read minVersion/maxVersion/category out of $DEV_INSTALL_XML" >&2
		exit 1
	fi
done

# --- 4. Zip -------------------------------------------------------------------
ZIP_NAME="${DEV_NAME}_${NEW_VERSION}.zip"
( cd "$TMP_DIR" && zip -r -q "$ZIP_NAME" "$DEV_NAME" )
ZIP_PATH="$TMP_DIR/$ZIP_NAME"
echo "==> Zipped ${ZIP_NAME}"

# --- 5. Hash --------------------------------------------------------------
SHA1="$(sha1sum "$ZIP_PATH" | awk '{print $1}')"
echo "==> sha1: ${SHA1}"

# --- 6. Write the new <version> and <sha> into repo-dev.xml -----------------
ZIP_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/dist/${ZIP_NAME}"

cat > "$REPO_DEV_XML" <<XML
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">SqueezeWax dev builds</title>
	</details>
	<plugins>
		<plugin name="${DEV_NAME}" version="${NEW_VERSION}" minTarget="${MIN_TARGET}" maxTarget="${MAX_TARGET}">
			<title lang="EN">SqueezeWax (Dev)</title>
			<desc lang="EN">Development build of SqueezeWax — not for general use.</desc>
			<creator>${GH_USER}</creator>
			<category>${CATEGORY}</category>
			<url>${ZIP_URL}</url>
			<sha>${SHA1}</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "==> Wrote ${REPO_DEV_XML}"

# --- 7. Move the zip into dist/ ----------------------------------------------
mkdir -p "$DIST_DIR"
cp "$ZIP_PATH" "$DIST_DIR/$ZIP_NAME"
echo "==> Copied zip to ${DIST_DIR}/${ZIP_NAME}"

# --- Verification (always printed, dry-run or not) ---------------------------
echo
echo "==> Dev copy file tree:"
find "$DEV_DIR" -type f | sed "s#^${TMP_DIR}/##" | sort

echo
echo "==> grep -ri squeezewax over the dev copy (only *Dev-suffixed matches expected):"
grep -ri squeezewax -r "$DEV_DIR" || echo "(no matches)"

echo
echo "==> Zip contents:"
unzip -l "$DIST_DIR/$ZIP_NAME"

# --- 8. git add/commit/push --------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
	echo
	echo "==> --dry-run: skipping git add/commit/push (§5 step 8)."
	echo "==> repo-dev.xml and dist/${ZIP_NAME} are on disk, uncommitted."
else
	git add "$REPO_DEV_XML" "$DIST_DIR/$ZIP_NAME"
	git commit -m "Dev build ${DEV_NAME} ${NEW_VERSION}"
	git push
	echo "==> Committed and pushed ${DEV_NAME} ${NEW_VERSION}"
fi
