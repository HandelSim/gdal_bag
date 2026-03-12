# Makefile for bag_to_geotiff
# Requires: GDAL development files (libgdal-dev)
#
# Usage:
#   make              Build the converter
#   make test         Build and run conversion tests on downloaded BAG files
#   make clean        Remove build artifacts
#   make info         Show GDAL configuration

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -Wpedantic
CXXFLAGS += $(shell gdal-config --cflags)
LDFLAGS  := $(shell gdal-config --libs)

SRC_DIR  := src
BUILD_DIR := build
TEST_DIR  := test_data
OUTPUT_DIR := output

TARGET   := $(BUILD_DIR)/bag_to_geotiff
SOURCES  := $(SRC_DIR)/bag_to_geotiff.cpp

.PHONY: all clean test info dirs

all: dirs $(TARGET)

dirs:
	@mkdir -p $(BUILD_DIR) $(OUTPUT_DIR)

$(TARGET): $(SOURCES)
	@echo "Building bag_to_geotiff..."
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Build successful: $@"

# ── Test targets ──────────────────────────────────────────────────────────────

test: all
	@echo ""
	@echo "=== Running BAG to GeoTiff conversion tests ==="
	@echo ""
	@failed=0; total=0; \
	for bagfile in $(TEST_DIR)/*.bag; do \
		[ -f "$$bagfile" ] || continue; \
		total=$$((total + 1)); \
		basename=$$(basename "$$bagfile" .bag); \
		outfile="$(OUTPUT_DIR)/$${basename}.tif"; \
		echo "--- Converting: $$bagfile"; \
		if $(TARGET) --all-bands "$$bagfile" "$$outfile"; then \
			echo "    [PASS] Output: $$outfile"; \
			if command -v gdalinfo >/dev/null 2>&1; then \
				echo "    GeoTiff info:"; \
				gdalinfo "$$outfile" | grep -E '(Driver|Size|Coordinate System|Origin|Pixel Size|Band|NoData|PROJCS|GEOGCS|WGS|NAD|UTM)' | sed 's/^/      /'; \
			fi; \
		else \
			echo "    [FAIL] Conversion failed for $$bagfile"; \
			failed=$$((failed + 1)); \
		fi; \
		echo ""; \
	done; \
	echo "=== Results: $$((total - failed))/$$total passed ==="; \
	[ $$failed -eq 0 ]

# Test with explicit fallback CRS (for files that lack CRS info)
test-no-crs: all
	@echo "=== Testing fallback CRS handling ==="
	@for bagfile in $(TEST_DIR)/*.bag; do \
		[ -f "$$bagfile" ] || continue; \
		basename=$$(basename "$$bagfile" .bag); \
		outfile="$(OUTPUT_DIR)/$${basename}_wgs84_fallback.tif"; \
		echo "Converting (WGS84 fallback): $$bagfile -> $$outfile"; \
		$(TARGET) --fallback-epsg 4326 "$$bagfile" "$$outfile"; \
	done

# Test with EPSG override
test-epsg-override: all
	@echo "=== Testing EPSG override ==="
	@for bagfile in $(TEST_DIR)/*.bag; do \
		[ -f "$$bagfile" ] || continue; \
		basename=$$(basename "$$bagfile" .bag); \
		outfile="$(OUTPUT_DIR)/$${basename}_epsg_override.tif"; \
		echo "Converting (EPSG:32619 override): $$bagfile -> $$outfile"; \
		$(TARGET) --epsg 32619 "$$bagfile" "$$outfile"; \
	done

# Test elevation-only output
test-elevation-only: all
	@echo "=== Testing elevation-only mode ==="
	@for bagfile in $(TEST_DIR)/*.bag; do \
		[ -f "$$bagfile" ] || continue; \
		basename=$$(basename "$$bagfile" .bag); \
		outfile="$(OUTPUT_DIR)/$${basename}_elev_only.tif"; \
		echo "Converting (elevation only): $$bagfile -> $$outfile"; \
		$(TARGET) --elevation-only "$$bagfile" "$$outfile"; \
	done

# Show GDAL info for all converted GeoTiffs
inspect:
	@echo "=== GeoTiff inspection ==="
	@for tiffile in $(OUTPUT_DIR)/*.tif; do \
		[ -f "$$tiffile" ] || continue; \
		echo ""; \
		echo "--- $$tiffile ---"; \
		gdalinfo "$$tiffile" 2>/dev/null | grep -E \
			'(Driver|Files|Size is|Coordinate System|PROJCS|GEOGCS|Origin|Pixel Size|Band|NoData|Metadata)' | \
			head -30; \
	done

info:
	@echo "GDAL version: $$(gdal-config --version)"
	@echo "GDAL cflags:  $$(gdal-config --cflags)"
	@echo "GDAL libs:    $$(gdal-config --libs)"
	@echo "GDAL BAG support: $$(gdalinfo --formats 2>/dev/null | grep -i 'bathymetry' || echo 'not found')"
	@echo "Compiler:     $(CXX)"
	@echo "CXXFLAGS:     $(CXXFLAGS)"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(BUILD_DIR) $(OUTPUT_DIR)
	@echo "Done."
