#!/usr/bin/env bash
set -euo pipefail

# Helpers for recording the README demo.
#
#   ./scripts/demo.sh stage                 hide desktop icons, restart Floe with a clean layout
#   ./scripts/demo.sh unstage               show desktop icons again
#   ./scripts/demo.sh convert <recording>   turn a screen recording into demo.mp4 and demo.gif
#
# convert options:
#   --from <sec>    start of the clip (default: 0)
#   --to <sec>      end of the clip (default: end of the recording)
#   --width <px>    output width (default: 1280)
#   --fps <n>       GIF frame rate (default: 20)
#   --out <dir>     output directory (default: dist/demo)

FLOE_APP="${FLOE_APP:-/Applications/Floe.app}"

stage() {
    echo "==> Hiding desktop icons..."
    defaults write com.apple.finder CreateDesktop -bool false
    killall Finder

    echo "==> Restarting Floe (drops remembered split ratios)..."
    pkill -x Floe || true
    sleep 1
    open "$FLOE_APP"

    echo "==> Ready. Run './scripts/demo.sh unstage' when you're done."
}

unstage() {
    echo "==> Showing desktop icons again..."
    defaults delete com.apple.finder CreateDesktop 2>/dev/null || true
    killall Finder
}

convert() {
    local input="" from="0" to="" width="1280" fps="20" out="dist/demo"

    while [ $# -gt 0 ]; do
        case "$1" in
            --from)  from="$2"; shift 2 ;;
            --to)    to="$2"; shift 2 ;;
            --width) width="$2"; shift 2 ;;
            --fps)   fps="$2"; shift 2 ;;
            --out)   out="$2"; shift 2 ;;
            *)       input="$1"; shift ;;
        esac
    done

    if [ -z "$input" ] || [ ! -f "$input" ]; then
        echo "Usage: $0 convert <recording.mov> [--from sec] [--to sec] [--width px] [--fps n] [--out dir]" >&2
        exit 1
    fi
    command -v ffmpeg >/dev/null || { echo "ffmpeg is missing: brew install ffmpeg" >&2; exit 1; }

    mkdir -p "$out"
    local trim=(-ss "$from")
    [ -n "$to" ] && trim+=(-to "$to")

    echo "==> Writing $out/demo.mp4..."
    ffmpeg -y -loglevel error "${trim[@]}" -i "$input" \
        -vf "scale=${width}:-2:flags=lanczos" \
        -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -movflags +faststart -an \
        "$out/demo.mp4"

    echo "==> Writing $out/demo.gif..."
    if command -v gifski >/dev/null; then
        local frames
        frames="$(mktemp -d)"
        ffmpeg -y -loglevel error -i "$out/demo.mp4" -vf "fps=${fps}" "$frames/frame%05d.png"
        gifski --quiet --fps "$fps" --width "$width" --quality 90 -o "$out/demo.gif" "$frames"/frame*.png
        rm -rf "$frames"
    else
        echo "    (brew install gifski gives sharper, smaller GIFs — falling back to ffmpeg)"
        ffmpeg -y -loglevel error -i "$out/demo.mp4" \
            -vf "fps=${fps},split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
            "$out/demo.gif"
    fi

    echo "==> Done:"
    ls -lh "$out"/demo.mp4 "$out"/demo.gif | awk '{print "    " $5 "  " $9}'
}

case "${1:-}" in
    stage)   stage ;;
    unstage) unstage ;;
    convert) shift; convert "$@" ;;
    *)
        sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
