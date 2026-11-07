#!/usr/bin/env bash
# tested.sh — on a push to main, says whether a job already passed on exactly this tree, so the main run can skip it: the
# second run every PR used to get on the then single runner. Usage, from a job of the main run:
#   .github/scripts/tested.sh <workflow file>/<job>@<event>…      e.g. tests.yml/suites@pull_request
# Exit 0 when one of the named jobs passed on a tree identical to the pushed commit's (the reason printed); 1 when the job
# must run: a direct push with no PR behind it, no passing run, a different tree, or any API error. Doubt is a run.
#
# WHY THE TREE AND NOT THE COMMIT. A PR's `pull_request` run tests refs/pull/N/merge: GitHub's merge of the PR's head H
# into main as it was then (B'). `gh pr merge --merge` then makes a new merge commit M of H into main as it is now (B'').
# M is never the commit that was tested, so commits cannot be compared; but a git tree sha names the exact content of
# every file, so when M's tree equals the tested merge commit's tree, the files on main are byte for byte the ones the
# suites passed on, whatever the commits and their parents. When main moved between the check and the merge (B' != B''),
# M carries that other change too, its tree differs from the tested one, and the suites run. The tested tree is recorded
# by the PR run itself, as the name of an artifact `tested-<job>-<tree>` that the job uploads in its last step (so it exists
# only when every step before it passed); this script looks for that name among the artifacts of the PR's successful runs
# for the same head H. smoke.yml's branch-push run tests H itself: its tree equals M's exactly when main had not moved.
# Needs GITHUB_REPOSITORY, GITHUB_SHA (the pushed commit), gh with GH_TOKEN (actions and pull-requests: read), python3.
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: tested.sh <workflow file>/<job>@<event>..." >&2; exit 2; }
repo="${GITHUB_REPOSITORY:?}"; sha="${GITHUB_SHA:?}"
say() { echo "tested: $*"; }
api() { gh api "$1" 2>/dev/null; }     # the body on stdout; nothing and a non-zero status on any failure
py() { python3 -c "$@" 2>/dev/null; }

commit="$(api "repos/$repo/git/commits/$sha")" || { say "run: the tree of $sha could not be read (API error)"; exit 1; }
tree="$(echo "$commit" | py 'import json,sys; print(json.load(sys.stdin)["tree"]["sha"])')"
[ -n "$tree" ] || { say "run: the tree of $sha could not be read (unexpected answer)"; exit 1; }
pulls="$(api "repos/$repo/commits/$sha/pulls")" || { say "run: the pull requests of $sha could not be listed (API error)"; exit 1; }
read -r pr head <<< "$(echo "$pulls" | py '
import json,sys
sha=sys.argv[1]
for p in json.load(sys.stdin):
    if p.get("merged_at") and p.get("merge_commit_sha") == sha:
        print(p["number"], p["head"]["sha"]); break
' "$sha")"
[ -n "${pr:-}" ] && [ -n "${head:-}" ] || { say "run: $sha is the merge commit of no pull request (a direct push to main): nothing was tested before it"; exit 1; }
say "push ${sha:0:7} (tree $tree) merged PR #$pr (head ${head:0:7})"
for spec in "$@"; do
    wf="${spec%%/*}"; jobev="${spec#*/}"; job="${jobev%@*}"; event="${jobev#*@}"
    runs="$(api "repos/$repo/actions/workflows/$wf/runs?event=$event&head_sha=$head&status=success&per_page=10")" \
        || { say "run: the $event runs of $wf for ${head:0:7} could not be listed (API error)"; exit 1; }
    ids="$(echo "$runs" | py 'import json,sys; print(" ".join(str(r["id"]) for r in json.load(sys.stdin)["workflow_runs"]))')"
    [ -n "$ids" ] || { say "no successful $event run of $wf for head ${head:0:7}"; continue; }
    for id in $ids; do
        arts="$(api "repos/$repo/actions/runs/$id/artifacts")" || { say "run: the artifacts of run $id could not be listed (API error)"; exit 1; }
        if echo "$arts" | py 'import json,sys; sys.exit(0 if sys.argv[1] in [a["name"] for a in json.load(sys.stdin)["artifacts"]] else 1)' "tested-$job-$tree"; then
            say "skip: $job already passed on this exact tree in $wf run $id ($event, PR #$pr, head ${head:0:7}); nothing to test again"
            exit 0
        fi
        say "run $id of $wf ($event) has no tested-$job-$tree: it tested another tree, or $job did not pass in it"
    done
done
say "run: no run of PR #$pr passed $* on tree $tree (main moved between the check and the merge, or the job did not pass)"
exit 1
