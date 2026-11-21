# shellcheck shell=bash
# sala_slack_safe  — stdin to stdout: the text of a Slack post with every digit run between colons made safe from Slack's emoji codes.
# Slack reads `:NN:` as an emoji code and draws a gray box for it, so "<link|session>:0:" (a pane written after its session link),
# "04:00: the weekly run" and "(pane :1:)" all showed one. The fix is the invisible one: a zero-width space (U+200B) goes before the closing
# colon of a colon, a run of 1 or 2 digits and a colon, so the text reads as typed and Slack sees no code. Left as they are:
#   a code (3 or more digits, `:100:`), `:+1:`, `:-1:` and every named emoji (`:white_check_mark:`): the run is not 1 or 2 digits after the colon;
#   a time or a port that no colon follows (`04:00 `, `host:22`), a URL (`https://host:8080/`);
#   the URL part of a Slack link (`<https://host:80/x|label>`: everything before the `|`; the label after it is escaped like any text);
#   a code span or block (backticks): Slack does not render emoji in code.
# Linear in the text: a scheme starts only where no scheme character stands before it (the lookbehind in the url alternative), so a long run of
# letters and digits is scanned once from its start and not again from every character in it (a 39000-character token took over a second).
# Idempotent: the colon is no longer right after the digits once the space is in, so a second pass changes nothing.
# It runs on the FINAL text, after the link passes (sala_board_links, slack_links), right before the text leaves. One definition for every path:
# sala's own posts (lib/common.sh: sala_send_post, so sala_post, sala_notify_raw and `sala alert`; lib/stuck.sh: sq_send), `sala dm`
# (lib/dm.sh) and the briefings' posts (contrib/briefing/lib.sh: post_slack). A byte that is not UTF-8 passes through untouched.
sala_slack_safe() {
    python3 -I -c '
import re, sys
Z = chr(0x200b)
PROT = re.compile(
    r"(?P<fence>```.*?```)"
    r"|(?P<code>`[^`\n]*`)"
    r"|(?P<link><(?:[A-Za-z][A-Za-z0-9+.-]*://|mailto:|[@#!])[^<>\s|]*(?:\|(?P<label>[^<>\n]*))?>)"
    r"|(?P<url>(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s<>`]+)", re.S)
CODE = re.compile(r":[0-9]{1,2}(?=:)")
def esc(s): return CODE.sub(lambda m: m.group(0) + Z, s)
def part(m):
    if m.group("link") is not None and m.group("label") is not None:
        t = m.group(0); i = len(t) - len(m.group("label")) - 1
        return t[:i] + esc(m.group("label")) + ">"
    return m.group(0)
def fix(t):
    out, pos = [], 0
    for m in PROT.finditer(t):
        out.append(esc(t[pos:m.start()])); out.append(part(m)); pos = m.end()
    out.append(esc(t[pos:]))
    return "".join(out)
raw = sys.stdin.buffer.read()
try: res = fix(raw.decode("utf-8", "surrogateescape")).encode("utf-8", "surrogateescape")
except Exception: res = raw
sys.stdout.buffer.write(res)
'
}
# sala_slack_safe_send  — stdin to stdout, for a post about to leave: sala_slack_safe, and never a lost post. A filter that fails, or gives nothing for
# a text that had something, sends the text as it came in (an emoji code drawn as a gray box beats a post that never arrives, and an empty body some
# notifier accepts would read as sent) and says so in one line of the watch log.
sala_slack_safe_send() {
    local t; t=$(mktemp "${TMPDIR:-/tmp}/sala-safe.XXXXXX" 2>/dev/null) || { cat; return 0; }
    cat > "$t"
    if (umask 077; sala_slack_safe < "$t" > "$t.out" 2>/dev/null) && { [ -s "$t.out" ] || [ ! -s "$t" ]; }; then cat "$t.out"
    else
        echo "[$(date -Is)] slack escape: the filter failed or gave nothing; the post goes out as it is" >> "${WLOG:-${SALA_LOG_DIR:-$HOME/.claude}/salamander-watch.log}" 2>/dev/null
        cat "$t"
    fi
    rm -f "$t" "$t.out"
    return 0
}
