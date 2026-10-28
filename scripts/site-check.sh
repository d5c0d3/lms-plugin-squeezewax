#!/usr/bin/env bash
#
# scripts/site-check.sh — scan the pages the website serves for beta/alpha.
#
# Usage:
#   scripts/site-check.sh <git-ref> [<version>]
#
# <git-ref> is anything `git show <ref>:<path>` accepts: a branch, a commit or a
# tree (promote-master.sh passes the tree of its merged worktree). Nothing is
# checked out. Decisions §15.59; docs/dev-repo-workflow.md §5b.
#
# Reads index.html, worked-example.html, README.md and docs/user-guide.md at the
# ref and prints every case-insensitive "beta" or "alpha" as file:line. In the
# two HTML pages, lines inside <script>...</script> are ignored: the version
# badge code names the stages on purpose.
#
# It also lists the .html/.md/.markdown files that _config.yml's exclude: list
# does not exclude, beyond those four, so a new page is noticed. It does not
# parse Jekyll; underscore- and dot-prefixed paths are skipped as Jekyll does.
#
# Exit 2, with a warning, if <version> is a release (X.Y.Z) and there is any
# hit. Exit 0 otherwise. A word scan cannot judge content: the last line always
# says to review the pages.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REF="${1:-}"
VERSION="${2:-}"
[ -n "$REF" ] && [ $# -le 2 ] || die "usage: $0 <git-ref> [<version>]"
git rev-parse -q --verify "$REF^{tree}" >/dev/null || die "not a git ref: $REF"

PAGES=(index.html worked-example.html README.md docs/user-guide.md)

# Other served pages: tracked .html/.md files not excluded by _config.yml.
EXCLUDES=""
if git cat-file -e "$REF:_config.yml" 2>/dev/null; then
	EXCLUDES="$(git show "$REF:_config.yml" | sed -n 's/^[[:space:]]*-[[:space:]]*\([^[:space:]#]*\).*/\1/p')"
fi
EXTRA=""
while IFS= read -r f; do
	case "$f" in
		*.html | *.md | *.markdown) ;;
		*) continue ;;
	esac
	case "/$f" in */_* | */.*) continue ;; esac
	skip=0
	for p in "${PAGES[@]}"; do [ "$f" = "$p" ] && skip=1; done
	while IFS= read -r e; do
		[ -n "$e" ] || continue
		case "$e" in
			*/) case "$f" in "$e"*) skip=1 ;; esac ;;
			*) [ "$f" = "$e" ] && skip=1 ;;
		esac
	done <<< "$EXCLUDES"
	[ "$skip" -eq 1 ] || EXTRA="$EXTRA $f"
done < <(git ls-tree -r --name-only "$REF")
if [ -n "$EXTRA" ]; then
	echo "note: _config.yml at $REF does not exclude these other pages; check them too:$EXTRA"
fi

HITS=0
for f in "${PAGES[@]}"; do
	if ! git cat-file -e "$REF:$f" 2>/dev/null; then
		echo "note: $f does not exist at $REF"
		continue
	fi
	OUT="$(git show "$REF:$f" | awk -v f="$f" -v html="${f##*.}" '
		html == "html" {
			if (tolower($0) ~ /<script/) inscript = 1
			skip = inscript
			if (tolower($0) ~ /<\/script>/) inscript = 0
			if (skip) next
		}
		tolower($0) ~ /beta|alpha/ { printf "%s:%d: %s\n", f, NR, $0 }
	')"
	if [ -n "$OUT" ]; then
		printf '%s\n' "$OUT"
		HITS=$((HITS + $(printf '%s\n' "$OUT" | wc -l)))
	fi
done
echo "==> $HITS beta/alpha hit(s) at $REF"

STATUS=0
if [ "$HITS" -gt 0 ] && printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
	echo "WARNING: release $VERSION but the website still mentions beta/alpha"
	STATUS=2
fi
echo "Review the website before pushing master: ${PAGES[*]}${EXTRA}. A word scan cannot judge content."
exit "$STATUS"
