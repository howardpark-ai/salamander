#!/bin/sh
# SALA_QUESTION_FILE_CMD's default: files a parked question as a board item through stackshot's client.py.
# What it does and its settings: contrib/question-board.py, docs/stuck-question-recovery.md.
d=$0; [ -L "$d" ] && d=$(readlink -f "$d")   # (no dirname/readlink process unless the script is a symlink)
case $d in */*) d=${d%/*} ;; *) d=. ;; esac
exec python3 -I -S "$(cd -P "$d" && pwd -P)/question-board.py" file
