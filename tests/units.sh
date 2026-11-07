#!/usr/bin/env bash
# Every service unit sala ships under systemd/ and contrib/*/systemd/ names the model lane it runs on: one
# `X-Model-Lane=<lane>` line in its [Unit] section, the lane one of the vocabulary below, so the Schedules tab of the Overview can list it.
# An optional `X-Model-Note=<text>` line (at most one, not empty) is shown beside the lane. systemd ignores X- keys in [Unit]; the lines are metadata. The value is read from what the unit's script runs, never guessed
# (docs/units.md). Also: each .timer has its .service, and each .service with a timer is covered by the check.
# Usage: bash tests/units.sh   (exit 0 = pass; under a second; reads files only, writes nothing)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
LANES=" subscription-1 bedrock aws-platform api subscription-2 sdk none "
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
n=0
for dir in systemd contrib/*/systemd; do
    [ -d "$dir" ] || continue
    for t in "$dir"/*.timer; do
        [ -e "$t" ] || continue
        [ -f "${t%.timer}.service" ] && ok "$t has its service" || bad "$t has no ${t%.timer}.service beside it"
    done
    for s in "$dir"/*.service; do
        [ -e "$s" ] || continue
        # the service must have an ExecStart in a [Service] section (the unit starts something)
        awk '/^\[/ {sec=$0} sec=="[Service]" && /^ExecStart=/ {f=1} END {exit !f}' "$s" || { ok "$s has no ExecStart: not checked"; continue; }
        n=$((n+1))
        # X-Model-Lane lines inside [Unit] (a comment line starts with # and never matches)
        mapfile -t found < <(awk '/^\[/ {sec=$0} sec=="[Unit]" && /^X-Model-Lane=/ {sub(/^X-Model-Lane=/, ""); print}' "$s")
        outside=$(awk '/^\[/ {sec=$0} sec!="[Unit]" && /^X-Model-Lane=/ {c++} END {print c+0}' "$s")
        if [ "${#found[@]}" -ne 1 ]; then bad "$s: ${#found[@]} X-Model-Lane= lines in [Unit] (need exactly one)"; continue; fi
        [ "$outside" = 0 ] || { bad "$s: X-Model-Lane= outside [Unit]"; continue; }
        case "$LANES" in *" ${found[0]} "*) ;; *) bad "$s: X-Model-Lane=${found[0]} is not one of:$LANES"; continue ;; esac
        # X-Model-Note=<text> in [Unit] is optional (at most one, never empty, never outside [Unit]); the Schedules tab shows it as the lane chip's tooltip
        mapfile -t notes < <(awk '/^\[/ {sec=$0} sec=="[Unit]" && /^X-Model-Note=/ {sub(/^X-Model-Note=/, ""); print}' "$s")
        nout=$(awk '/^\[/ {sec=$0} sec!="[Unit]" && /^X-Model-Note=/ {c++} END {print c+0}' "$s")
        if [ "${#notes[@]}" -gt 1 ]; then bad "$s: ${#notes[@]} X-Model-Note= lines in [Unit] (at most one)"; continue; fi
        [ "$nout" = 0 ] || { bad "$s: X-Model-Note= outside [Unit]"; continue; }
        if [ "${#notes[@]}" = 1 ] && [ -z "${notes[0]//[[:space:]]/}" ]; then bad "$s: X-Model-Note= is empty (leave the line out instead)"; continue; fi
        # X-Project=<scope/project> in [Unit]: the job's category on the Overview's Schedules tab, written as the Agents table's Project column shows it.
        # Required of a service with a timer beside it (a job); another service may carry one (at most one), never outside [Unit]
        mapfile -t projs < <(awk '/^\[/ {sec=$0} sec=="[Unit]" && /^X-Project=/ {sub(/^X-Project=/, ""); print}' "$s")
        pout=$(awk '/^\[/ {sec=$0} sec!="[Unit]" && /^X-Project=/ {c++} END {print c+0}' "$s")
        if [ "${#projs[@]}" -gt 1 ]; then bad "$s: ${#projs[@]} X-Project= lines in [Unit] (at most one)"; continue; fi
        [ "$pout" = 0 ] || { bad "$s: X-Project= outside [Unit]"; continue; }
        if [ "${#projs[@]}" = 0 ] && [ -f "${s%.service}.timer" ]; then bad "$s: a job (it has a timer) with no X-Project=<scope/project> in [Unit]"; continue; fi
        if [ "${#projs[@]}" = 1 ] && ! [[ ${projs[0]} =~ ^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]]; then bad "$s: X-Project=${projs[0]} is not scope/project (projects/general, beta/pr)"; continue; fi
        ok "$s: X-Model-Lane=${found[0]}${notes[0]:+ (X-Model-Note: ${notes[0]})}${projs[0]:+ X-Project=${projs[0]}}"
    done
done
[ "$n" -gt 0 ] || bad "no service units found (run from a checkout)"
echo "units: $n service unit(s) checked, $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
