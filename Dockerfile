# =============================================================================
# Dockerfile — BAG-to-GeoTiff converter environment
#
# Uses locally pre-downloaded .deb packages (in packages/) so the build
# works without Docker container internet access.
#
# Pre-package the debs on the host before building:
#   ./dc.sh build            (handles this automatically)
#
# OR manually:
#   mkdir -p packages && cd packages
#   apt-get download libgdal-dev gdal-bin gdal-data gdal-plugins \
#     libgdal34t64 libhdf5-dev libhdf5-103-1t64 libhdf5-hl-100t64 \
#     libhdf5-cpp-103-1t64 hdf5-tools libproj-dev libproj25 proj-bin \
#     proj-data build-essential g++ gcc-13 g++-13 cpp-13 make \
#     libc6-dev linux-libc-dev libstdc++-13-dev curl less file \
#     vim-tiny bash-completion ca-certificates
#
# Build:  ./dc.sh build   OR   docker compose build
# Start:  ./dc.sh start   OR   docker compose up -d
# Bash:   ./dc.sh bash    OR   docker compose exec bag-converter bash
# =============================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    GDAL_PAM_ENABLED=NO

# ── Copy pre-downloaded .deb packages ────────────────────────────────────────
# This avoids needing internet access inside the Docker build network.
COPY packages/ /tmp/packages/

# ── Install packages from local .deb files ───────────────────────────────────
# We create a local apt repository from the bundled .deb files so that apt can
# resolve all inter-package dependencies without network access.
RUN echo "deb [trusted=yes] file:///tmp/packages ./" \
        > /etc/apt/sources.list.d/local-gdal.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libgdal-dev \
        gdal-bin \
        gdal-data \
        gdal-plugins \
        libhdf5-dev \
        libhdf5-103-1t64 \
        libhdf5-hl-100t64 \
        libhdf5-cpp-103-1t64 \
        hdf5-tools \
        libproj-dev \
        libproj25 \
        proj-bin \
        proj-data \
        build-essential \
        g++ \
        gcc-13 \
        g++-13 \
        cpp-13 \
        make \
        libc6-dev \
        linux-libc-dev \
        libstdc++-13-dev \
        curl \
        less \
        file \
        vim-tiny \
        bash-completion \
        ca-certificates \
        && \
    rm -rf /tmp/packages /var/lib/apt/lists/* \
           /etc/apt/sources.list.d/local-gdal.list

# ── Workspace layout ──────────────────────────────────────────────────────────
WORKDIR /workspace
RUN mkdir -p test_data output build

# ── Copy source + support files ───────────────────────────────────────────────
COPY src/     src/
COPY Makefile Makefile
COPY build.sh build.sh
COPY scripts/ scripts/
COPY docs/    docs/
RUN chmod +x build.sh scripts/*.sh 2>/dev/null || true

# ── Build the converter ───────────────────────────────────────────────────────
RUN gdal-config --version && \
    g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic \
        $(gdal-config --cflags) \
        -o build/bag_to_geotiff src/bag_to_geotiff.cpp \
        $(gdal-config --libs) && \
    echo "Build OK" && \
    ./build/bag_to_geotiff --help | head -1

# ── Verify BAG driver ─────────────────────────────────────────────────────────
RUN gdalinfo --formats | grep -i "Bathymetry Attributed Grid" && \
    echo "GDAL BAG driver: OK"

# ── Shell aliases and helpers ─────────────────────────────────────────────────
RUN cat >> /root/.bashrc << 'BASHRC'

export PATH="/workspace/build:$PATH"
export PS1='\[\033[1;34m\][bag-converter]\[\033[0m\] \w \$ '

# Convert a BAG file -> /workspace/output/<name>.tif
bag2tif() {
    local input="$1"; shift
    local base; base="$(basename "${input%.bag}")"
    local output="/workspace/output/${base}.tif"
    echo "Converting: $input  →  $output"
    bag_to_geotiff "$@" "$input" "$output"
}

# Convert every .bag in test_data/
bag2tif_all() {
    local count=0
    for f in /workspace/test_data/*.bag; do
        [ -f "$f" ] || continue
        bag2tif "$f" "$@"
        count=$((count + 1))
    done
    [ $count -eq 0 ] && echo "No .bag files found in /workspace/test_data/"
}

# Quick gdalinfo summary
baginfo() { gdalinfo "$1" 2>/dev/null | head -60; }

# Dump ISO 19115 XML metadata from a BAG
bagxml() {
    h5dump -b FILE -d /BAG_root/metadata "$1" 2>/dev/null | \
      sed -n '/DATA {/,/}/p' | sed '1d;$d' | \
      sed 's/^ *"//;s/"$//' | head -80
}

# HDF5 structure tree
bagh5() { h5ls -r "$1"; }

alias ll='ls -lh'
alias cdw='cd /workspace'
alias cddata='cd /workspace/test_data'
alias cdout='cd /workspace/output'

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║  bag-converter  •  GDAL $(gdal-config --version 2>/dev/null)                 ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  bag2tif <file.bag>    convert one BAG file      ║"
echo "  ║  bag2tif_all           convert all in test_data/ ║"
echo "  ║  baginfo  <file>       gdalinfo summary          ║"
echo "  ║  bagxml   <file.bag>   dump ISO XML metadata     ║"
echo "  ║  bagh5    <file.bag>   HDF5 structure tree       ║"
echo "  ║  Dirs:  test_data/  output/  (host bind-mounts)  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
BASHRC

# ── Keep the container alive ──────────────────────────────────────────────────
CMD ["sleep", "infinity"]
