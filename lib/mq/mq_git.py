"""lib/mq/mq_git.py — git for mq: the work clone, one worktree per group, and the remote operations, which are counted (docs/mq.md).

Building a group and pushing its branch use git over the remote and no REST call. Every operation that reaches the remote (clone, fetch,
ls-remote, push) is counted into the dict the caller hands in, so a group's record can say how many there were.
"""
import os
import subprocess


class GitError(Exception):
    pass


REMOTE_OPS = ("clone", "fetch", "ls-remote", "push")


class Git:
    def __init__(self, work, remote, name=None, email=None, only_push=None):
        self.work = work
        self.remote = remote
        self.only_push = only_push       # replay: the one branch prefix a push or a delete may name (queue/practice/); None = any
        self.ident = []
        n, e = name or self._cfg("user.name") or "mergequeue", email or self._cfg("user.email") or "mergequeue@localhost"
        self.ident = ["-c", "user.name=" + n, "-c", "user.email=" + e, "-c", "commit.gpgsign=false", "-c", "merge.autoStash=false"]
        self.env = dict(os.environ, GIT_TERMINAL_PROMPT="0", LC_ALL="C")

    @staticmethod
    def _cfg(key):
        r = subprocess.run(["git", "config", "--get", key], capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""

    def run(self, args, cwd=None, check=True, timeout=300, counts=None, input=None):
        """git <args> in cwd (default: the work clone) → CompletedProcess (text). A remote operation is added to counts."""
        if counts is not None:
            for op in REMOTE_OPS:
                if args and args[0] == op:
                    counts[op] = counts.get(op, 0) + 1
        try:
            r = subprocess.run(["git"] + self.ident + list(args), cwd=cwd or self.work, capture_output=True, text=True,
                               timeout=timeout, env=self.env, input=input)
        except subprocess.TimeoutExpired:
            raise GitError("git %s: timed out after %ds" % (" ".join(args[:2]), timeout))
        except OSError as e:
            raise GitError("git %s: %s" % (" ".join(args[:2]), e))
        if check and r.returncode != 0:
            tail = " ".join((r.stderr or r.stdout or "").strip().splitlines()[-2:])
            raise GitError("git %s: %s" % (" ".join(args[:2]), tail[:300]))
        return r

    def out(self, args, **kw):
        return self.run(args, **kw).stdout.strip()

    def _may_push(self, branch):
        if self.only_push and not branch.startswith(self.only_push):
            raise GitError("git push: refused, %s is outside %s (a replay writes only there)" % (branch, self.only_push))

    # ---- the clone ----
    def ensure_clone(self, counts=None):
        if os.path.isdir(os.path.join(self.work, ".git")):
            self.run(["remote", "set-url", "origin", self.remote], check=False)
            return
        os.makedirs(os.path.dirname(self.work), exist_ok=True)
        if counts is not None:
            counts["clone"] = counts.get("clone", 0) + 1
        r = subprocess.run(["git", "clone", "--quiet", self.remote, self.work], capture_output=True, text=True, timeout=600, env=self.env)
        if r.returncode != 0:
            raise GitError("git clone: " + " ".join((r.stderr or "").strip().splitlines()[-2:])[:300])

    def fetch_base(self, base, counts=None):
        """origin/<base> up to date; → its sha."""
        self.run(["fetch", "--quiet", "--prune", "origin", "+refs/heads/%s:refs/remotes/origin/%s" % (base, base)], counts=counts)
        return self.out(["rev-parse", "refs/remotes/origin/" + base])

    def show_file(self, rev, path):
        """The text of path at rev, or None when it is not there."""
        r = self.run(["show", "%s:%s" % (rev, path)], check=False)
        return r.stdout if r.returncode == 0 else None

    def fetch_pr(self, pr, counts=None, sha=None):
        """refs/pull/<pr>/head → refs/mq/pull/<pr>; → its sha. With sha (a replay): that commit, fetched by its sha, even when no branch holds it."""
        self.run(["fetch", "--quiet", "origin", "+%s:refs/mq/pull/%d" % (sha or "refs/pull/%d/head" % pr, pr)], counts=counts)
        return self.out(["rev-parse", "refs/mq/pull/%d" % pr])

    def remote_branch(self, branch, counts=None):
        """The sha of origin's branch, or '' when there is none."""
        out = self.out(["ls-remote", "--heads", "origin", "refs/heads/" + branch], counts=counts)
        return out.split()[0] if out else ""

    def push_branch(self, local, branch, counts=None):
        self._may_push(branch)
        self.run(["push", "--quiet", "origin", "%s:refs/heads/%s" % (local, branch)], counts=counts, timeout=300)

    def is_ancestor(self, a, b):
        """True when commit a is in the history of commit b (or is b)."""
        return self.run(["merge-base", "--is-ancestor", a, b], check=False).returncode == 0

    def merge_conflicts(self, a, b):
        """Would commits a and b merge? → None when they do (a tree is made, nothing is written to a branch), else the list of conflicted paths ([] when git names none).
        Raises GitError when git cannot tell (a missing object, an old git without merge-tree --write-tree)."""
        r = self.run(["merge-tree", "--write-tree", "--name-only", "--no-messages", a, b], check=False)
        if r.returncode == 0:
            return None
        if r.returncode != 1:
            raise GitError("git merge-tree: " + " ".join((r.stderr or r.stdout or "").strip().splitlines()[-1:])[:200])
        names = []
        for ln in r.stdout.splitlines()[1:]:
            if not ln.strip():
                break
            names.append(ln.strip())
        return names

    def push_fast_forward(self, sha, branch, counts=None):
        """sha → origin's branch, as a fast-forward only: no force and no lease. The remote refuses a push that is not one (the branch moved), and so does this."""
        self._may_push(branch)
        self.run(["push", "--quiet", "origin", "%s:refs/heads/%s" % (sha, branch)], counts=counts, timeout=300)

    def delete_remote_branch(self, branch, counts=None):
        """True when the branch was deleted, False when there was none. Reads before it writes, so nothing is pushed for a branch that is not there."""
        self._may_push(branch)
        if not self.remote_branch(branch, counts=counts):
            return False
        self.run(["push", "--quiet", "origin", "--delete", "refs/heads/" + branch], counts=counts)
        return True

    # ---- worktrees ----
    def worktree_add(self, path, branch, base_sha):
        self.worktree_remove(path, branch)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.run(["worktree", "add", "-q", "-B", branch, path, base_sha])

    def worktree_remove(self, path, branch=None):
        if os.path.isdir(path):
            self.run(["worktree", "remove", "--force", path], check=False)
        if os.path.isdir(path):
            import shutil
            shutil.rmtree(path, ignore_errors=True)
        self.run(["worktree", "prune"], check=False)
        if branch:
            self.run(["branch", "-D", "-q", branch], check=False)

    def drop_pr_refs(self, prs):
        for pr in prs:
            self.run(["update-ref", "-d", "refs/mq/pull/%d" % pr], check=False)
