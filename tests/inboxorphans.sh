#!/usr/bin/env bash
# The held keys no ledger row accounts for (lib/common.sh, inbox_release_orphans, called by inbox_release_stale; docs/stackshot-contracts.md,
# interface 3). sala holds stackshot's inbox for a pane across its relaunch: the keys go into held-msg.txt and held-hub.txt and a row into
# the ledger salamander-inbox-holds.tsv, and inbox_release_stale frees a hold through its row. The two live in different folders, so a move
# of the host, a restore from backup or a half-failed release can leave keys held with no row, and nothing freed them. Checked here, in
# an isolated HOME with a temporary hold folder and ledger (never the real ones), the clock faked by pre-seeding the first-seen file:
#   a key with no row is left alone before SALA_INBOX_ORPHAN_SECS and freed from BOTH held files after; the first pass only notes it;
#   a row accounts for its uuid and for its name, whatever its age: those keys are untouched by the new path and leave the first-seen
#   file; the row path (inbox_release_stale on an old row) is as before; a key that left the held files is dropped from the first-seen
#   file and never freed; a second pass frees nothing and a key that comes back starts its wait over; keys held in one file only;
#   stackshot's held-resume-msg.txt and held-resume-hub.txt (its reboot resume's own files) are never read, written or freed;
#   a missing hold folder is a no-op; the sweep waits for the hold lock, and takes it only for itself (nothing left held).
# Usage: bash tests/inboxorphans.sh   (exit 0 = pass; seconds; no tmux)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-inboxorphans.XXXXXX") || exit 1
trap 'kill "${HP:-}" 2>/dev/null; rm -rf "$T"' EXIT
exec 7< "$T"; flock -n 7 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock (fd 8 is the hold lock's)
export HOME="$T/home"; mkdir -p "$HOME"
unset XDG_STATE_HOME XDG_CONFIG_HOME TMUX TMUX_PANE
export SALA_CONFIG=/dev/null SALA_INBOX_HOLD_DIR="$T/hold"
mkdir -p "$SALA_INBOX_HOLD_DIR" "$HOME/.claude"
. "$ROOT/lib/common.sh"
SEEN="$SALA_STATE_DIR/inbox-held-unaccounted.tsv"; LEDGER="$SALA_INBOX_LEDGER"; HM="$SALA_INBOX_HOLD_DIR/held-msg.txt"; HH="$SALA_INBOX_HOLD_DIR/held-hub.txt"
case "$LEDGER" in "$T"/*) ;; *) bad "the ledger is outside the sandbox: $LEDGER"; exit 1 ;; esac
case "$SEEN" in "$T"/*) ;; *) bad "the first-seen file is outside the sandbox: $SEEN"; exit 1 ;; esac
U1=11111111-0000-4000-8000-000000000001 U2=22222222-0000-4000-8000-000000000002 U3=33333333-0000-4000-8000-000000000003
now() { printf '%(%s)T' -1; }
reset() { : > "$HM"; : > "$HH"; : > "$LEDGER"; rm -f "$SEEN"; INBOX_ORPHANS_FREED=(); }
hold_both() { local k; for k in "$@"; do printf '%s\n' "$k" >> "$HM"; printf '%s\n' "$k" >> "$HH"; done; }
seed() { local t=$1 k; shift; mkdir -p "${SEEN%/*}"; for k in "$@"; do printf '%s\t%s\n' "$t" "$k"; done >> "$SEEN"; }   # <epoch> <key…>: the first time sala saw each key
held() { grep -cxF -- "$1" "$HM" "$HH" 2>/dev/null | awk -F: '{n += $NF} END {print n+0}'; }   # how many of the two files carry the key
seen_has() { [ -f "$SEEN" ] && awk -F'\t' -v k="$1" '$2 == k {f = 1} END {exit !f}' "$SEEN"; }
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER"; }   # <epoch> <uuid> <name>

echo "== a held key with no ledger row: left alone before the wait, freed from both files after"
reset; hold_both X; N=$(now)
inbox_release_orphans
[ "$(held X)" = 2 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && seen_has X && ok "first pass: noted, nothing freed" || bad "first pass: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]} seen=$(cat "$SEEN" 2>/dev/null)"
t=$(awk -F'\t' '$2 == "X" {print $1}' "$SEEN"); [ "$t" -ge "$N" ] && [ "$t" -le "$(now)" ] && ok "the first-seen epoch is the time of the first pass" || bad "first-seen: $t"
reset; hold_both X; seed $(( $(now) - 599 + 5 )) X   # seen 594 s ago: 6 s short of the 600
inbox_release_orphans
[ "$(held X)" = 2 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "seen 594 s ago: not freed" || bad "594 s: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]}"
reset; hold_both X Y; seed $(( $(now) - 601 )) X; seed $(( $(now) - 30 )) Y
inbox_release_orphans
[ "$(held X)" = 0 ] && [ "${INBOX_ORPHANS_FREED[*]}" = X ] && ok "seen 601 s ago: freed from held-msg.txt and held-hub.txt, and reported" || bad "601 s: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]}"
[ "$(held Y)" = 2 ] && seen_has Y && ! seen_has X && ok "a young key beside it stays held and noted; the freed key is no longer remembered" || bad "Y: held=$(held Y); seen: $(cat "$SEEN" 2>/dev/null)"
grep -qxF Y "$HM" && grep -qxF Y "$HH" && [ "$(wc -l < "$HM")" = 1 ] && [ "$(wc -l < "$HH")" = 1 ] && ok "the held files were rewritten with only the other key in them" || bad "held files: $(cat "$HM" "$HH")"

echo "== a key held in one file only, and one after a pass of the other"
reset; printf 'A\n' >> "$HM"; printf 'B\n' >> "$HH"; seed $(( $(now) - 700 )) A B
inbox_release_orphans
[ ! -s "$HM" ] && [ ! -s "$HH" ] && [ "${#INBOX_ORPHANS_FREED[@]}" = 2 ] && ok "a key in held-msg.txt only and one in held-hub.txt only are each freed" || bad "one-file keys: msg=[$(cat "$HM")] hub=[$(cat "$HH")] freed=${INBOX_ORPHANS_FREED[*]}"
[ ! -e "$SEEN" ] && ok "nothing left to remember: the first-seen file is gone" || bad "first-seen file kept: $(cat "$SEEN")"

echo "== a key with a ledger row is untouched by the new path, whatever the row's age"
reset; hold_both "$U1" NAME1 "$U2" NAME2 "$U3" NAME3; printf 'NAMEONLY\n' >> "$HM"; printf 'UUIDONLY\n' >> "$HH"
row $(( $(now) - 100 )) "$U1" NAME1; row $(( $(now) - 7200 )) "$U2" NAME2
row $(( $(now) - 9000 )) 9999 NAMEONLY    # a row that names the key as the session name only
row $(( $(now) - 9000 )) UUIDONLY nobody  # a row that names the key as the uuid only
seed $(( $(now) - 9000 )) "$U1" NAME1 "$U2" NAME2 NAMEONLY UUIDONLY "$U3" NAME3   # remembered from before the rows: the accounted ones are dropped
inbox_release_orphans
[ "$(held "$U1")" = 2 ] && [ "$(held NAME1)" = 2 ] && [ "$(held "$U2")" = 2 ] && [ "$(held NAME2)" = 2 ] && [ "$(held NAMEONLY)" = 1 ] && [ "$(held UUIDONLY)" = 1 ] && ok "a row accounts for its uuid and its name (young and two hours old): nothing of them freed" || bad "rows: $(cat "$HM" "$HH" | sort | uniq -c | tr '\n' ' ')"
[ "$(held "$U3")" = 0 ] && [ "$(held NAME3)" = 0 ] && [ "${INBOX_ORPHANS_FREED[*]}" = "$U3 NAME3" ] && ok "the two keys no row names, remembered for 9000 s, are the only ones freed" || bad "freed: ${INBOX_ORPHANS_FREED[*]} ($(cat "$HM" | tr '\n' ' '))"
! seen_has "$U1" && ! seen_has NAME2 && ! seen_has NAMEONLY && ! seen_has UUIDONLY && [ ! -e "$SEEN" ] && ok "a key a row now accounts for is dropped from the first-seen file" || bad "first-seen: $(cat "$SEEN" 2>/dev/null)"
[ "$(wc -l < "$LEDGER")" = 4 ] && ok "the ledger itself is not touched" || bad "ledger: $(cat "$LEDGER")"

echo "== the row path is as before: an old row frees its keys and goes, a young one stays"
reset; hold_both "$U1" NAME1 "$U2" NAME2; row $(( $(now) - 700 )) "$U1" NAME1; row $(( $(now) - 100 )) "$U2" NAME2
inbox_release_stale
[ "$(held "$U1")" = 0 ] && [ "$(held NAME1)" = 0 ] && [ "$(held "$U2")" = 2 ] && [ "$(held NAME2)" = 2 ] && ! grep -qF "$U1" "$LEDGER" && grep -qF "$U2" "$LEDGER" && ok "the 700 s row released its uuid and name and left the ledger; the 100 s row did not" || bad "row path: $(cat "$HM" | tr '\n' ' ') / $(cat "$LEDGER")"
[ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && [ ! -e "$SEEN" ] && ok "none of it counted as unaccounted, nothing remembered" || bad "freed=${INBOX_ORPHANS_FREED[*]} seen=$(cat "$SEEN" 2>/dev/null)"
reset; hold_both X; seed $(( $(now) - 700 )) X
inbox_release_stale
[ "$(held X)" = 0 ] && [ "${INBOX_ORPHANS_FREED[*]}" = X ] && ok "inbox_release_stale (the watch's call) frees an old unaccounted key too, with an empty ledger" || bad "stale: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]}"

echo "== a key that left the held files is dropped from the first-seen file, never freed"
reset; hold_both K; seed $(( $(now) - 30 )) K; seed $(( $(now) - 9000 )) GONE1 GONE2
inbox_release_orphans
[ "$(held K)" = 2 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "an old entry of a key no longer held frees nothing" || bad "gone: held=$(held K) freed=${INBOX_ORPHANS_FREED[*]}"
seen_has K && ! seen_has GONE1 && ! seen_has GONE2 && [ "$(wc -l < "$SEEN")" = 1 ] && ok "the first-seen file lost the keys that are gone and kept the held one" || bad "first-seen: $(cat "$SEEN")"
: > "$HM"; : > "$HH"
inbox_release_orphans
[ ! -e "$SEEN" ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "nothing held: the file goes too" || bad "empty files: seen=$(cat "$SEEN" 2>/dev/null)"

echo "== a second pass frees nothing; a key that comes back starts its wait over"
reset; hold_both X; seed $(( $(now) - 700 )) X
inbox_release_orphans; first=("${INBOX_ORPHANS_FREED[@]}")
inbox_release_orphans
[ "${first[*]}" = X ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "freed once, the second pass frees nothing" || bad "twice: first=${first[*]} second=${INBOX_ORPHANS_FREED[*]}"
hold_both X
inbox_release_orphans
[ "$(held X)" = 2 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && seen_has X && ok "the same key held again is a new key: noted, not freed" || bad "back again: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]}"

echo "== a clock that stepped back (a first-seen time in the future) frees nothing"
reset; hold_both X; seed $(( $(now) + 5000 )) X
inbox_release_orphans
[ "$(held X)" = 2 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "not freed" || bad "future: held=$(held X) freed=${INBOX_ORPHANS_FREED[*]}"
t=$(awk -F'\t' '$2 == "X" {print $1}' "$SEEN"); [ "$t" -le "$(now)" ] && ok "and the stored time is brought back to now" || bad "stored time $t"

echo "== the hold folder missing, an unreadable ledger line, a key with odd characters"
reset; mv "$SALA_INBOX_HOLD_DIR" "$T/hold-away"; seed $(( $(now) - 700 )) X
inbox_release_orphans; rc=$?
[ "$rc" = 0 ] && [ ${#INBOX_ORPHANS_FREED[@]} = 0 ] && ok "no stackshot folder: nothing done (as the other hold functions)" || bad "no folder: rc=$rc freed=${INBOX_ORPHANS_FREED[*]}"
mv "$T/hold-away" "$SALA_INBOX_HOLD_DIR"
reset; hold_both 'we ird[key]*' 'plain'; printf 'garbage without tabs\n\n' >> "$LEDGER"; seed $(( $(now) - 700 )) 'we ird[key]*'
inbox_release_orphans
[ "$(held 'we ird[key]*')" = 0 ] && [ "$(held plain)" = 2 ] && ok "a key with a space, brackets and a star is freed exactly; the one beside it stays; a garbled ledger line does no harm" || bad "odd keys: $(cat "$HM" | tr '\n' ' ') freed=${INBOX_ORPHANS_FREED[*]}"

echo "== stackshot's reboot-resume holds are never touched: held-resume-msg.txt and held-resume-hub.txt stay as they are"
reset; RM="$SALA_INBOX_HOLD_DIR/held-resume-msg.txt"; RH="$SALA_INBOX_HOLD_DIR/held-resume-hub.txt"
printf '%s\nRESUMEONLY\nX\n' "$U1" > "$RM"; printf '%s\nRESUMEONLY\nX\n' "$U1" > "$RH"   # keys with no ledger row, one also held by sala, the first-seen file long past the wait
hold_both X OLDROW; printf '%s\tOLDROW\tOLDROW\n' $(( $(now) - 9000 )) > "$LEDGER"; seed $(( $(now) - 9000 )) X "$U1" RESUMEONLY
want=$(cksum "$RM" "$RH")
inbox_release_orphans; inbox_release_stale
[ "$(cksum "$RM" "$RH")" = "$want" ] && [ "$(held X)" = 0 ] && [ "$(held OLDROW)" = 0 ] && ok "both sweeps freed sala's own keys and left held-resume-msg.txt and held-resume-hub.txt byte-identical, their keys unfreed" || bad "resume files changed or sala's keys stayed: $(cksum "$RM" "$RH" | tr '\n' ' ') want=$(echo $want) held X=$(held X) OLDROW=$(held OLDROW)"
rm -f "$RM" "$RH"

echo "== the sweep takes the hold lock: a hold in progress is waited for, and nothing is left locked"
reset; hold_both X; seed $(( $(now) - 700 )) X; rm -f "$T/swept"
LOCKF="$SALA_INBOX_LEDGER.lock"
( exec 9>"$LOCKF"; flock 9; exec sleep 60 ) & HP=$!
waitfor '! flock -n "$LOCKF" true' 40 || bad "the lock holder did not take the lock"
( inbox_release_orphans; echo "${INBOX_ORPHANS_FREED[*]}" > "$T/swept" ) & SW=$!
nap 1
[ ! -e "$T/swept" ] && [ "$(held X)" = 2 ] && ok "with the lock held elsewhere the sweep has freed nothing yet" || bad "the sweep did not wait: $(cat "$T/swept" 2>/dev/null) held=$(held X)"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=
waitfor '[ -e "$T/swept" ]' 40
wait "$SW" 2>/dev/null
[ "$(cat "$T/swept" 2>/dev/null)" = X ] && [ "$(held X)" = 0 ] && ok "released, it ran and freed the key" || bad "after the release: swept=[$(cat "$T/swept" 2>/dev/null)] held=$(held X)"
flock -n "$LOCKF" true && ok "the lock is free again afterwards" || bad "the lock is still held"
[ -z "$(ls "$SALA_INBOX_HOLD_DIR" | grep -v '^held-\(msg\|hub\)\.txt$')" ] && ok "no temporary file left in the hold folder" || bad "left in the hold folder: $(ls "$SALA_INBOX_HOLD_DIR")"
[ -z "$(ls "$SALA_STATE_DIR" | grep 'inbox-held')" ] && ok "no first-seen file or temporary left behind once nothing is held" || bad "left in the state folder: $(ls "$SALA_STATE_DIR")"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
