#!/bin/bash
# Builds the README's hero from the MarketingAssetsTests renders: the video
# editor playing the demo. Run it after the editor's look changes:
#
#   SHOTNIX_MARKETING_DIR=/tmp/shotnix-marketing swift test --filter MarketingAssetsTests
#   scripts/readme-hero.sh /tmp/shotnix-marketing
#
# It writes assets/readme/hero.avif (the animation in the README) and
# <marketing-dir>/shotnix-editor-playback.mp4, the full-quality version the
# hero links to: copy that to shotnix-web/public/media/. If the editor's
# layout moved, update the geometry in scripts/readme-hero.swift from
# `scripts/website-editor-demo.py <marketing-dir>`. Needs ffmpeg with
# libsvtav1 and libx264. AVIF because it's a real video codec: gradients stay
# smooth at a fraction of an animated WebP's size, and macOS decodes it natively.
set -euo pipefail

MARKETING_DIR="${1:?usage: scripts/readme-hero.sh <marketing-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O "$SCRIPT_DIR/readme-hero.swift" -o "$WORK/readme-hero"

# frames <width> <fps>: the editor at that size, one PNG per frame, in $WORK/frames.
frames() {
    rm -rf "$WORK/demo" "$WORK/frames"
    mkdir -p "$WORK/demo" "$WORK/frames"
    ffmpeg -v error -i "$MARKETING_DIR/shotnix-editor-demo.mp4" \
        -vf "fps=$2,scale=$((912 * $1 / 1512)):$((513 * $1 / 1512)):flags=lanczos" "$WORK/demo/v%04d.png"
    "$WORK/readme-hero" "$MARKETING_DIR/shotnix-editor-frame.png" "$WORK/demo" "$WORK/frames" "$1" "$2"
}

# Both from the window at 2× (3024 × 1888), 60 fps: sharp on Retina.
frames 3024 60

# The README animation. Video range (every decoder honors it) and sRGB
# tags, so tones match the render.
HERO="$SCRIPT_DIR/../assets/readme/hero.avif"
ffmpeg -v error -y -framerate 60 -i "$WORK/frames/h%04d.png" \
    -vf "scale=out_color_matrix=bt709:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p" \
    -c:v libsvtav1 -preset 4 -crf 22 -g 120 -svtav1-params tune=0 \
    -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc iec61966-2-1 \
    -f avif "$HERO"
echo "✓ $HERO ($(($(stat -f %z "$HERO") / 1024)) KB)"

# The full-quality video, tagged like the site's other videos.
PLAYBACK="$MARKETING_DIR/shotnix-editor-playback.mp4"
ffmpeg -v error -y -framerate 60 -i "$WORK/frames/h%04d.png" \
    -vf "scale=out_color_matrix=bt709:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p" \
    -c:v libx264 -preset slow -crf 18 -profile:v high -level 5.2 \
    -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags +faststart "$PLAYBACK"
echo "✓ $PLAYBACK ($(($(stat -f %z "$PLAYBACK") / 1024)) KB): copy it to shotnix-web/public/media/"
