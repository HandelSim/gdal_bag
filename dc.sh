#!/usr/bin/env bash
# =============================================================================
# dc.sh — Helper script for the bag-converter Docker container
#
# Usage:
#   ./dc.sh build          Build the Docker image
#   ./dc.sh start          Start the container (build if needed)
#   ./dc.sh stop           Stop the container
#   ./dc.sh restart        Restart the container
#   ./dc.sh bash           Open an interactive bash shell inside the container
#   ./dc.sh status         Show container status
#   ./dc.sh logs           Tail container logs
#   ./dc.sh rebuild        Force-rebuild the image and restart
#   ./dc.sh convert <file> Convert a BAG file using the container
#   ./dc.sh test           Download NOAA BAG files and run all conversion tests
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER="bag-converter"
COMPOSE="docker compose"

# ── Colour helpers ────────────────────────────────────────────────────────────
B='\033[1m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; X='\033[0m'
ok()   { echo -e "${G}[OK]${X}    $*"; }
info() { echo -e "${B}[..]${X}    $*"; }
warn() { echo -e "${Y}[!!]${X}    $*"; }
die()  { echo -e "${R}[ERR]${X}   $*" >&2; exit 1; }

# ── Ensure Docker is running ──────────────────────────────────────────────────
ensure_docker() {
    if ! docker info &>/dev/null; then
        warn "Docker daemon not running. Attempting to start..."
        if command -v systemctl &>/dev/null; then
            sudo systemctl start docker
        else
            sudo service docker start 2>/dev/null || \
              (dockerd &>/tmp/dockerd.log & sleep 3)
        fi
        docker info &>/dev/null || die "Could not connect to Docker daemon."
    fi
}

# ── Is the container running? ─────────────────────────────────────────────────
is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_build() {
    ensure_docker
    info "Building image..."
    $COMPOSE build
    ok "Image built: bag-converter:latest"
}

cmd_start() {
    ensure_docker
    if is_running; then
        ok "Container '$CONTAINER' is already running."
        return
    fi
    info "Starting container..."
    $COMPOSE up -d
    sleep 1
    if is_running; then
        ok "Container '$CONTAINER' is up."
        echo ""
        echo -e "  Bash in:  ${B}./dc.sh bash${X}"
        echo -e "  Stop:     ${B}./dc.sh stop${X}"
    else
        die "Container failed to start. Run: ./dc.sh logs"
    fi
}

cmd_stop() {
    ensure_docker
    info "Stopping container..."
    $COMPOSE stop
    ok "Container stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_rebuild() {
    ensure_docker
    info "Rebuilding image (no cache)..."
    $COMPOSE build --no-cache
    info "Restarting container..."
    $COMPOSE down 2>/dev/null || true
    $COMPOSE up -d
    ok "Container rebuilt and restarted."
}

cmd_bash() {
    ensure_docker
    if ! is_running; then
        warn "Container is not running. Starting it first..."
        cmd_start
    fi
    info "Opening bash shell in '$CONTAINER'..."
    echo -e "  Type ${B}exit${X} to leave the container (it keeps running in background)."
    echo ""
    docker exec -it "$CONTAINER" bash
}

cmd_status() {
    ensure_docker
    echo ""
    echo -e "${B}Container status:${X}"
    docker ps -a --filter "name=$CONTAINER" \
        --format "  Name: {{.Names}}\n  Image: {{.Image}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}" \
        2>/dev/null || echo "  (not found)"
    echo ""
    if is_running; then
        echo -e "${B}Disk usage (output/):${X}"
        du -sh output/ 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
        echo -e "${B}Test data:${X}"
        ls -lh test_data/*.bag 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}' || echo "  (no .bag files)"
    fi
    echo ""
}

cmd_logs() {
    ensure_docker
    $COMPOSE logs --tail=50 --follow
}

cmd_convert() {
    local input="$1"; shift || true
    [[ -z "$input" ]] && die "Usage: ./dc.sh convert <input.bag> [options]"
    [[ ! -f "$input" ]] && die "File not found: $input"

    ensure_docker
    if ! is_running; then
        warn "Container not running. Starting..."
        cmd_start
    fi

    # Resolve to absolute path
    local abs_input; abs_input="$(realpath "$input")"
    local basename; basename="$(basename "${abs_input%.bag}")"

    # If the file is already in test_data/, reference it inside the container.
    # Otherwise, copy it in first.
    if [[ "$abs_input" == "$SCRIPT_DIR/test_data/"* ]]; then
        local container_input="/workspace/test_data/$(basename "$abs_input")"
    else
        info "Copying '$input' into test_data/..."
        cp "$abs_input" "$SCRIPT_DIR/test_data/"
        local container_input="/workspace/test_data/$(basename "$abs_input")"
    fi

    local container_output="/workspace/output/${basename}.tif"

    info "Converting inside container:"
    info "  $container_input  →  $container_output"
    docker exec -it "$CONTAINER" \
        /workspace/build/bag_to_geotiff "$@" \
        "$container_input" "$container_output"

    if [[ -f "$SCRIPT_DIR/output/${basename}.tif" ]]; then
        local size; size="$(du -sh "$SCRIPT_DIR/output/${basename}.tif" | cut -f1)"
        ok "Output: output/${basename}.tif ($size)"
    fi
}

cmd_test() {
    ensure_docker
    if ! is_running; then
        warn "Container not running. Starting..."
        cmd_start
    fi
    info "Running test suite inside container (downloads NOAA BAG files)..."
    docker exec -it "$CONTAINER" bash /workspace/build.sh --no-install --test
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
COMMAND="${1:-help}"; shift 2>/dev/null || true

case "$COMMAND" in
    build)   cmd_build   ;;
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    rebuild) cmd_rebuild ;;
    bash)    cmd_bash    ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    convert) cmd_convert "$@" ;;
    test)    cmd_test    ;;
    help|--help|-h)
        echo ""
        echo -e "${B}dc.sh — bag-converter Docker helper${X}"
        echo ""
        echo "  ./dc.sh build          Build the Docker image"
        echo "  ./dc.sh start          Start the container (in background)"
        echo "  ./dc.sh stop           Stop the container"
        echo "  ./dc.sh restart        Stop then start"
        echo "  ./dc.sh bash           Open a shell inside the container"
        echo "  ./dc.sh status         Show container and data status"
        echo "  ./dc.sh logs           Tail container logs"
        echo "  ./dc.sh rebuild        Force-rebuild image from scratch and restart"
        echo "  ./dc.sh convert f.bag  Convert a BAG file using the container"
        echo "  ./dc.sh test           Run conversion tests (downloads NOAA files)"
        echo ""
        echo "  Once inside (bash), these shortcuts are available:"
        echo "    bag2tif <file.bag>   Convert one BAG -> output/"
        echo "    bag2tif_all          Convert all BAGs in test_data/"
        echo "    baginfo <file>       gdalinfo summary"
        echo "    bagxml  <file.bag>   Dump ISO XML metadata"
        echo "    bagh5   <file.bag>   HDF5 structure tree"
        echo ""
        ;;
    *)
        die "Unknown command: $COMMAND. Run ./dc.sh help"
        ;;
esac
