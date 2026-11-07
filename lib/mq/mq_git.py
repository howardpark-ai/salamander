"""lib/mq/mq_git.py — git for mq: the work clone, one worktree per group, and the remote operations, which are counted (docs/mq.md).

Building a group and pushing its branch use git over the remote and no REST call. Every operation that reaches the remote (clone, fetch,
ls-remote, push) is counted into the dict the caller hands in, so a group's record can say how many there were.
"""
import os
import subprocess


class GitError(Exception):
    pass


class IdentityError(GitError):
    """The merge commits would carry no identity, or a person's global one (Git.identity_problem)."""


REMOTE_OPS = ("clone", "fetch", "ls-remote", "push")
# The git verbs that never write a commit run with no identity, so a refused identity does not stop `mq doctor` from reading the clone. Every other verb
# (commit, merge, cherry-pick, …) needs a safe identity, so a verb added later is held back until it is listed here on purpose.
NO_IDENT = ("add", "branch", "clone", "diff", "fetch", "ls-remote", "merge-base", "merge-tree", "push", "remote", "reset", "rev-parse", "show", "update-ref", "worktree")
REFUSAL = ("refusing to make merge commits: %s. Set git_name and git_email in the host file "
           "($XDG_CONFIG_HOME/mergequeue/<owner>__<repo>.toml) to an identity made for the queue (docs/mq.md, Configuration)")


class Git:
    def __init__(self, work, remote, name=None, email=None, only_push=None):
        self.work = work
        self.remote = remote
        self.only_push = only_push       # replay: the one branch prefix a push or a delete may name (queue/practice/); None = any
        self.name, self.email = name or "", email or ""      # the host file's git_name and git_email; they win over everything below
        self._ident = None               # the identity's -c options, once a safe identity has resolved
        self.env = dict(os.environ, GIT_TERMINAL_PROMPT="0", LC_ALL="C")

    def _cfg(self, key, where=None):
        """`git config --get key` in the work clone (where = None; "" while the clone is not there, since git would then read the global file) or in the global files (where = "global")."""
        if where == "global":
            args = ["git", "config", "--global", "--get", key]
        elif os.path.isdir(os.path.join(self.work, ".git")):
            args = ["git", "-C", self.work, "config", "--get", key]
        else:
            return ""
        try:
            r = subprocess.run(args, capture_output=True, text=True, env=self.env, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""

    def identity(self):
        """→ (name, email, [what is wrong]). The host file's git_name and git_email win. A key it leaves unset is read from the WORK CLONE (`git -C <clone> config --get`), which
        carries the repo's own identity (its local config, or an includeIf rule of the global file), never from the caller's folder, where only a person's global file would answer.
        A value that came from the clone and equals the global one is refused, and so is an empty one: there is no fallback identity. The remote is not asked whether the repo is
        public (that would be a network call of its own), so the rule holds for every remote."""
        out, bad = [], []
        for key, explicit, hostkey in (("user.name", self.name, "git_name"), ("user.email", self.email, "git_email")):
            val = explicit or self._cfg(key)
            if not val:
                bad.append("%s is not set (the host file's %s is unset and the work clone has none of its own)" % (key, hostkey))
            elif not explicit and val == self._cfg(key, "global"):
                bad.append("the work clone's %s is the global git %s of the user the queue runs as, not one made for the queue" % (key, key))
            out.append(val)
        return out[0], out[1], bad

    def identity_problem(self):
        """→ the refusal text when the merge commits would have no safe identity, else None. None as well while the work clone is not there yet and the host file leaves a key
        unset: the question is asked again once the clone exists (and by the first commit)."""
        if (not self.name or not self.email) and not os.path.isdir(os.path.join(self.work, ".git")):
            return None
        bad = self.identity()[2]
        return REFUSAL % "; ".join(bad) if bad else None

    @property
    def ident(self):
        """The -c options of a commit-making command; raises IdentityError instead of falling back to some identity. Kept once resolved."""
        if self._ident is None:
            n, e, bad = self.identity()
            if bad:
                raise IdentityError(REFUSAL % "; ".join(bad))
            self._ident = ["-c", "user.name=" + n, "-c", "user.email=" + e]
        return self._ident

    def run(self, args, cwd=None, check=True, timeout=300, counts=None, input=None):
        """git <args> in cwd (default: the work clone) → CompletedProcess (text). A remote operation is added to counts."""
        if counts is not None:
            for op in REMOTE_OPS:
                if args and args[0] == op:
                    counts[op] = counts.get(op, 0) + 1
        try:
            ident = [] if args and args[0] in NO_IDENT else self.ident
            r = subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "merge.autoStash=false"] + ident + list(args), cwd=cwd or self.work, capture_output=True, text=True,
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
