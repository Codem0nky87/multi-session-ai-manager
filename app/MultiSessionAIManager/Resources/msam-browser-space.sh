#!/bin/sh
# AI Manager browser space.
#
# Runs as the only process of a Herdr pane and marks that pane out: every cell
# is filled, and the top left says which browser space this is and how big the
# pane is. AI Manager finds the mark in the terminal it draws and lays its
# browser over exactly these cells. Any other terminal attached to the same
# Herdr shows this fill instead.
id=${1:-000000}
pid=

draw() {
    size=$(stty size 2>/dev/null) || return
    rows=${size% *}
    cols=${size#* }
    [ "$rows" -gt 0 ] 2>/dev/null && [ "$cols" -gt 0 ] 2>/dev/null || return
    fill=$(printf '%*s' "$cols" '' | sed 's/ /░/g')
    mark="[[AIM-BROWSER $id ${cols}x${rows}]]"
    printf '\033[?25l'
    r=1
    while [ "$r" -le "$rows" ]; do
        printf '\033[%d;1H%s' "$r" "$fill"
        r=$((r + 1))
    done
    # A mark cut short would be read as nothing at all, so leave it out.
    [ "${#mark}" -le "$cols" ] && printf '\033[1;1H%s' "$mark"
}

trap draw WINCH
# A stray Ctrl-C must not close the space. Herdr closes a pane with a hangup.
trap '' INT QUIT TSTP
trap 'kill "$pid" 2>/dev/null; exit 0' HUP TERM
stty -echo 2>/dev/null
draw
while :; do
    sleep 86400 &
    pid=$!
    wait "$pid"
    # wait came back because the pane was resized: one sleeper, not one per resize.
    kill "$pid" 2>/dev/null
done
