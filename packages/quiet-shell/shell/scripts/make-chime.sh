#!/usr/bin/env bash
# Build the timer chime: three soft sine notes (E5, G#5, B5), each with a quiet
# bell-like partial, rising 0.22 s apart and fading out. Run at build time, so the
# sound is source, not a binary blob; -D turns dither off to keep it reproducible.
set -euo pipefail
out=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
note() { sox -D -n -r 48000 "$work/$1" synth 1.8 sine "$2" sine "$3" remix 1v0.8,2v0.12 fade p 0.008 1.8 1.75 gain -n -14; }
note e.wav 659.25 1819.5
note g.wav 830.61 2292.5
note b.wav 987.77 2726.2
sox -D -m "$work/e.wav" "|sox -D $work/g.wav -p pad 0.22" "|sox -D $work/b.wav -p pad 0.44" -C 8 "$out" gain -n -12 pad 0 1.2
