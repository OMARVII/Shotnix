#!/bin/bash
# Builds the README's hero from the MarketingAssetsTests renders: the video
# editor playing the demo. Run it after the editor's look changes:
#
#   SHOTNIX_MARKETING_DIR=/tmp/shotnix-marketing swift test --filter MarketingAssetsTests
#   scripts/readme-hero.sh /tmp/shotnix-marketing
#
# It writes assets/readme/hero.webp, one frame of the editor mid-demo, and
# <marketing-dir>/shotnix-editor-playback.mp4, the video the hero links to:
# copy that to shotnix-web/public/media/. If the editor's layout moved, update
# the geometry in scripts/readme-hero.swift from
# `scripts/website-editor-demo.py <marketing-dir>`. Needs ffmpeg with libx264,
# and cwebp.
#
# A still, not an animation: GitHub plays animated images through the
# browser's image decoder, which can't keep up with the editor at Retina size
# and 60 fps, and the hero stuttered. The video plays in the browser's player.
set -euo pipefail

MARKETING_DIR="${1:?usage: scripts/readme-hero.sh <marketing-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O "$SCRIPT_DIR/readme-hero.swift" -o "$WORK/readme-hero"

# The window at 2× (3024 × 1888), 60 fps, one PNG per frame.
mkdir -p "$WORK/demo" "$WORK/frames"
ffmpeg -v error -i "$MARKETING_DIR/shotnix-editor-demo.mp4" \
    -vf "fps=60,scale=1824:1026:flags=lanczos" "$WORK/demo/v%04d.png"
"$WORK/readme-hero" "$MARKETING_DIR/shotnix-editor-frame.png" "$WORK/demo" "$WORK/frames" 3024 60

# The hero: 0:05.0, zoomed in on the click, with the caption lit and the
# playhead inside the zoom and the caption on the timeline. Lossless, so it's
# the render pixel for pixel.
HERO="$SCRIPT_DIR/../assets/readme/hero.webp"
cwebp -quiet -lossless -z 9 -metadata icc "$WORK/frames/h0301.png" -o "$HERO"
echo "✓ $HERO ($(($(stat -f %z "$HERO") / 1024)) KB)"

# The video, tagged like the site's other videos.
PLAYBACK="$MARKETING_DIR/shotnix-editor-playback.mp4"
ffmpeg -v error -y -framerate 60 -i "$WORK/frames/h%04d.png" \
    -vf "scale=out_color_matrix=bt709:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p" \
    -c:v libx264 -preset slow -crf 18 -profile:v high -level 5.2 \
    -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags +faststart "$PLAYBACK"
echo "✓ $PLAYBACK ($(($(stat -f %z "$PLAYBACK") / 1024)) KB): copy it to shotnix-web/public/media/"
