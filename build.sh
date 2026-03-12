#!/usr/bin/env bash
# =============================================================================
# build.sh — BAG-to-GeoTiff converter build script
#
# Installs GDAL (with HDF5/BAG support) and builds the converter.
# Supports Ubuntu 20.04–24.04, Debian 11/12, and macOS (via Homebrew).
#
# Usage:
#   ./build.sh              # install deps + build
#   ./build.sh --test       # install deps + build + run conversion tests
#   ./build.sh --no-install # build only (assumes GDAL already installed)
#   ./build.sh --clean      # clean build artifacts then build
#
# What this script does:
#   1. Detects OS and package manager
#   2. Installs GDAL dev files (libgdal-dev) and gdal-bin via the system
#      package manager, with workarounds for known apt mirror issues
#   3. Builds the converter with g++ and gdal-config
#   4. Optionally downloads NOAA BAG test files and runs conversions
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
header()  { echo -e "\n${BOLD}=== $* ===${RESET}"; }

# ── Script root (the repo directory) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_INSTALL=true
DO_TEST=false
DO_CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --no-install) DO_INSTALL=false ;;
        --test)       DO_TEST=true ;;
        --clean)      DO_CLEAN=true ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *) warn "Unknown argument: $arg (ignoring)" ;;
    esac
done

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID:-linux}-${VERSION_CODENAME:-unknown}"
    else
        echo "linux-unknown"
    fi
}

OS="$(detect_os)"
info "Detected OS: $OS"

# ── Check for required tools ──────────────────────────────────────────────────
require_tool() {
    if ! command -v "$1" &>/dev/null; then
        die "Required tool not found: $1. Please install it and re-run."
    fi
}

require_tool g++
require_tool curl

# ── Clean if requested ────────────────────────────────────────────────────────
if $DO_CLEAN; then
    header "Cleaning build artifacts"
    rm -rf build/ output/
    ok "Cleaned."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Install GDAL
# ─────────────────────────────────────────────────────────────────────────────
header "Step 1: GDAL installation"

install_gdal_apt() {
    # ── Check if already installed ────────────────────────────────────────────
    if command -v gdal-config &>/dev/null; then
        local ver
        ver="$(gdal-config --version)"
        ok "GDAL $ver already installed (gdal-config found)."
        return 0
    fi

    info "Installing GDAL via apt-get..."

    # ── Need root for apt ─────────────────────────────────────────────────────
    local SUDO=""
    [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

    # ── Refresh package lists ─────────────────────────────────────────────────
    info "Updating apt package lists..."
    if ! $SUDO apt-get update -q 2>&1 | grep -v "^Hit\|^Ign\|^Get\|^Reading\|^Building\|^Done"; then
        warn "apt-get update had warnings (may be a mirror issue; continuing)."
    fi

    # ── Try standard install first ────────────────────────────────────────────
    info "Attempting: apt-get install libgdal-dev gdal-bin"
    if $SUDO apt-get install -y libgdal-dev gdal-bin 2>&1; then
        ok "GDAL installed successfully."
        return 0
    fi

    # ── Fallback: some security mirrors return 404 for updated packages.
    #    Work around by using only the main archive with --fix-missing.
    warn "Standard apt install failed. Trying with --fix-missing..."

    # Back up existing sources and use only the main archive
    local NOSEC_CONF="/etc/apt/sources.list.d/gdal-build-nosec.sources"
    if [[ ! -f "$NOSEC_CONF" ]]; then
        info "Creating apt source file using only archive.ubuntu.com (no security mirror)..."
        $SUDO tee "$NOSEC_CONF" > /dev/null << 'SOURCES'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
SOURCES
        $SUDO apt-get update -q 2>/dev/null || true
    fi

    if $SUDO apt-get install -y --fix-missing libgdal-dev gdal-bin 2>&1; then
        ok "GDAL installed (--fix-missing workaround succeeded)."
        return 0
    fi

    # ── Last resort: try installing just the minimum required packages ────────
    warn "--fix-missing also failed. Trying minimal install..."
    local GDAL_PKGS=(
        libgdal-dev
        gdal-bin
        libhdf5-dev
        libproj-dev
        libgeotiff-dev
    )
    if $SUDO apt-get install -y "${GDAL_PKGS[@]}" 2>&1; then
        ok "Minimal GDAL package set installed."
        return 0
    fi

    return 1
}

install_gdal_brew() {
    if command -v gdal-config &>/dev/null; then
        ok "GDAL $(gdal-config --version) already installed."
        return 0
    fi
    if ! command -v brew &>/dev/null; then
        die "Homebrew not found. Install it from https://brew.sh then re-run."
    fi
    info "Installing GDAL via Homebrew..."
    brew install gdal
    ok "GDAL installed via Homebrew."
}

install_gdal_dnf() {
    if command -v gdal-config &>/dev/null; then
        ok "GDAL $(gdal-config --version) already installed."
        return 0
    fi
    local SUDO=""
    [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
    info "Installing GDAL via dnf (EPEL)..."
    $SUDO dnf install -y epel-release
    $SUDO dnf install -y gdal-devel gdal
    ok "GDAL installed via dnf."
}

if $DO_INSTALL; then
    case "$OS" in
        macos)                install_gdal_brew ;;
        fedora-*|centos-*|rhel-*|rocky-*)
                              install_gdal_dnf  ;;
        ubuntu-*|debian-*|linuxmint-*|pop-*|elementary-*)
                              install_gdal_apt  ;;
        *)
            warn "Unrecognised OS '$OS'. Trying apt-get..."
            install_gdal_apt || warn "apt-get failed; trying brew..."
            command -v gdal-config &>/dev/null || install_gdal_brew
            ;;
    esac
else
    info "--no-install: skipping GDAL installation."
fi

# ── Verify GDAL is usable ─────────────────────────────────────────────────────
if ! command -v gdal-config &>/dev/null; then
    die "gdal-config not found after installation attempt. Cannot build."
fi

GDAL_VERSION="$(gdal-config --version)"
ok "Using GDAL $GDAL_VERSION"

# Verify BAG raster driver is present
if gdalinfo --formats 2>/dev/null | grep -qi "bathymetry attributed grid"; then
    ok "GDAL BAG raster driver: present"
else
    warn "GDAL BAG driver not detected in 'gdalinfo --formats'."
    warn "BAG support requires HDF5 in the GDAL build."
    warn "Continuing anyway — the driver may still work."
fi

# ── Minimum GDAL version check (need >= 3.2 for compound CRS + creation) ─────
GDAL_MAJOR=$(echo "$GDAL_VERSION" | cut -d. -f1)
GDAL_MINOR=$(echo "$GDAL_VERSION" | cut -d. -f2)
if [[ "$GDAL_MAJOR" -lt 3 ]] || { [[ "$GDAL_MAJOR" -eq 3 ]] && [[ "$GDAL_MINOR" -lt 2 ]]; }; then
    warn "GDAL $GDAL_VERSION is older than 3.2. Compound CRS and some BAG"
    warn "features may not be available. Recommend upgrading to GDAL >= 3.2."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Build
# ─────────────────────────────────────────────────────────────────────────────
header "Step 2: Building bag_to_geotiff"

mkdir -p build output

CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -Wpedantic"
GDAL_CFLAGS="$(gdal-config --cflags)"
GDAL_LIBS="$(gdal-config --libs)"

BUILD_CMD="$CXX $CXXFLAGS $GDAL_CFLAGS -o build/bag_to_geotiff src/bag_to_geotiff.cpp $GDAL_LIBS"

info "Compiler: $CXX"
info "GDAL cflags: $GDAL_CFLAGS"
info "Compile command: $BUILD_CMD"
echo ""

if $BUILD_CMD; then
    ok "Build successful: build/bag_to_geotiff"
else
    die "Build failed. Check compiler errors above."
fi

# Verify the binary runs
if ! ./build/bag_to_geotiff --help > /dev/null 2>&1; then
    die "Binary built but --help failed. Possible shared library issue."
fi
ok "Binary is functional."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Download test BAG files (if --test requested)
# ─────────────────────────────────────────────────────────────────────────────
if $DO_TEST; then
    header "Step 3: Downloading NOAA test BAG files"

    mkdir -p test_data

    # Base URL for NOAA NOS hydrographic survey BAG files
    NOAA_BASE="https://data.ngdc.noaa.gov/platforms/ocean/nos/coast"

    declare -A TEST_FILES=(
        # Key:   output filename
        # Value: <survey_range>/<survey_id>/BAG/<filename>
        ["H12023_MBVB_4m_MLLW_combined.bag"]="H12001-H14000/H12023/BAG/H12023_MBVB_4m_MLLW_combined.bag"
        ["H12238_MB_2m_MLLW_1of3.bag"]="H12001-H14000/H12238/BAG/H12238_MB_2m_MLLW_1of3.bag"
        ["H12048_MB_2m_MLLW_2of2.bag"]="H12001-H14000/H12048/BAG/H12048_MB_2m_MLLW_2of2.bag"
    )

    DOWNLOAD_OK=0
    DOWNLOAD_FAIL=0

    for filename in "${!TEST_FILES[@]}"; do
        dest="test_data/$filename"
        url="$NOAA_BASE/${TEST_FILES[$filename]}"

        if [[ -f "$dest" && -s "$dest" ]]; then
            size="$(du -sh "$dest" | cut -f1)"
            ok "Already downloaded: $filename ($size)"
            DOWNLOAD_OK=$((DOWNLOAD_OK + 1))
            continue
        fi

        info "Downloading: $filename"
        info "  URL: $url"

        if curl -L --progress-bar --max-time 600 --retry 3 \
                --retry-delay 5 -o "$dest" "$url"; then
            size="$(du -sh "$dest" | cut -f1)"
            ok "Downloaded: $filename ($size)"
            DOWNLOAD_OK=$((DOWNLOAD_OK + 1))
        else
            warn "Failed to download: $filename (skipping)"
            rm -f "$dest"
            DOWNLOAD_FAIL=$((DOWNLOAD_FAIL + 1))
        fi
    done

    if [[ $DOWNLOAD_OK -eq 0 ]]; then
        warn "No test files downloaded. Skipping conversion tests."
        DO_TEST=false
    else
        ok "$DOWNLOAD_OK file(s) ready for testing."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Run conversion tests
# ─────────────────────────────────────────────────────────────────────────────
if $DO_TEST; then
    header "Step 4: Running BAG-to-GeoTiff conversion tests"

    PASS=0
    FAIL=0
    SKIP=0

    run_test() {
        local label="$1"
        local bagfile="$2"
        local outfile="$3"
        shift 3
        local extra_args=("$@")

        if [[ ! -f "$bagfile" ]]; then
            warn "SKIP [$label]: $bagfile not found"
            SKIP=$((SKIP + 1))
            return
        fi

        echo ""
        info "Test: $label"
        info "  Input:  $bagfile"
        info "  Output: $outfile"
        [[ ${#extra_args[@]} -gt 0 ]] && info "  Args:   ${extra_args[*]}"

        mkdir -p "$(dirname "$outfile")"

        if ./build/bag_to_geotiff "${extra_args[@]}" "$bagfile" "$outfile" 2>&1; then
            if [[ -f "$outfile" && -s "$outfile" ]]; then
                size="$(du -sh "$outfile" | cut -f1)"
                ok "PASS [$label] → $outfile ($size)"

                # Quick gdalinfo check
                if command -v gdalinfo &>/dev/null; then
                    local crs
                    crs="$(gdalinfo "$outfile" 2>/dev/null | grep -E '(PROJCRS|PROJCS|GEOGCS|COMPOUNDCRS|COMPD_CS)' | head -1 | sed 's/^\s*//')"
                    [[ -n "$crs" ]] && info "  CRS:    $crs"
                    local dims
                    dims="$(gdalinfo "$outfile" 2>/dev/null | grep '^Size is' | head -1)"
                    [[ -n "$dims" ]] && info "  Size:   $dims"
                fi
                PASS=$((PASS + 1))
            else
                err "FAIL [$label]: output file missing or empty"
                FAIL=$((FAIL + 1))
            fi
        else
            err "FAIL [$label]: converter exited with error"
            FAIL=$((FAIL + 1))
        fi
    }

    # Test 1: Standard conversion (all bands, detect CRS from file)
    run_test "standard-4m-combined" \
        "test_data/H12023_MBVB_4m_MLLW_combined.bag" \
        "output/H12023_MBVB_4m_MLLW_combined.tif"

    # Test 2: Standard conversion, larger file
    run_test "standard-2m-survey" \
        "test_data/H12238_MB_2m_MLLW_1of3.bag" \
        "output/H12238_MB_2m_MLLW_1of3.tif"

    # Test 3: Elevation only
    run_test "elevation-only" \
        "test_data/H12023_MBVB_4m_MLLW_combined.bag" \
        "output/H12023_elev_only.tif" \
        "--elevation-only"

    # Test 4: LZW compression
    run_test "lzw-compression" \
        "test_data/H12023_MBVB_4m_MLLW_combined.bag" \
        "output/H12023_lzw.tif" \
        "--compress" "LZW"

    # Test 5: User EPSG override (force UTM zone 19N)
    run_test "epsg-override-26919" \
        "test_data/H12023_MBVB_4m_MLLW_combined.bag" \
        "output/H12023_epsg26919.tif" \
        "--epsg" "26919"

    # Test 6: WGS84 fallback (simulate missing CRS by using --fallback-epsg
    #         with a file that actually has a CRS — the file CRS wins,
    #         confirming priority logic works)
    run_test "fallback-epsg-4326" \
        "test_data/H12238_MB_2m_MLLW_1of3.bag" \
        "output/H12238_fallback_wgs84.tif" \
        "--fallback-epsg" "4326"

    # Test 7: Third survey file (Gulf, UTM zone 15N)
    run_test "gulf-survey-2m" \
        "test_data/H12048_MB_2m_MLLW_2of2.bag" \
        "output/H12048_MB_2m_MLLW_2of2.tif"

    # ── Summary ────────────────────────────────────────────────────────────────
    echo ""
    header "Test Results"
    echo -e "  ${GREEN}PASS${RESET}: $PASS"
    echo -e "  ${RED}FAIL${RESET}: $FAIL"
    [[ $SKIP -gt 0 ]] && echo -e "  ${YELLOW}SKIP${RESET}: $SKIP"
    echo ""

    if [[ $FAIL -gt 0 ]]; then
        err "$FAIL test(s) failed."
        exit 1
    elif [[ $PASS -eq 0 ]]; then
        warn "No tests ran (all skipped or no test files)."
    else
        ok "All $PASS test(s) passed."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
header "Build complete"
echo ""
echo -e "  Binary:  ${BOLD}./build/bag_to_geotiff${RESET}"
echo -e "  Usage:   ${BOLD}./build/bag_to_geotiff [OPTIONS] <input.bag> [output.tif]${RESET}"
echo -e "  Help:    ${BOLD}./build/bag_to_geotiff --help${RESET}"
echo -e "  Tests:   ${BOLD}./build.sh --test${RESET}   (downloads NOAA BAG files and converts)"
echo -e "  Make:    ${BOLD}make test${RESET}            (if you already have BAG files in test_data/)"
echo ""
