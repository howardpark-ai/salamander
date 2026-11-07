#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["botocore>=1.41.0"]
#
# [tool.uv]
# exclude-newer = "2026-10-03T04:00:00Z"
# ///
"""help_review_call.py: the one model call of help-review.sh (check 3 of the help-text gates).

Reads the prompt on stdin (or from the file named by the one argument), makes ONE signed call to Amazon Bedrock, prints the model's
reply text on stdout (and, when Bedrock says why it stopped, one stderr line `help_review_call: stop_reason=<value>`). Exit 0 with the text; any failure exits 1 with one scrubbed line on stderr (help-review.sh retries once and then
skips, so a model outage never blocks a merge). It makes no decision about the verdict and never prints a key.

SIGN-IN. An AWS sign-in, not a lane: in CI the credentials in the environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN, put there by the workflow's OIDC sign-in step), else the AWS profile named by ANTHROPIC_AWS_PROFILE (by hand, in the user's ~/.aws), SigV4 with botocore,
service `bedrock`, POST https://bedrock-runtime.<region>.amazonaws.com/model/<model id>/invoke with the Anthropic Messages body plus
`anthropic_version: bedrock-2023-05-31` (the InvokeModel call; no boto3 needed, botocore signs it). The model is Haiku 5.5 through the global
inference profile `global.anthropic.claude-haiku-5-5`; the credentials' policy allows Bedrock invoke of the review model only. With AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment those are used (botocore adds
AWS_SESSION_TOKEN to the signed request) and the profile is not read. Environment (the ANTHROPIC_AWS_ names are kept to avoid churn; no workspace id is needed):
    ANTHROPIC_AWS_PROFILE        no default: used only when no keys are in the environment; unset too, the call fails saying so
    ANTHROPIC_AWS_REGION         no default: else AWS_REGION or AWS_DEFAULT_REGION; none set, the call fails saying so
    SALA_REVIEW_MODEL            default global.anthropic.claude-haiku-5-5
    SALA_REVIEW_HTTP_TIMEOUT     seconds the HTTPS call may take (default 60)
    SALA_REVIEW_MAX_TOKENS       default 600

It is a PEP 723 script: run it with `uv run --locked --script .github/scripts/help_review_call.py`, which reads the lock beside it
(help_review_call.py.lock, made by `uv lock --script .github/scripts/help_review_call.py`). Never pip install."""
from __future__ import annotations

import json
import os
import re
import sys

SERVICE = "bedrock"
DEFAULT_MODEL = "global.anthropic.claude-haiku-5-5"
DEFAULT_PROFILE = ""   # no default: a profile is for a run by hand (ANTHROPIC_AWS_PROFILE)
DEFAULT_REGION = ""   # no default: the region is a setting of the job (ANTHROPIC_AWS_REGION, AWS_REGION or AWS_DEFAULT_REGION)


def scrub(text: object, limit: int = 300) -> str:
    """One line, no credential-shaped text."""
    s = re.sub(r"(AKIA|ASIA)[A-Z0-9]{16}", "[key id]", str(text))
    s = re.sub(r"(?i)([a-z_]*(?:secret|token|signature|credential)[a-z_]*)[\"']?\s*[:=]\s*[\"']?[A-Za-z0-9/+=_\-]{12,}", r"\1=[hidden]", s)
    return " ".join(s.split())[:limit]


def fail(msg: str):
    print(f"help_review_call: {scrub(msg)}", file=sys.stderr)
    sys.exit(1)


def main(argv: list[str]) -> int:
    import urllib.error
    import urllib.parse
    import urllib.request
    env = os.environ
    region = (env.get("ANTHROPIC_AWS_REGION") or env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION") or "").strip() or DEFAULT_REGION
    if not region:
        fail("ANTHROPIC_AWS_REGION is not set (and neither are AWS_REGION and AWS_DEFAULT_REGION): name the region of the Bedrock endpoint")
    profile = env.get("ANTHROPIC_AWS_PROFILE", "").strip() or DEFAULT_PROFILE
    model = env.get("SALA_REVIEW_MODEL", "").strip() or DEFAULT_MODEL
    try:
        timeout = float(env.get("SALA_REVIEW_HTTP_TIMEOUT") or 60)
        max_tokens = int(env.get("SALA_REVIEW_MAX_TOKENS") or 600)
    except ValueError:
        fail("SALA_REVIEW_HTTP_TIMEOUT / SALA_REVIEW_MAX_TOKENS is not a number")
    try:
        if len(argv) > 1:
            with open(argv[1], encoding="utf-8", errors="replace") as f:
                prompt = f.read()
        else:
            prompt = sys.stdin.read()
    except OSError as e:
        fail(f"the prompt could not be read: {e}")
    if not prompt.strip():
        fail("the prompt is empty")
    try:
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
        from botocore.session import Session
    except ImportError as e:
        fail(f"botocore is not available ({e}); run with `uv run --locked --script`")
    try:
        # keys already in the environment win; a named profile would make botocore ignore them
        keys_in_env = bool(env.get("AWS_ACCESS_KEY_ID") and env.get("AWS_SECRET_ACCESS_KEY"))
        if not keys_in_env and not profile:
            fail("no AWS sign-in: put AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN) in the environment, or name a profile in ANTHROPIC_AWS_PROFILE")
        creds = (Session() if keys_in_env else Session(profile=profile)).get_credentials()
    except Exception as e:
        fail(f"the AWS sign-in could not be read ({type(e).__name__}): {e}")
    if creds is None:
        fail(f"the AWS profile {profile} has no credentials")
    url = f"https://bedrock-runtime.{region}.amazonaws.com/model/{urllib.parse.quote(model, safe='')}/invoke"
    body = json.dumps({"anthropic_version": "bedrock-2023-05-31", "max_tokens": max_tokens, "messages": [{"role": "user", "content": prompt}]}).encode("utf-8")
    try:
        req = AWSRequest(method="POST", url=url, data=body, headers={"content-type": "application/json", "accept": "application/json"})
        SigV4Auth(creds.get_frozen_credentials(), SERVICE, region).add_auth(req)
        headers = dict(req.headers.items())
    except Exception as e:
        fail(f"could not sign the request ({type(e).__name__}): {e}")
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method="POST"), timeout=timeout) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except Exception as e:
        fail(f"the call failed ({type(e).__name__}): {e}")
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = None
    if status != 200:
        # Bedrock errors are {"message": "..."}; tolerate the Anthropic {"error": {"type", "message"}} shape too
        err = doc.get("error") if isinstance(doc, dict) else None
        if isinstance(err, dict):
            detail = f"{err.get('type')}: {err.get('message')}"
        elif isinstance(doc, dict) and doc.get("message"):
            detail = str(doc["message"])
        else:
            detail = raw.decode("utf-8", "replace")
        fail(f"HTTP {status}: {detail}")
    parts = [b.get("text", "") for b in (doc.get("content") or []) if isinstance(b, dict) and b.get("type") == "text"] if isinstance(doc, dict) else []
    text = "".join(parts)
    if not text.strip():
        fail("the reply has no text")
    stop = doc.get("stop_reason") if isinstance(doc, dict) else None
    if stop:   # stderr only (stdout stays the reply text): help-review.sh shows it, so a reply cut off by max_tokens can be told from prose
        print(f"help_review_call: stop_reason={scrub(stop, 60)}", file=sys.stderr)
    sys.stdout.write(text if text.endswith("\n") else text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
