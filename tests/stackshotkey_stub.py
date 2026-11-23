#!/usr/bin/env python3
"""tests/stackshotkey_stub.py: a stand-in for the server side of stackshot's caller keys, for tests/stackshotkey.sh. NOT stackshot: it implements only what the contract
(docs/stackshot-contracts.md, "A caller's own key") says of POST /keys/enroll and POST /keys/pass, on 127.0.0.1 and a random port, in memory.

    python3 stackshotkey_stub.py <port file>      writes the port to <port file> when it listens; runs until it is killed (the suite kills it by its PID)

  POST /keys/enroll  {public_key, label, sender} -> 200 {state: pending | approved, fingerprint, short, item}; a new key is pending with the next item `board#N`;
                     the same key again answers its state and changes nothing; 400 for a body that is not as the contract says.
  POST /keys/pass    {claim} -> a compact JWS checked as the contract says: at most 2048 characters, header {"alg": "EdDSA"}, the Ed25519 signature over `<header>.<payload>`
                     FIRST (a signature that is not the named key's is 403 state unknown for every fingerprint), then aud (this stub's own address, no trailing slash needed),
                     iat/exp numbers, life over 0 and at most 60 s, iat within 60 s of the clock, not expired, jti of 8 to 128 printable characters and not seen before
                     (401 with `error` for these), then the key's state (403 `pending`); 200 {pass: "ssp_...", expires_in: 600, fingerprint, sender}.
  Test-only controls (not in the contract):  POST /_admin {"approve": true | "<fingerprint prefix>", "fail": <status or 0>, "reset_log": true}   GET /_admin/log   GET /_admin/passes
  `fail` makes every /keys/pass answer that status with a JSON error. /_admin/log is the list of what was asked and answered (claim fields, never a pass); /_admin/passes the passes
  issued (the suite looks for them in every output it keeps: none may be there)."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _,+-]{0,79}$")
SENDER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")
FP_RE = re.compile(r"^[0-9a-f]{64}$")
LOCK = threading.Lock()
KEYS: dict[str, dict] = {}        # fingerprint -> {public_key, label, sender, state, item}
JTIS: set[tuple[str, str]] = set()
PASSES: dict[str, str] = {}       # pass -> fingerprint
LOG: list[dict] = []
MODE = {"fail": 0}
DUMMY = bytes(32)


def unb64u(s: str) -> bytes:
    if not re.fullmatch(r"[A-Za-z0-9_-]*", s):
        raise ValueError("not base64url")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and abs(v) < 1e12


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, status: int, obj: dict) -> None:
        raw = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self, limit: int):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            return None
        try:
            d = json.loads(self.rfile.read(n).decode("utf-8"))
        except ValueError:
            return None
        return d if isinstance(d, dict) else None

    def do_GET(self):
        if self.path == "/_admin/log":
            return self._send(200, {"log": LOG})
        if self.path == "/_admin/passes":
            return self._send(200, {"passes": list(PASSES)})
        self._send(404, {"error": "no such route"})

    def do_POST(self):
        with LOCK:
            if self.path == "/_admin":
                d = self._body(8192) or {}
                if "approve" in d:
                    for fp, k in KEYS.items():
                        if d["approve"] is True or fp.startswith(str(d["approve"])):
                            k["state"] = "approved"
                if "fail" in d:
                    MODE["fail"] = int(d["fail"])
                if d.get("reset_log"):
                    LOG.clear()
                return self._send(200, {"ok": True})
            if self.path == "/keys/enroll":
                return self._enroll()
            if self.path == "/keys/pass":
                return self._pass()
        self._send(404, {"error": "no such route"})

    def _enroll(self):
        d = self._body(8192)
        pk = d.get("public_key") if d else None
        try:
            raw = unb64u(pk) if isinstance(pk, str) and len(pk) == 43 else None
            if raw is None or len(raw) != 32:
                raise ValueError
            Ed25519PublicKey.from_public_bytes(raw)
        except Exception:
            LOG.append({"op": "enroll", "status": 400})
            return self._send(400, {"error": "public_key is not an Ed25519 key in base64url (43 characters)"})
        if not (isinstance(d.get("label"), str) and LABEL_RE.match(d["label"]) and isinstance(d.get("sender"), str) and SENDER_RE.match(d["sender"])):
            LOG.append({"op": "enroll", "status": 400})
            return self._send(400, {"error": "label or sender is not as the contract says"})
        fp = hashlib.sha256(raw).hexdigest()
        k = KEYS.get(fp)
        new = k is None
        if new:
            k = KEYS[fp] = {"public_key": pk, "label": d["label"], "sender": d["sender"], "state": "pending", "item": "board#%d" % (len(KEYS) + 40)}
        LOG.append({"op": "enroll", "status": 200, "new": new, "fp": fp, "label": d["label"], "sender": d["sender"], "state": k["state"], "public_key_len": len(pk)})
        self._send(200, {"state": k["state"], "fingerprint": fp, "short": fp[:16], "item": k["item"] if k["state"] == "pending" else ""})

    def _pass(self):
        entry = {"op": "pass", "origin": self._origin()}
        LOG.append(entry)
        if MODE["fail"]:
            entry["status"] = MODE["fail"]
            return self._send(MODE["fail"], {"error": "the stub was told to fail"})
        d = self._body(8192)
        claim = d.get("claim") if d else None
        if not isinstance(claim, str) or len(claim) > 2048 or claim.count(".") != 2:
            entry["status"] = 400
            return self._send(400, {"error": "no compact JWS"})
        entry["claim_len"] = len(claim)
        h, p, s = claim.split(".")
        try:
            head, pay, sig = json.loads(unb64u(h)), json.loads(unb64u(p)), unb64u(s)
            assert isinstance(head, dict) and isinstance(pay, dict)
        except Exception:
            entry["status"] = 400
            return self._send(400, {"error": "the parts are not JSON objects"})
        entry.update(header=head, payload={k: v for k, v in pay.items()}, header_text=unb64u(h).decode("ascii", "replace"))
        iss = pay.get("iss")
        if head.get("alg") != "EdDSA" or not (isinstance(iss, str) and FP_RE.match(iss)):
            entry["status"] = 401
            return self._send(401, {"error": "header or iss"})
        k = KEYS.get(iss)
        raw = unb64u(k["public_key"]) if k else DUMMY
        try:
            Ed25519PublicKey.from_public_bytes(raw).verify(sig, ("%s.%s" % (h, p)).encode("ascii"))
            proven = k is not None
        except (InvalidSignature, ValueError):
            proven = False
        entry["signature_ok"] = proven
        if not proven:
            entry["status"] = 403
            return self._send(403, {"error": "claim refused: the key is not approved", "state": "unknown"})
        now = time.time()
        iat, exp, jti = pay.get("iat"), pay.get("exp"), pay.get("jti")
        aud = pay.get("aud")
        if aud not in (self._origin(), self._origin() + "/") and str(aud).rstrip("/") != self._origin():
            entry["status"] = 401
            return self._send(401, {"error": "aud is not this board"})
        if not (is_num(iat) and is_num(exp)) or not (isinstance(jti, str) and 8 <= len(jti) <= 128 and jti.isprintable()):
            entry["status"] = 401
            return self._send(401, {"error": "a bad iat, exp or jti"})
        if not 0 < exp - iat <= 60 or abs(now - iat) > 60:
            entry["status"] = 401
            return self._send(401, {"error": "the claim's life or clock"})
        if exp < now:
            entry["status"] = 401
            return self._send(401, {"error": "expired"})
        if (iss, jti) in JTIS:
            entry["status"] = 401
            return self._send(401, {"error": "jti already used"})
        JTIS.add((iss, jti))
        if k["state"] != "approved":
            entry["status"] = 403
            return self._send(403, {"error": "claim refused: the key is not approved", "state": "pending"})
        tok = "ssp_" + secrets.token_urlsafe(32)
        PASSES[tok] = iss
        entry.update(status=200, pass_sha12=hashlib.sha256(tok.encode()).hexdigest()[:12])
        self._send(200, {"pass": tok, "expires_in": 600, "fingerprint": iss, "sender": k["sender"]})

    def _origin(self) -> str:
        return "http://127.0.0.1:%d" % self.server.server_address[1]


def main(argv: list[str]) -> int:
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(argv[1], "w", encoding="utf-8") as f:
        f.write(str(srv.server_address[1]) + "\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
