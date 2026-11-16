# The trial Codex review

`salamander codex-review <owner/repo> <pr>` has OpenAI's Codex CLI read the diff of a pull request's head and posts what it found as one comment on the PR. It is a
**two-week trial and a second opinion**: it never blocks, delays or fails a merge or a release, and nothing waits for it.

| | |
|---|---|
| the verb | `salamander codex-review <owner/repo> <pr>` (`lib/codex-review.sh`, the work in `lib/codex-review.py`, standard library only) |
| the start from a release | `release.sh --run <pr>` starts it, detached, right after it finds the PR open (never for `--merged` or an already merged PR) |
| the repos | `howardpark-ai/salamander` and `howardpark-ai/stackshot`; any other repo is logged and left alone |
| the log | `~/.local/state/salamander/codex-review/<owner>__<repo>-pr-<n>.log` (the state folder is `$XDG_STATE_HOME/salamander`), times in UTC |
| one review per commit | a marker file `codex-review/done/<owner>__<repo>-pr-<n>-<head sha>`, taken under a `flock` on `codex-review/<owner>__<repo>-pr-<n>.lock` |

## What a call does

1. Exits at once, logging why, for a repo outside the two, for `SALA_CODEX_REVIEW=off`, or when Codex is not signed in (`codex login status` says no).
2. Reads the PR's head sha and title and its diff with `gh`. A head sha that already has a marker is done. A diff over `SALA_CODEX_MAX_DIFF` bytes is skipped and logged.
3. Runs `codex exec --sandbox read-only --skip-git-repo-check -C <an empty temporary folder> --output-last-message <file> -` with the review prompt and the diff on stdin,
   for at most `SALA_CODEX_TIMEOUT` seconds (then its whole process group is ended). Codex sees the diff and an empty working folder, nothing of the checkout.
   The prompt asks for correctness bugs, risky changes and missing tests or docs, as short bullets with file and line, at most 40 lines, and `No findings.` when there are none.
4. A non-zero exit, a timeout, an empty answer, or a short answer that is a refusal or a usage-limit message is logged and **posts nothing**, and leaves no marker, so the next call tries again.
5. A good answer goes through the privacy check (below) and is posted with `gh pr comment <pr> --repo <repo> --body-file`, headed
   `Codex review (trial, read-only, a second opinion and not a gate) of <sha7>`, cut to 60000 characters.

Every valid call exits 0 and prints one short line, whatever happened; a script starts it detached and never waits. A wrong call (no repo, a pr that is not a number) exits 2 and prints the usage on stderr.

## The privacy check

Both repos are public, and a review is text written by a model that was shown a diff. Before a review is posted on a public repo it is checked: the text is put alone in a throwaway git repo and
`<SALA_CODEX_PUBLIC_SCAN> scan <that folder> --repo <name>` is run. Only exit 0 with a `PASS` line posts the review. The visibility of the repo is read with `gh repo view`; if that cannot be read the repo is treated as public.

The check **fails closed**: a hit, a check that exits non-zero, cannot run, times out (`SALA_CODEX_SCAN_TIMEOUT`), or is not set at all posts only the note
`Codex review withheld: the text needed a privacy check it did not pass`, and the review stays in `codex-review/<owner>__<repo>-pr-<n>-<sha7>.withheld.md` (mode 600) for its owner to read. The marker is written after the note too,
so the same commit is not reviewed or noted twice.

The command is a setting because the check lives outside this repository. Until `SALA_CODEX_PUBLIC_SCAN` is set, every review on a public repo is withheld. Set it in `~/.config/salamander/config`, for example
`SALA_CODEX_PUBLIC_SCAN=/path/to/public-scan.py` (any program that takes `scan <dir> --repo <name>`, exits 0 and prints a line with `PASS` when the text may be public).

## Settings

Read from `~/.config/salamander/config` or the environment (`release.sh` passes them on to the review's unit).

| Setting | Default | Meaning |
|---|---|---|
| `SALA_CODEX_REVIEW` | `on` | `off` turns the verb into a logged no-op |
| `SALA_CODEX_BIN` | `~/.local/bin/codex` | the Codex CLI |
| `SALA_CODEX_HOME` | `~/.config/codex` | Codex's state folder for this review, always passed as `CODEX_HOME`; never `~/.codex` |
| `SALA_CODEX_MAX_DIFF` | `300000` | bytes; a larger diff is skipped |
| `SALA_CODEX_TIMEOUT` | `900` | seconds Codex may run |
| `SALA_CODEX_PUBLIC_SCAN` | unset | the privacy check's command (above); unset withholds |
| `SALA_CODEX_SCAN_TIMEOUT` | `120` | seconds the privacy check may run |

Codex signs in through a ChatGPT seat (`CODEX_HOME=~/.config/codex codex login`). No API key is used and none may be added: `OPENAI_API_KEY` and `CODEX_API_KEY` are removed from the environment Codex runs in.

## How a release starts it

`release.sh` runs inside a transient user unit, and systemd ends a unit's whole cgroup when its main process exits, which would cut a review that outlives the release. So the review gets a unit of its own,
`salamander-codex-review-<pr>-<time>`, with its output in `<state>/releases/codex-review-pr-<pr>.log`; with no user manager it is started with `setsid nohup` instead. One release-log line says it was started or why not.
Neither a failed start nor a failing review can change what `release.sh` does or returns.

## The trial, and turning it off

The trial runs for two weeks. Its question is whether the second opinion finds what the other reviews do not. To stop it, set `SALA_CODEX_REVIEW=off` in `~/.config/salamander/config`: a release still starts the verb, which logs
`SALA_CODEX_REVIEW=off` and does nothing. To end it for good, remove the call in `release.sh` (`codex_review_start`) and the verb.

## What this does not protect against

`--sandbox read-only` stops Codex writing; it does not hide the files it can read as the user that runs it. The empty working folder means a review cannot be steered by a file in the checkout, but a diff that tells Codex to read
something else is still a prompt Codex reads. That is why the diff is labeled as data in the prompt, the text is checked before it is posted, and nothing is run on what Codex returns. The markers and withheld files are not pruned.

Tests: `tests/codex-review.sh` (the verb against stubs) and `tests/release.sh` (the start from `release.sh`).
