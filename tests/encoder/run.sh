#!/bin/bash
# Builds libmvt + mvt_test, runs paced encodes, validates with ffprobe/ffmpeg and measures PSNR.
# usage: tests/encoder/run.sh [quick]   (output in tests/encoder/out, log in out/results.txt)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
mkdir -p "$out"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" >/dev/null
bin="$here/build/mvt_test"
log="$out/results.txt"
: >"$log"
fail=0

say() { echo "$*" | tee -a "$log"; }

# check <name> <width> <height> <ten_bit 0|1> <streams> <frames> <codec ext>
check() {
    local name=$1 w=$2 h=$3 ten=$4 streams=$5 frames=$6 ext=$7
    local tb=""
    [ "$ten" = 1 ] && tb="--ten-bit"
    for ((s = 0; s < streams; s++)); do
        local f="$out/$name-s$s.$ext"
        local info
        info=$(ffprobe -v error -select_streams v -show_entries stream=codec_name,profile,pix_fmt,color_range,color_space,level -of compact=p=0 "$f")
        local count keys
        count=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$f")
        keys=$(ffprobe -v error -select_streams v -show_entries frame=key_frame -of csv=p=0 "$f" | grep -c '^1' || true)
        local errs
        errs=$(ffmpeg -v error -i "$f" -f null - 2>&1 | wc -l | tr -d ' ')
        local idr_errs idr_count
        idr_errs=$(ffmpeg -v error -i "$out/$name-s$s-from-idr.$ext" -f null - 2>&1 | wc -l | tr -d ' ')
        idr_count=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$out/$name-s$s-from-idr.$ext" || echo 0)
        say "  ffprobe s$s: $info, frames $count/$frames, keyframes $keys, decode errors $errs; from mid-stream IDR: $idr_count frames, errors $idr_errs"
        [ "$count" = "$frames" ] && [ "$errs" = 0 ] && [ "$idr_errs" = 0 ] && [ "$idr_count" = $((frames - 120)) ] || fail=1
        for k in 1 150 299; do
            [ "$k" -lt "$frames" ] || continue
            local yuv="$out/$name-s$s-f$k.yuv"
            ffmpeg -v error -y -i "$f" -vf "select=eq(n\\,$k)" -frames:v 1 -f rawvideo "$yuv"
            say "  $("$bin" psnr --width "$w" --height "$h" $tb --stream "$s" --frame "$k" --yuv "$yuv")"
            rm -f "$yuv"
        done
        ffmpeg -v error -y -i "$f" -vf "select=eq(n\\,150)" -frames:v 1 "$out/$name-s$s-f150.png" || true
    done
}

# run <name> <ten_bit> <streams> <frames> <check 0|1> -- mvt_test options
run() {
    local name=$1 ten=$2 streams=$3 frames=$4 do_check=$5
    shift 6
    local w h ext=hevc
    w=$(echo "$@" | sed -E 's/.*--width ([0-9]+).*/\1/')
    h=$(echo "$@" | sed -E 's/.*--height ([0-9]+).*/\1/')
    [[ "$*" == *--h264* ]] && ext=h264
    say ""
    say "== $name"
    if ! "$bin" encode --streams "$streams" --frames "$frames" --out "$out/$name" "$@" | tee -a "$log"; then
        say "  mvt_test reported failures"
        fail=1
    fi
    [ "$do_check" = 1 ] && check "$name" "$w" "$h" "$ten" "$streams" "$frames" "$ext"
    return 0
}

if [ "${1:-}" = quick ]; then
    run quick 0 1 200 1 -- --width 1832 --height 1920 --mbps 50
else
    run eye2x-1832 0 2 300 1 -- --width 1832 --height 1920 --mbps 50
    run eye2x-1832-seq 0 2 300 0 -- --width 1832 --height 1920 --mbps 50 --sequential
    run eye2x-1832-10bit 1 2 300 1 -- --width 1832 --height 1920 --mbps 50 --ten-bit
    run eye2x-1832-copy 0 2 300 0 -- --width 1832 --height 1920 --mbps 50 --mode copy
    run eye2x-1832-async 0 2 300 0 -- --width 1832 --height 1920 --mbps 50 --mode async
    run eye2x-1832-4slices 0 2 300 0 -- --width 1832 --height 1920 --mbps 50 --slices 4
    run wide-3664 0 1 300 1 -- --width 3664 --height 1920 --mbps 100
    run wivrn-q3-default 1 2 300 1 -- --width 1280 --height 1344 --mbps 25 --ten-bit
    run wivrn-q3-default-seq 1 2 300 0 -- --width 1280 --height 1344 --mbps 25 --ten-bit --sequential
    run wivrn-q3-full 1 2 300 1 -- --width 2496 --height 2688 --mbps 100 --ten-bit
    run eye2x-1832-h264 0 2 300 1 -- --width 1832 --height 1920 --mbps 50 --h264
    run rate-immediate 0 1 360 0 -- --width 1832 --height 1920 --mbps 40 --rate2 15 --idr-at 999
    run rate-smooth 0 1 360 0 -- --width 1832 --height 1920 --mbps 40 --rate2 60 --smooth --idr-at 999
fi
say ""
say "overall: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
