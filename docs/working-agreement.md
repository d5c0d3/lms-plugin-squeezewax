# SqueezeWax — Working Agreement

How work is split between the claude.ai project (design chat) and Claude Code
in VS Code (implementation), which model to use where, and the rules that
apply in both places.

The **Rules for the design chat** section below is written to be pasted into
the project instructions. The rest is reference and can live as a knowledge
file or as `docs/working-agreement.md` in the repo.

---

## 1. Where work happens

| | claude.ai project (here) | Claude Code (VS Code) |
|---|---|---|
| Design decisions, trade-offs | ✅ | ✗ — implement what's decided |
| Research against external sources | ✅ | ✗ — no web access assumed |
| Reading LMS/plugin source to answer "does this API exist" | ✅ (clones fresh) | ✅ (reads `refs/`) |
| Writing plugin code | ✗ | ✅ |
| Editing files in the repo | ✗ — outputs files to download | ✅ |
| Git operations | ✗ | ✅ |
| Deciding scope | ✅ | ✗ — follow the spec, object if wrong |

The dividing line: **the design chat decides what and why; Claude Code
decides how and does it.** If the design chat starts writing `Slim::*` calls,
it has drifted. If Claude Code starts renegotiating scope, so has it.

## 2. Source of truth

- `docs/squeezewax-design.md` — scope and behaviour. Wins over everything.
- `docs/implementation-plan.md` — how v1 gets built, with cited APIs.
- `docs/v1-decisions.md` — dated decision records. Reasoning and evidence,
  not live spec; anything still contradicting the design doc is a bug to
  reconcile, not a second opinion.
- `CLAUDE.md` — rules for Claude Code.
- `TODO.md` — shared reminders, both of us read and write it.
- `refs/` — read-only. Never edited, never copied wholesale.

One rule: when two documents disagree, that is a defect. Fix it in the same
session it's noticed rather than picking one and moving on.

## 3. Model choice — by task shape, not by build step

Pick by **where the expensive judgment sits**, not by which step of the build
order you're on.

| Model | Use for | Examples |
|---|---|---|
| `haiku` | Plumbing with a known-good answer | Cloning repos, moving files, `.gitignore`, running the packaging script |
| `sonnet` | The decision is made; the work is transcription or mechanical code | Folding agreed decisions into the spec, writing Perl once the design is settled, routine fixes |
| `opusplan` (plan mode on) | Mixed: real judgment up front, mechanical execution after | Doc reconciliation with verification, multi-file refactors |
| `opus` | Open-ended design, "does this API exist", anything where a plausible wrong answer is expensive to catch later | `Schema.pm`, the matching cascade, resumable scan logic |

Rule of thumb: if a wrong answer would look right and surface months later as
a silent bug, use opus. If a wrong answer fails loudly and immediately, sonnet
is fine.

`Schema.pm` is an opus job. It has no reference implementation to model, it's
the foundation everything else sits on, and its failure mode is silent wrong
badges rather than a crash.

## 4. Session hygiene (Claude Code)

- **`CLAUDE.md` is loaded at the start of a conversation.** Changes to it are
  not active in the session that made them. Edit it, close, reopen.
- **Prefer several short sessions to one long one.** Setup, then planning,
  then implementation — each with its own model.
- **Small, reviewable commits.** One concern per commit.
- **Commit before packaging.** `scripts/package-dev-build.sh` builds from
  `git archive HEAD`, not the working tree, so an uncommitted edit is silently
  invisible to the dev build. Edit → commit → package → push.

## 5. The sync loop

`docs/` is mirrored into the claude.ai project via the GitHub connector, which
**does not auto-sync**.

After any commit under `docs/`, hit **"Sync now"** in the project before the
next design chat. Claude Code adds a one-line reminder; the `post-commit` hook
catches it deterministically.

Consequence worth remembering: if the design chat is reasoning about a spec
section you changed yesterday and didn't sync, it is reasoning about the old
version and will not know.

## 6. Verifying claims across the two sides

The design chat clones slimserver fresh (latest tag or master). `refs/` here
is pinned to branch `public/9.1`. **Line numbers will not match.**

So: citations that cross from the design chat into the repo must be
re-verified by Claude Code, locating by **symbol or string, never by line
number**, and correcting the reference to the checked-out branch. A citation
that can't be found on `public/9.1` is reported, not quietly dropped.
