/**
 * bag_to_geotiff.cpp
 *
 * Converts BAG (Bathymetric Attributed Grid) files of any version (1.0–2.0+)
 * to GeoTiff format, with robust spatial reference handling.
 *
 * Handles:
 *  - BAG v1.0–v2.0+ (HDF5-based, GDAL BAG driver)
 *  - Missing/empty CRS  → falls back to WGS84 geographic (EPSG:4326) with warning
 *  - Non-WKT CRS strings (bare EPSG codes) → resolved via OGRSpatialReference
 *  - Variable-resolution BAG 1.6.0+ files → flattened via RESAMPLED_GRID mode
 *  - Compound CRS (horizontal + vertical) → preserved in GeoTiff metadata
 *  - Elevation and uncertainty bands, plus any additional BAG layers
 *  - Nodata values propagated faithfully from GDAL (elevation: 1e6; uncertainty: 0.0 per
 *    spec, but GDAL's BAG driver normalises both to 1e6 at read time)
 *
 * Dependencies: GDAL >= 3.2 with HDF5/BAG support
 *
 * Build:
 *   g++ -std=c++17 -O2 -o bag_to_geotiff bag_to_geotiff.cpp \
 *       $(gdal-config --cflags) $(gdal-config --libs)
 *
 * Usage:
 *   bag_to_geotiff [OPTIONS] <input.bag> [output.tif]
 *
 * Options:
 *   --epsg <code>        Override/assign EPSG code as horizontal CRS
 *   --wkt <wkt_string>   Override/assign WKT string as horizontal CRS
 *   --fallback-epsg <N>  EPSG code to use when CRS is missing (default: 4326)
 *   --elevation-only     Export only the elevation band (Band 1)
 *   --all-bands          Export elevation + uncertainty + all optional bands
 *   --compress <method>  Compression: DEFLATE (default), LZW, NONE
 *   --vr-mode <mode>     Variable-res mode: RESAMPLED_GRID (default), LIST_SUPERGRIDS
 *   --help               Print this help message
 */

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <filesystem>
#include <stdexcept>
#include <cmath>
#include <algorithm>

#include "gdal_priv.h"
#include "cpl_conv.h"
#include "cpl_string.h"
#include "ogr_spatialref.h"

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

static const double BAG_NODATA       = 1.0e6;   ///< BAG sentinel for missing data
static const int    DEFAULT_FALLBACK_EPSG = 4326; ///< WGS84 geographic

// ─────────────────────────────────────────────────────────────────────────────
// Utility helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Print a GDAL error to stderr with context tag.
static void reportError(const std::string& context, CPLErr eErr,
                        const std::string& detail = "")
{
    std::string sev;
    switch (eErr) {
        case CE_Warning: sev = "WARNING"; break;
        case CE_Failure: sev = "ERROR";   break;
        case CE_Fatal:   sev = "FATAL";   break;
        default:         sev = "INFO";    break;
    }
    std::cerr << "[" << sev << "] " << context;
    if (!detail.empty()) std::cerr << ": " << detail;
    std::cerr << "\n";

    // Also emit any pending GDAL error messages
    const char* gdalMsg = CPLGetLastErrorMsg();
    if (gdalMsg && strlen(gdalMsg) > 0 && std::string(gdalMsg) != detail) {
        std::cerr << "  GDAL: " << gdalMsg << "\n";
    }
    CPLErrorReset();
}

/// Attempt to construct a valid OGRSpatialReference from a WKT or user-input
/// string (handles bare EPSG codes, PROJ strings, etc.).
static bool parseSRS(const std::string& input, OGRSpatialReference& srs)
{
    if (input.empty()) return false;

    // First, try direct WKT import (most common for BAG files)
    OGRErr err = srs.importFromWkt(input.c_str());
    if (err == OGRERR_NONE && !srs.IsEmpty()) return true;

    // Fall back to SetFromUserInput which handles EPSG:XXXX, PROJ strings, etc.
    srs.Clear();
    err = srs.SetFromUserInput(input.c_str());
    if (err == OGRERR_NONE && !srs.IsEmpty()) return true;

    return false;
}

/// Check if the WKT string represents a geographic (lat/lon) CRS.
static bool isGeographic(const OGRSpatialReference& srs)
{
    return srs.IsGeographic() != 0;
}

/// Check whether the geotransform corner coordinates are consistent with
/// the given CRS (basic sanity check).
static bool georefSanityCheck(const double gt[6], int xSize, int ySize,
                               const OGRSpatialReference& srs)
{
    // Compute the center coordinate
    double cx = gt[0] + gt[1] * xSize * 0.5;
    double cy = gt[3] + gt[5] * ySize * 0.5;

    if (isGeographic(srs)) {
        // For geographic CRS, coordinates must be in degrees
        return (cx >= -360.0 && cx <= 360.0 && cy >= -90.0 && cy <= 90.0);
    } else {
        // For projected CRS, expect large meter values (rough check)
        // Very small values near zero suggest a mis-matched CRS
        bool suspiciouslySmall = (std::abs(cx) < 1000.0 && std::abs(cy) < 1000.0);
        return !suspiciouslySmall;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BAG version detection
// ─────────────────────────────────────────────────────────────────────────────

/// Try to read the BAG version attribute from a GDAL metadata domain.
/// Returns version string or "unknown".
static std::string detectBagVersion(GDALDataset* ds)
{
    if (!ds) return "unknown";

    // The BAG driver may expose this through the xml:BAG metadata domain
    const char* bagXml = ds->GetMetadataItem("", "xml:BAG");
    if (!bagXml) bagXml = ds->GetMetadataItem("xml:BAG", "");

    if (bagXml) {
        // Look for the version string in the XML
        // BAG 1.5+ uses: <smXML:version>1.6.2</smXML:version>
        const char* verTag = strstr(bagXml, "<smXML:version>");
        if (!verTag) verTag = strstr(bagXml, "<gco:CharacterString>1."); // rough fallback
        if (verTag) {
            const char* start = strchr(verTag, '>');
            if (start) {
                start++;
                const char* end = strchr(start, '<');
                if (end && end - start < 20) {
                    return std::string(start, end - start);
                }
            }
        }
    }

    // Also check the GDAL metadata for BAG Version
    const char* ver = ds->GetMetadataItem("BAG_VERSION");
    if (ver) return std::string(ver);

    return "unknown";
}

/// Check if the BAG file appears to be variable-resolution (VR).
static bool isVariableResolution(GDALDataset* ds)
{
    if (!ds) return false;
    // VR BAG files expose supergrids as subdatasets
    char** subdatasets = ds->GetMetadata("SUBDATASETS");
    if (subdatasets) {
        for (int i = 0; subdatasets[i] != nullptr; ++i) {
            if (strstr(subdatasets[i], "supergrid") ||
                strstr(subdatasets[i], "SUPERGRID")) {
                return true;
            }
        }
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// CRS resolution
// ─────────────────────────────────────────────────────────────────────────────

struct CrsResult {
    OGRSpatialReference srs;
    bool                isFallback = false;   ///< True if we defaulted to WGS84
    bool                isOverride = false;   ///< True if user supplied a CRS
    std::string         sourceDescription;    ///< Human-readable provenance
};

/// Resolve the best available CRS for the dataset.
static CrsResult resolveCRS(GDALDataset* ds,
                            const std::string& userWkt,
                            int userEpsg,
                            int fallbackEpsg)
{
    CrsResult result;
    result.srs.SetAxisMappingStrategy(OAMS_TRADITIONAL_GIS_ORDER);

    // 1. User-supplied CRS (highest priority)
    if (!userWkt.empty()) {
        if (parseSRS(userWkt, result.srs)) {
            result.isOverride = true;
            result.sourceDescription = "user-supplied WKT/EPSG string";
            return result;
        }
        std::cerr << "[WARNING] Could not parse user-supplied CRS: " << userWkt
                  << "\n  Falling back to dataset CRS.\n";
    }
    if (userEpsg > 0) {
        OGRErr err = result.srs.importFromEPSG(userEpsg);
        if (err == OGRERR_NONE) {
            result.isOverride = true;
            result.sourceDescription = "user-supplied EPSG:" + std::to_string(userEpsg);
            return result;
        }
        std::cerr << "[WARNING] Could not import EPSG:" << userEpsg
                  << "\n  Falling back to dataset CRS.\n";
        result.srs.Clear();
    }

    // 2. CRS from dataset (standard case)
    const char* dsWkt = ds->GetProjectionRef();
    if (dsWkt && strlen(dsWkt) > 0) {
        OGRSpatialReference dsSrs;
        dsSrs.SetAxisMappingStrategy(OAMS_TRADITIONAL_GIS_ORDER);
        if (parseSRS(std::string(dsWkt), dsSrs) && !dsSrs.IsEmpty()) {
            result.srs = dsSrs;
            result.sourceDescription = "BAG file metadata";
            return result;
        }
        std::cerr << "[WARNING] BAG file contains a CRS string but it could not be "
                     "parsed:\n  \"" << dsWkt << "\"\n"
                  << "  Attempting fallback CRS.\n";
    } else {
        std::cerr << "[WARNING] BAG file contains no CRS information.\n";
    }

    // 3. Fallback CRS
    result.srs.Clear();
    result.srs.SetAxisMappingStrategy(OAMS_TRADITIONAL_GIS_ORDER);
    OGRErr err = result.srs.importFromEPSG(fallbackEpsg);
    if (err != OGRERR_NONE) {
        // Last resort: hardcode WGS84
        result.srs.SetWellKnownGeogCS("WGS84");
    }
    result.isFallback = true;
    result.sourceDescription = "fallback EPSG:" + std::to_string(fallbackEpsg) +
                               " (no valid CRS in BAG file)";

    std::cerr << "[INFO] Using " << result.sourceDescription << "\n";
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Band label helpers
// ─────────────────────────────────────────────────────────────────────────────

static std::string getBandLabel(GDALRasterBand* band, int bandIndex)
{
    const char* desc = band->GetDescription();
    if (desc && strlen(desc) > 0) return std::string(desc);

    switch (bandIndex) {
        case 1: return "elevation";
        case 2: return "uncertainty";
        case 3: return "nominal_elevation";
        default: return "band_" + std::to_string(bandIndex);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Conversion options
// ─────────────────────────────────────────────────────────────────────────────

struct ConvertOptions {
    std::string inputFile;
    std::string outputFile;
    std::string userWkt;          ///< User-supplied CRS (WKT or user input string)
    int         userEpsg      = 0;///< User-supplied EPSG code
    int         fallbackEpsg  = DEFAULT_FALLBACK_EPSG;
    bool        elevationOnly = false;
    bool        allBands      = true;
    std::string compression   = "DEFLATE";
    std::string vrMode        = "RESAMPLED_GRID";
};

static void printHelp(const char* progname)
{
    std::cout <<
        "Usage: " << progname << " [OPTIONS] <input.bag> [output.tif]\n"
        "\n"
        "Converts BAG bathymetric files (v1.0–v2.0+) to GeoTiff.\n"
        "\n"
        "Options:\n"
        "  --epsg <code>        Override/assign EPSG code as horizontal CRS\n"
        "  --wkt <string>       Override/assign WKT string as horizontal CRS\n"
        "  --fallback-epsg <N>  EPSG to use when CRS is missing (default: 4326 = WGS84)\n"
        "  --elevation-only     Export only Band 1 (elevation)\n"
        "  --all-bands          Export all bands: elevation, uncertainty, extras (default)\n"
        "  --compress <method>  DEFLATE (default), LZW, NONE\n"
        "  --vr-mode <mode>     VR BAG mode: RESAMPLED_GRID (default), LIST_SUPERGRIDS\n"
        "  --help               Show this help\n"
        "\n"
        "If output.tif is omitted, the output will be named after the input with .tif.\n"
        "\n"
        "CRS handling:\n"
        "  1. User --epsg or --wkt override (highest priority)\n"
        "  2. CRS embedded in BAG XML metadata (standard)\n"
        "  3. Fallback EPSG (default WGS84 geographic) when BAG has no CRS\n"
        "\n"
        "Examples:\n"
        "  " << progname << " survey.bag\n"
        "  " << progname << " survey.bag output.tif\n"
        "  " << progname << " --epsg 32619 survey.bag output.tif\n"
        "  " << progname << " --fallback-epsg 4326 no_crs.bag output.tif\n"
        "  " << progname << " --elevation-only --compress LZW survey.bag output.tif\n"
        "\n";
}

static ConvertOptions parseArgs(int argc, char** argv)
{
    ConvertOptions opts;
    std::vector<std::string> positional;

    for (int i = 1; i < argc; ++i) {
        std::string arg(argv[i]);

        if (arg == "--help" || arg == "-h") {
            printHelp(argv[0]);
            exit(0);
        } else if (arg == "--epsg" && i + 1 < argc) {
            opts.userEpsg = std::atoi(argv[++i]);
        } else if (arg == "--wkt" && i + 1 < argc) {
            opts.userWkt = argv[++i];
        } else if (arg == "--fallback-epsg" && i + 1 < argc) {
            opts.fallbackEpsg = std::atoi(argv[++i]);
        } else if (arg == "--elevation-only") {
            opts.elevationOnly = true;
            opts.allBands = false;
        } else if (arg == "--all-bands") {
            opts.allBands = true;
        } else if (arg == "--compress" && i + 1 < argc) {
            opts.compression = argv[++i];
            // Normalize to uppercase
            std::transform(opts.compression.begin(), opts.compression.end(),
                           opts.compression.begin(), ::toupper);
        } else if (arg == "--vr-mode" && i + 1 < argc) {
            opts.vrMode = argv[++i];
        } else if (arg[0] != '-') {
            positional.push_back(arg);
        } else {
            std::cerr << "[WARNING] Unknown option: " << arg << "\n";
        }
    }

    if (positional.empty()) {
        std::cerr << "[ERROR] No input file specified.\n";
        printHelp(argv[0]);
        exit(1);
    }

    opts.inputFile = positional[0];

    if (positional.size() >= 2) {
        opts.outputFile = positional[1];
    } else {
        // Auto-generate output name: replace .bag with .tif
        std::filesystem::path p(opts.inputFile);
        p.replace_extension(".tif");
        opts.outputFile = p.string();
    }

    return opts;
}

// ─────────────────────────────────────────────────────────────────────────────
// Core conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a single BAG dataset (already opened) to a GeoTiff file.
/// Returns true on success.
static bool convertDataset(GDALDataset* srcDs,
                           const std::string& outputPath,
                           const ConvertOptions& opts,
                           const CrsResult& crs)
{
    int xSize = srcDs->GetRasterXSize();
    int ySize = srcDs->GetRasterYSize();
    int nBands = srcDs->GetRasterCount();

    if (xSize <= 0 || ySize <= 0 || nBands <= 0) {
        std::cerr << "[ERROR] Dataset has invalid dimensions: "
                  << xSize << "x" << ySize << " with " << nBands << " band(s).\n";
        return false;
    }

    // Determine which bands to copy
    int bandsToCopy = nBands;
    if (opts.elevationOnly) bandsToCopy = 1;
    // (allBands uses the default nBands)

    // Read geotransform
    double gt[6] = {0};
    bool hasGT = (srcDs->GetGeoTransform(gt) == CE_None);
    if (!hasGT) {
        std::cerr << "[WARNING] No geotransform in source dataset; "
                     "output will not be georeferenced.\n";
    }

    // Sanity check: do the coordinates make sense for the CRS?
    if (hasGT && !crs.isFallback && !crs.isOverride) {
        if (!georefSanityCheck(gt, xSize, ySize, crs.srs)) {
            std::cerr << "[WARNING] Geotransform coordinates may be inconsistent "
                         "with the detected CRS.\n"
                      << "  Center X: " << (gt[0] + gt[1]*xSize*0.5)
                      << "  Center Y: " << (gt[3] + gt[5]*ySize*0.5) << "\n"
                      << "  CRS: " << crs.sourceDescription << "\n"
                      << "  Consider using --epsg to manually specify the correct CRS.\n";
        }
    }

    // Build GeoTiff creation options
    char** createOptions = nullptr;
    if (opts.compression != "NONE") {
        createOptions = CSLSetNameValue(createOptions, "COMPRESS", opts.compression.c_str());
        if (opts.compression == "DEFLATE") {
            createOptions = CSLSetNameValue(createOptions, "PREDICTOR", "2");
        }
    }
    createOptions = CSLSetNameValue(createOptions, "TILED", "YES");
    createOptions = CSLSetNameValue(createOptions, "BIGTIFF", "IF_SAFER");
    createOptions = CSLSetNameValue(createOptions, "NUM_THREADS", "ALL_CPUS");

    // Get output driver
    GDALDriver* tiffDriver = GetGDALDriverManager()->GetDriverByName("GTiff");
    if (!tiffDriver) {
        std::cerr << "[ERROR] GeoTiff driver not available in this GDAL build.\n";
        CSLDestroy(createOptions);
        return false;
    }

    // Create output dataset
    GDALDataset* dstDs = tiffDriver->Create(
        outputPath.c_str(), xSize, ySize, bandsToCopy, GDT_Float32, createOptions);
    CSLDestroy(createOptions);

    if (!dstDs) {
        std::cerr << "[ERROR] Failed to create output file: " << outputPath << "\n";
        reportError("GDALDriver::Create", CE_Failure);
        return false;
    }

    // Set geotransform
    if (hasGT) {
        dstDs->SetGeoTransform(gt);
    }

    // Set CRS — export as WKT string
    {
        char* wktOut = nullptr;
        OGRErr wktErr = crs.srs.exportToWkt(&wktOut);
        if (wktErr == OGRERR_NONE && wktOut && strlen(wktOut) > 0) {
            dstDs->SetProjection(wktOut);
        } else if (wktErr != OGRERR_NONE) {
            std::cerr << "[WARNING] Could not export CRS to WKT; "
                         "output will have no CRS.\n";
        }
        CPLFree(wktOut);
    }

    // Copy bands
    for (int b = 1; b <= bandsToCopy; ++b) {
        GDALRasterBand* srcBand = srcDs->GetRasterBand(b);
        GDALRasterBand* dstBand = dstDs->GetRasterBand(b);

        if (!srcBand || !dstBand) {
            std::cerr << "[WARNING] Could not access band " << b << "; skipping.\n";
            continue;
        }

        // Set description
        std::string label = getBandLabel(srcBand, b);
        dstBand->SetDescription(label.c_str());

        // Set nodata
        int hasNodata = 0;
        double srcNodata = srcBand->GetNoDataValue(&hasNodata);
        if (hasNodata) {
            dstBand->SetNoDataValue(srcNodata);
        } else {
            // Fallback: BAG spec uses 1e6 for elevation and 0.0 for uncertainty,
            // but GDAL's driver normalises both to 1e6 when reporting nodata.
            // We only reach here if GDAL reports no nodata at all (unusual).
            dstBand->SetNoDataValue(BAG_NODATA);
        }

        // Copy band metadata
        char** bandMeta = srcBand->GetMetadata();
        if (bandMeta) {
            dstBand->SetMetadata(bandMeta);
        }

        // Copy the raster data in chunked blocks for memory efficiency
        const int CHUNK_ROWS = 256;
        std::vector<float> rowBuf(static_cast<size_t>(xSize) * CHUNK_ROWS);

        for (int row = 0; row < ySize; row += CHUNK_ROWS) {
            int rowsThisChunk = std::min(CHUNK_ROWS, ySize - row);

            CPLErr readErr = srcBand->RasterIO(
                GF_Read, 0, row, xSize, rowsThisChunk,
                rowBuf.data(), xSize, rowsThisChunk,
                GDT_Float32, 0, 0);

            if (readErr != CE_None) {
                std::cerr << "[ERROR] Failed to read band " << b
                          << " at row " << row << "\n";
                GDALClose(dstDs);
                return false;
            }

            CPLErr writeErr = dstBand->RasterIO(
                GF_Write, 0, row, xSize, rowsThisChunk,
                rowBuf.data(), xSize, rowsThisChunk,
                GDT_Float32, 0, 0);

            if (writeErr != CE_None) {
                std::cerr << "[ERROR] Failed to write band " << b
                          << " at row " << row << "\n";
                GDALClose(dstDs);
                return false;
            }
        }

        std::cout << "  Band " << b << " (" << label << "): copied "
                  << xSize << "x" << ySize << " pixels.\n";
    }

    // Copy dataset-level metadata
    char** dsMeta = srcDs->GetMetadata();
    if (dsMeta) {
        dstDs->SetMetadata(dsMeta);
    }

    // Preserve BAG XML metadata in a custom metadata domain
    const char* bagXml = srcDs->GetMetadataItem("", "xml:BAG");
    if (!bagXml) bagXml = srcDs->GetMetadataItem("xml:BAG", "");
    if (bagXml) {
        dstDs->SetMetadataItem("BAG_XML_METADATA", bagXml, "BAG");
    }

    // Also store CRS provenance info
    dstDs->SetMetadataItem("BAG_CRS_SOURCE", crs.sourceDescription.c_str(), "BAG");
    if (crs.isFallback) {
        dstDs->SetMetadataItem("BAG_CRS_FALLBACK", "YES", "BAG");
    }

    // Compute statistics for each band
    std::cout << "  Computing band statistics...\n";
    for (int b = 1; b <= bandsToCopy; ++b) {
        GDALRasterBand* band = dstDs->GetRasterBand(b);
        if (band) {
            double minV, maxV, meanV, stdV;
            // approxOK=TRUE for speed, bForce=TRUE to actually compute
            CPLErr statErr = band->ComputeStatistics(TRUE, &minV, &maxV,
                                                      &meanV, &stdV,
                                                      nullptr, nullptr);
            if (statErr == CE_None) {
                std::cout << "    Band " << b << ": min=" << minV
                          << " max=" << maxV << " mean=" << meanV << "\n";
            }
        }
    }

    // Build overviews (for efficient rendering in GIS tools)
    int overviewLevels[] = {2, 4, 8, 16};
    int numLevels = 4;
    // Only build if the image is large enough
    if (xSize > 512 && ySize > 512) {
        std::cout << "  Building overviews...\n";
        CPLErr ovErr = dstDs->BuildOverviews("AVERAGE", numLevels,
                                              overviewLevels, 0, nullptr,
                                              GDALDummyProgress, nullptr);
        if (ovErr != CE_None) {
            std::cerr << "[WARNING] Failed to build overviews (non-fatal).\n";
        }
    }

    GDALClose(dstDs);
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Main conversion entry point
// ─────────────────────────────────────────────────────────────────────────────

static bool convertBagToGeotiff(const ConvertOptions& opts)
{
    std::cout << "=== BAG to GeoTiff Converter ===\n"
              << "Input:  " << opts.inputFile << "\n"
              << "Output: " << opts.outputFile << "\n\n";

    // ── Step 1: Open the BAG file (initial probe to detect VR and version) ──

    char** openOptions = nullptr;
    openOptions = CSLSetNameValue(openOptions, "MODE", "LOW_RES_GRID");
    openOptions = CSLSetNameValue(openOptions, "REPORT_VERTCRS", "YES");

    GDALDataset* probeDs = (GDALDataset*)GDALOpenEx(
        opts.inputFile.c_str(),
        GDAL_OF_RASTER | GDAL_OF_READONLY,
        nullptr, openOptions, nullptr);
    CSLDestroy(openOptions);

    if (!probeDs) {
        std::cerr << "[ERROR] Could not open: " << opts.inputFile << "\n";
        reportError("GDALOpenEx", CE_Failure);
        return false;
    }

    // Detect BAG version
    std::string bagVersion = detectBagVersion(probeDs);
    bool isVR = isVariableResolution(probeDs);

    std::cout << "BAG version: " << bagVersion << "\n"
              << "Variable resolution: " << (isVR ? "YES" : "NO") << "\n"
              << "Dimensions: " << probeDs->GetRasterXSize()
              << " x " << probeDs->GetRasterYSize() << "\n"
              << "Bands: " << probeDs->GetRasterCount() << "\n";

    // ── Step 2: Determine CRS ──

    CrsResult crs = resolveCRS(probeDs, opts.userWkt, opts.userEpsg,
                               opts.fallbackEpsg);

    std::cout << "CRS source: " << crs.sourceDescription << "\n";

    {
        char* wktDisplay = nullptr;
        crs.srs.exportToPrettyWkt(&wktDisplay);
        if (wktDisplay) {
            std::cout << "CRS:\n" << wktDisplay << "\n\n";
            CPLFree(wktDisplay);
        }
    }

    GDALClose(probeDs);

    // ── Step 3: Re-open with appropriate mode for conversion ──

    GDALDataset* srcDs = nullptr;

    if (isVR) {
        std::cout << "[INFO] Variable-resolution BAG detected. "
                  << "Opening in " << opts.vrMode << " mode.\n";

        char** vrOptions = nullptr;
        vrOptions = CSLSetNameValue(vrOptions, "MODE", opts.vrMode.c_str());
        vrOptions = CSLSetNameValue(vrOptions, "REPORT_VERTCRS", "YES");
        if (opts.vrMode == "RESAMPLED_GRID") {
            // Use minimum resolution to capture full detail
            vrOptions = CSLSetNameValue(vrOptions, "RES_STRATEGY", "MIN");
            vrOptions = CSLSetNameValue(vrOptions, "VALUE_POPULATION", "MAX");
        }

        srcDs = (GDALDataset*)GDALOpenEx(
            opts.inputFile.c_str(),
            GDAL_OF_RASTER | GDAL_OF_READONLY,
            nullptr, vrOptions, nullptr);
        CSLDestroy(vrOptions);
    } else {
        // Standard BAG: re-open normally
        char** stdOptions = nullptr;
        stdOptions = CSLSetNameValue(stdOptions, "MODE", "LOW_RES_GRID");
        stdOptions = CSLSetNameValue(stdOptions, "REPORT_VERTCRS", "YES");

        srcDs = (GDALDataset*)GDALOpenEx(
            opts.inputFile.c_str(),
            GDAL_OF_RASTER | GDAL_OF_READONLY,
            nullptr, stdOptions, nullptr);
        CSLDestroy(stdOptions);
    }

    if (!srcDs) {
        std::cerr << "[ERROR] Failed to re-open BAG for conversion.\n";
        reportError("GDALOpenEx (conversion)", CE_Failure);
        return false;
    }

    // ── Step 4: Convert ──

    bool success = convertDataset(srcDs, opts.outputFile, opts, crs);

    GDALClose(srcDs);

    if (success) {
        std::cout << "\n[OK] Conversion complete: " << opts.outputFile << "\n";
    } else {
        std::cerr << "\n[FAILED] Conversion failed for: " << opts.inputFile << "\n";
    }

    return success;
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

int main(int argc, char** argv)
{
    // Initialize GDAL
    GDALAllRegister();
    CPLSetConfigOption("GDAL_PAM_ENABLED", "NO"); // Disable .aux.xml sidecar files

    // Suppress noisy GDAL errors during normal operation
    CPLSetErrorHandler(CPLQuietErrorHandler);

    // Parse arguments
    ConvertOptions opts = parseArgs(argc, argv);

    // Validate input file exists
    if (!std::filesystem::exists(opts.inputFile)) {
        std::cerr << "[ERROR] Input file not found: " << opts.inputFile << "\n";
        return 1;
    }

    // Run conversion
    bool ok = convertBagToGeotiff(opts);

    GDALDestroyDriverManager();
    return ok ? 0 : 1;
}
