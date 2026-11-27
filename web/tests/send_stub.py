"""The composer's send answered in the page, for browser tests about what is sent and drawn: the fake session has no pane. A message goes to the
server's outbox (api/outbox/<name>), a "!" command or a slash command to api/s/<pid>/send; both are answered here."""

from __future__ import annotations

# JS: `__outboxAnswer(url, options)` stands in for the server's outbox. A POST adds the message, as queued in the pane; a GET lists what it
# holds; a cancel withdraws one. null for any other request.
OUTBOX = """window.__outbox = window.__outbox || [];
  window.__outboxAnswer = (u, o) => {
    const url = String(u);
    if (!url.startsWith("api/outbox/")) return null;
    const list = window.__outbox, now = Date.now();
    let body = { ok: true, messages: list };
    if (o && o.method === "POST" && url.endsWith("/cancel")) {
      const m = list.find((x) => url.includes("/" + x.id + "/"));
      if (m) { m.state = "withdrawn"; m.updated = now; }
      body = { ok: true, message: m, messages: list };
    } else if (o && o.method === "POST") {
      const sent = JSON.parse(o.body);
      const m = { id: "m" + (list.length + 1), cid: sent.cid, text: sent.text, uploads: sent.uploads, state: "queued", reason: null, error: "", created: now, updated: now };
      list.push(m);
      body = { ok: true, message: m, messages: list };
    }
    return Promise.resolve(new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } }));
  };"""


def spy_send(then: str = "return true;") -> str:
    """The script that keeps every sent message's {text, uploads} in `__sent` and answers it, then runs `then`."""
    return ("(() => { " + OUTBOX + """
  window.__sent = []; const real = window.fetch;
  window.fetch = (u, o) => {
    const post = !!o && o.method === "POST", box = __outboxAnswer(u, o);
    if (box) { if (post && !String(u).endsWith("/cancel")) { const { cid, ...sent } = JSON.parse(o.body); __sent.push(sent); } return box; }
    if (String(u).includes("/send")) { __sent.push(JSON.parse(o.body));
      return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "Content-Type": "application/json" } })); }
    return real(u, o); };
  """ + then + " })()")
