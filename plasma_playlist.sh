#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
player="${script_dir}/bin/plasma_player"
loop_mode=0

usage() {
    echo "Usage: $0 [--loop] song1.mp3 [song2.mp3 ...]" >&2
}

if [[ ! -x "${player}" ]]; then
    echo "Player executable not found: ${player}" >&2
    echo "Build the project first with: gprbuild -P mp3player.gpr" >&2
    exit 1
fi

if [[ $# -gt 0 && "$1" == "--loop" ]]; then
    loop_mode=1
    shift
fi

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

for song in "$@"; do
    if [[ ! -f "${song}" ]]; then
        echo "Song not found: ${song}" >&2
        exit 1
    fi
done

run_playlist_once() {
    local song

    for song in "$@"; do
        "${player}" "${song}"
    done
}

if [[ ${loop_mode} -eq 1 ]]; then
    while true; do
        run_playlist_once "$@"
    done
else
    run_playlist_once "$@"
fi
