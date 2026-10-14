#!/usr/bin/env bash
#
# scripts/promote-master.sh — promote a hardware-checked build to master.
#
# Usage (run on v1-buildout):
#   scripts/promote-master.sh <version> <report-no> [--dry-run] [--merge-head]
#
# Users install from master's repo.xml, served by the website (decisions
# §15.36 part 1, §15.37 part 3; docs/dev-repo-workflow.md §5b). A dev build (a
# version containing "a", e.g. 2.0.0a1) is never promoted. The zip <url> stays
# on raw.githubusercontent.com/.../master/dist/, not on Pages. This merges the PACKAGE COMMIT for <version>
# into master and never rebuilds: package-build.sh bumps the version on every
# run, so a rebuild would ship a version nobody hardware-checked. The zip is
# carried byte for byte; version and <sha> survive because both describe its
# bytes.
#
# What it does, in order:
#   1. Finds the one commit whose subject is "Package build SqueezeWax <version>".
#   2. At that commit: repo.xml's version is <version>; the zip's sha1sum is
#      repo.xml's <sha>; docs/user-guide.md exists (the README links it).
#   3. Works in a temporary git worktree of master, removed on exit.
#   4. If master has a repo.xml, <version> must be greater by
#      Slim::Utils::Versions->compareVersions from refs/slimserver/ (forward
#      only: migrations are one-way and LMS offers only a higher version).
#   5. `git merge --no-ff --no-commit` of the package commit. --merge-head
#      merges v1-buildout's HEAD instead, allowed only when SqueezeWax/ and
#      LICENSE are identical to the package commit's. Conflicts are allowed
#      only in repo.xml, dist/ and TODO.md. A TODO.md conflict is settled by taking
#      the package commit's TODO.md, but only after a check: every non-blank line
#      master added to TODO.md since master's last "Promote SqueezeWax" commit
#      must appear verbatim in it. Any missing line aborts the merge and is
#      listed (decisions §15.41).
#   6. Fixes the two paths whose policy differs from the branch: dist/ keeps
#      the zips already on master plus this build's; repo.xml is the package
#      commit's with only the <url>'s /v1-buildout/ changed to /master/.
#   7. Shows the staged diff stat and the new repo.xml. --dry-run stops here and
#      aborts the merge.
#   8. Commits "Promote SqueezeWax <version> to master (hardware report <n>)".
#
# It never pushes; it prints the command for the owner. A commit made here moves
# the local master branch.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

NAME="SqueezeWax"
DEV_BRANCH="v1-buildout"

VERSION=""
REPORT=""
DRY_RUN=0
MERGE_HEAD=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--merge-head) MERGE_HEAD=1 ;;
		-*) die "unknown argument: $arg" ;;
		*)
			if [ -z "$VERSION" ]; then VERSION="$arg"
			elif [ -z "$REPORT" ]; then REPORT="$arg"
			else die "too many arguments: $arg"
			fi
			;;
	esac
done
[ -n "$VERSION" ] && [ -n "$REPORT" ] \
	|| die "usage: $0 <version> <report-no> [--dry-run] [--merge-head]"
case "$VERSION" in
	*a*) die "$VERSION is a dev build (contains \"a\"); dev builds are never promoted (decisions §15.37 part 2)" ;;
esac
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*([ab][0-9]+)?$' \
	|| die "version must look like 0.0.0.24, 1.0.0b1 or 1.0.0, got: $VERSION"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

[ "$(git branch --show-current)" = "$DEV_BRANCH" ] \
	|| die "run this on $DEV_BRANCH (current: $(git branch --show-current))"
git rev-parse -q --verify refs/heads/master >/dev/null \
	|| die "no local master branch"

SLUG="${VERSION//./_}"
ZIP_NAME="${NAME}_${SLUG}.zip"
ZIP_PATH="dist/$ZIP_NAME"

# --- 1. The package commit ----------------------------------------------------
MSG="Package build ${NAME} ${VERSION}"
P_LIST="$(git log --format='%H%x09%s' HEAD | awk -F'\t' -v s="$MSG" '$2 == s { print $1 }')"
P_COUNT="$(printf '%s\n' "$P_LIST" | grep -c . || true)"
[ "$P_COUNT" -ge 1 ] || die "no commit on $DEV_BRANCH has the subject: $MSG"
[ "$P_COUNT" -eq 1 ] || die "$P_COUNT commits have the subject \"$MSG\"; expected exactly one"
P="$P_LIST"
echo "==> Package commit: $(git rev-parse --short "$P")  $MSG"

# --- 2. What that commit says about itself -------------------------------------
xml_version() { perl -ne 'print $1 and exit if /<plugin\b[^>]*\bversion="([^"]+)"/'; }
xml_sha()     { perl -ne 'print $1 and exit if /<sha>([^<]*)<\/sha>/'; }

P_VERSION="$(git show "$P:repo.xml" | xml_version)"
[ "$P_VERSION" = "$VERSION" ] \
	|| die "repo.xml at the package commit says version \"$P_VERSION\", not $VERSION"

git cat-file -e "$P:$ZIP_PATH" 2>/dev/null || die "$ZIP_PATH is not in the package commit"
ZIP_SHA="$(git show "$P:$ZIP_PATH" | sha1sum | awk '{print $1}')"
XML_SHA="$(git show "$P:repo.xml" | xml_sha)"
[ -n "$XML_SHA" ] || die "no <sha> in repo.xml at the package commit"
[ "$ZIP_SHA" = "$XML_SHA" ] \
	|| die "sha mismatch: $ZIP_PATH hashes to $ZIP_SHA, repo.xml says $XML_SHA"

git cat-file -e "$P:docs/user-guide.md" 2>/dev/null \
	|| die "docs/user-guide.md does not exist at the package commit (the README links it)"
echo "==> Checked: version $VERSION, sha1 $ZIP_SHA, user guide present"

TARGET="$P"
TARGET_DESC="the package commit"
if [ "$MERGE_HEAD" -eq 1 ]; then
	TARGET="$(git rev-parse HEAD)"
	TARGET_DESC="$DEV_BRANCH HEAD ($(git rev-parse --short HEAD))"
	if ! git diff --quiet "$P" HEAD -- "$NAME" LICENSE; then
		echo "error: --merge-head refused: $NAME/ or LICENSE changed after the package commit:" >&2
		git diff --stat "$P" HEAD -- "$NAME" LICENSE >&2
		echo "       Rebuild, hardware-check and promote that build instead." >&2
		exit 1
	fi
fi

# --- 3. A worktree of master ----------------------------------------------------
WT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/squeezewax-promote.XXXXXX")"
WT="$WT_BASE/master"
cleanup() {
	git worktree remove --force "$WT" >/dev/null 2>&1 || true
	rm -rf "$WT_BASE"
	git worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree add -q "$WT" master
W() { git -C "$WT" "$@"; }

if git rev-parse -q --verify refs/remotes/origin/master >/dev/null \
	&& [ "$(git rev-parse master)" != "$(git rev-parse origin/master)" ]; then
	echo "warning: local master differs from origin/master; promoting onto local master" >&2
fi

# --- 4. Forward only ------------------------------------------------------------
if W cat-file -e HEAD:repo.xml 2>/dev/null; then
	M_VERSION="$(W show HEAD:repo.xml | xml_version)"
	[ -n "$M_VERSION" ] || die "could not read the version out of master's repo.xml"
	[ -f "$REPO_ROOT/refs/slimserver/Slim/Utils/Versions.pm" ] \
		|| die "refs/slimserver/ is missing: needed for Slim::Utils::Versions->compareVersions"
	if [ "$(perl -I"$REPO_ROOT/refs/slimserver" -MSlim::Utils::Versions \
		-e 'print Slim::Utils::Versions->compareVersions($ARGV[0], $ARGV[1])' \
		"$M_VERSION" "$VERSION")" != "-1" ]; then
		die "forward only: $VERSION is not greater than master's $M_VERSION"
	fi
	echo "==> Forward: master is at $M_VERSION, promoting $VERSION"
else
	echo "==> master has no repo.xml yet: first promotion"
fi

# --- 5. Merge -------------------------------------------------------------------
KEEP_MASTER_ZIPS="$(W ls-tree -r --name-only HEAD -- dist | sort)"

echo "==> Merging $TARGET_DESC into master (--no-ff --no-commit)"
W merge --no-ff --no-commit "$TARGET" >/dev/null 2>&1 || true
W rev-parse -q --verify MERGE_HEAD >/dev/null \
	|| die "the merge did not start (already up to date, or git refused); nothing changed"

BAD=""
TODO_CONFLICT=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	case "$f" in
		repo.xml | dist/*) ;;
		TODO.md) TODO_CONFLICT=1 ;;
		*) BAD="$BAD $f" ;;
	esac
done < <(W diff --name-only --diff-filter=U)
if [ -n "$BAD" ]; then
	W merge --abort || true
	die "conflict outside repo.xml, dist/ and TODO.md (merge aborted):$BAD"
fi

# TODO.md (decisions §15.41): the package commit's version wins, but only if it
# already carries every line master added since master's last promotion.
if [ "$TODO_CONFLICT" -eq 1 ]; then
	LAST_PROMO="$(W log -1 --format=%H --grep='^Promote '"$NAME"' ' master)"
	[ -n "$LAST_PROMO" ] \
		|| { W merge --abort || true; die "TODO.md conflicts and master has no \"Promote $NAME\" commit to measure from; resolve by hand"; }
	TODO_THEIRS="$(git show "$TARGET:TODO.md")"
	MISSING=""
	N_CHECKED=0
	while IFS= read -r line; do
		[ -n "${line//[[:space:]]/}" ] || continue
		N_CHECKED=$((N_CHECKED + 1))
		grep -qxF -- "$line" <<< "$TODO_THEIRS" \
			|| MISSING="$MISSING$line"$'\n'
	done < <(git diff "$LAST_PROMO" master -- TODO.md | grep '^+' | grep -v '^+++' | cut -c2-)
	if [ -n "$MISSING" ]; then
		W merge --abort || true
		echo "error: TODO.md: master added lines since $(git rev-parse --short "$LAST_PROMO") that $TARGET_DESC lacks (merge aborted):" >&2
		printf '%s' "$MISSING" | sed 's/^/    /' >&2
		echo "       Copy them to $DEV_BRANCH first (decisions §15.41), then promote." >&2
		exit 1
	fi
	git show "$TARGET:TODO.md" > "$WT/TODO.md"
	W add -- TODO.md
	echo "==> TODO.md: took package commit's version; $N_CHECKED master lines confirmed present"
fi

# --- 6. The two policy paths -----------------------------------------------------
# dist/: the zips already on master, plus this build's, and nothing else.
KEEP="$(printf '%s\n%s\n' "$KEEP_MASTER_ZIPS" "$ZIP_PATH" | grep . | sort -u)"
while IFS= read -r f; do
	[ -n "$f" ] || continue
	if printf '%s\n' "$KEEP" | grep -qxF -- "$f"; then
		continue
	fi
	W rm -q -f --cached -- "$f"
	rm -f "$WT/$f"
done < <(W ls-files -- dist | sort -u)
while IFS= read -r f; do
	[ -n "$f" ] || continue
	W checkout HEAD -- "$f"
done <<< "$KEEP_MASTER_ZIPS"
mkdir -p "$WT/dist"
git show "$P:$ZIP_PATH" > "$WT/$ZIP_PATH"
W add -- "$ZIP_PATH"

# repo.xml: the package commit's, with only the <url>'s branch changed.
git show "$P:repo.xml" > "$WT/repo.xml"
URL_COUNT="$(perl -0777 -ne 'my @u = /<url>([^<]*)<\/url>/g; print scalar @u' "$WT/repo.xml")"
[ "$URL_COUNT" = "1" ] || { W merge --abort || true; die "expected one <url> in repo.xml, found $URL_COUNT"; }
BRANCH_COUNT="$(perl -0777 -ne '/<url>([^<]*)<\/url>/; my $u = $1; my $n = () = $u =~ m{/'"$DEV_BRANCH"'/}g; print $n' "$WT/repo.xml")"
[ "$BRANCH_COUNT" = "1" ] \
	|| { W merge --abort || true; die "expected /$DEV_BRANCH/ exactly once in repo.xml's <url>, found $BRANCH_COUNT"; }
perl -0777 -pi -e 's{(<url>[^<]*?)/'"$DEV_BRANCH"'/}{$1/master/}' "$WT/repo.xml"
W add -- repo.xml

# Re-check against what is actually staged.
FINAL_SHA="$(sha1sum "$WT/$ZIP_PATH" | awk '{print $1}')"
FINAL_XML_SHA="$(xml_sha < "$WT/repo.xml")"
[ "$FINAL_SHA" = "$FINAL_XML_SHA" ] \
	|| { W merge --abort || true; die "after the merge, $ZIP_PATH hashes to $FINAL_SHA but repo.xml says $FINAL_XML_SHA"; }
FINAL_URL="$(perl -0777 -ne '/<url>([^<]*)<\/url>/ and print $1' "$WT/repo.xml")"
case "$FINAL_URL" in
	*/master/"$ZIP_PATH") ;;
	*) W merge --abort || true; die "repo.xml's <url> does not end in /master/$ZIP_PATH: $FINAL_URL" ;;
esac
[ -z "$(W diff --name-only --diff-filter=U)" ] \
	|| { W merge --abort || true; die "unmerged paths remain after the policy fixes"; }
[ "$(W ls-files -- dist | sort -u)" = "$KEEP" ] \
	|| { W merge --abort || true; die "dist/ is not exactly master's zips plus $ZIP_NAME"; }

# --- 7. Show ---------------------------------------------------------------------
echo
echo "==> git diff --cached --stat (master worktree):"
W diff --cached --stat | tail -40
echo
echo "==> repo.xml as it will be on master:"
cat "$WT/repo.xml"

if [ "$DRY_RUN" -eq 1 ]; then
	W merge --abort
	echo
	echo "==> --dry-run: merge aborted, master untouched."
	exit 0
fi

# --- 8. Commit --------------------------------------------------------------------
W commit -q -m "Promote ${NAME} ${VERSION} to master (hardware report ${REPORT})"
echo
echo "==> Committed on master: $(git rev-parse --short master)"
echo "==> Not pushed. When ready:  git push origin master"
