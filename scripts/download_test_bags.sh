#!/usr/bin/env bash
# download_test_bags.sh
#
# Downloads a representative set of NOAA NOS BAG files for testing.
# Files are from different surveys with various coordinate systems.
#
# NOAA NOS BAG archive structure:
#   https://data.ngdc.noaa.gov/platforms/ocean/nos/coast/<RANGE>/<SURVEY_ID>/BAG/<file>.bag

set -euo pipefail

DEST="${1:-test_data}"
mkdir -p "$DEST"

BASE="https://data.ngdc.noaa.gov/platforms/ocean/nos/coast"

# ── Test files: different surveys, different resolutions ──────────────────────
#
# H12238 – NAD83 / UTM Zone 19N, multi-beam, 2m resolution, Gulf of Maine area
# H12023 – NAD83 / UTM Zone 19N, combined multi-beam+vertical beam, 4m resolution
# H12048 – NAD83 / UTM Zone 19N, multi-beam, 2m resolution
#
# All three use NAD83/UTM but test different resolutions and survey types.

declare -A FILES=(
    ["H12238_MB_2m_MLLW_1of3.bag"]="H12001-H14000/H12238/BAG"
    ["H12023_MBVB_4m_MLLW_combined.bag"]="H12001-H14000/H12023/BAG"
    ["H12048_MB_2m_MLLW_2of2.bag"]="H12001-H14000/H12048/BAG"
)

echo "Downloading NOAA BAG test files to: $DEST"
echo ""

SUCCESS=0
FAILED=0

for filename in "${!FILES[@]}"; do
    range_survey="${FILES[$filename]}"
    url="$BASE/$range_survey/$filename"
    dest_file="$DEST/$filename"

    if [ -f "$dest_file" ]; then
        echo "[SKIP] Already exists: $filename"
        SUCCESS=$((SUCCESS + 1))
        continue
    fi

    echo "Downloading: $filename"
    echo "  URL: $url"

    if curl -L --progress-bar --max-time 300 --retry 3 \
            -o "$dest_file" "$url"; then
        size=$(du -sh "$dest_file" | cut -f1)
        echo "  [OK] $size saved to $dest_file"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  [FAIL] Could not download $filename"
        rm -f "$dest_file"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "=== Download complete: $SUCCESS succeeded, $FAILED failed ==="
echo ""
echo "Available test files:"
ls -lh "$DEST"/*.bag 2>/dev/null || echo "  (none)"
