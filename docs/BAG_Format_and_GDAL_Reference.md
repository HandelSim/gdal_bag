# BAG (Bathymetric Attributed Grid) Format Reference
## Version History, Coordinate Systems, and GDAL Handling

---

## 1. Overview

The **Bathymetric Attributed Grid (BAG)** is an open, non-proprietary file format for storing and exchanging bathymetric (seafloor depth) data. It was developed by the **Open Navigation Surface Working Group (ONSWG)**, a consortium of hydrographic offices, academic institutions, and software vendors, with the first official release in April 2006.

BAG files are the **standard data product format** for the NOAA Office of Coast Survey and are used by hydrographic offices worldwide, including the UK Hydrographic Office (UKHO) and the US Naval Oceanographic Office (NAVOCEANO).

### Core Properties
- Container format: **HDF5 (Hierarchical Data Format version 5)**
- Metadata standard: **ISO 19115 / ISO 19139 XML**
- Coordinate convention: **Right-handed Cartesian** (Z positive upward)
- Nodata sentinel value: **1,000,000.0 (1.0e6)**
- Elevation sign: **Positive above vertical datum** (depths are negative)
- Grid type: Regular, fixed-spacing grid (contiguous geographic region)

---

## 2. BAG Version History

### Version 1.0.0 / 1.0.1 (April 2006) — First Release

The initial specification establishing:
- HDF5 container structure with four mandatory datasets: `elevation`, `uncertainty`, `metadata`, `tracking_list`
- ISO 19115 XML metadata block stored as raw byte array
- Simple spatial reference encoded as WKT within the XML metadata
- Elevation and uncertainty grids as 32-bit float arrays
- Grid georeference: SW corner coordinates + node spacing (RESX, RESY) stored in metadata XML
- BAG version string stored as HDF5 attribute `/BAG_root/BAG Version`

**CRS storage**: A single `referenceSystemInfo` block in the ISO XML metadata containing the horizontal CRS as a WKT string (or occasionally as an EPSG code string).

**Known issues with v1.0 files**:
- Some early producers stored CRS as EPSG code text only (e.g., `"EPSG:32617"`) rather than full WKT
- No explicit vertical datum specification; assumed MLLW or chart datum
- No compression support

### Version 1.1.0 (2009)

- Expanded XML metadata with additional optional datasets
- Added support for **optional layers** beyond elevation and uncertainty
- Introduced `nominal_elevation` dataset (optional)
- Improved documentation of the tracking list schema

### Version 1.2.0 (2009)

- Added **Nominal Depth** as a depth correction type (NAVOCEANO requirement)
- Enhanced support for corrected vs. nominal depth representations
- Minor XML schema clarifications

### Version 1.3.0 (2010)

- Intermediate specification clarifications
- Improved interoperability guidance

### Version 1.4.0 (2011)

- Added **HDF5 DEFLATE compression** support for elevation/uncertainty datasets
- This is the basis for **IHO S-102** Bathymetric Surface Product Specification (adopted April 2012)
- Introduced `chunk_size` concept for HDF5 dataset storage
- Improved metadata validation rules

**Note on S-102**: IHO S-102 is derived from BAG 1.4 and adds S-100 framework compliance for official nautical chart products. S-102 files use the same HDF5/BAG structure but with stricter metadata requirements.

### Version 1.5.0 (2012)

- **Major metadata schema change**: Updated ISO XML schema to align with current ISO 19115 standards
- The XPath expressions for key metadata fields changed between 1.4 and 1.5:

| Field             | BAG ≤ 1.4 XPath                                            | BAG 1.5 XPath                                                  |
|-------------------|------------------------------------------------------------|----------------------------------------------------------------|
| Horizontal WKT    | `smXML:MD_CRS/projection/smXML:RS_Identifier/code`        | `gmd:MD_ReferenceSystem/.../gmd:RS_Identifier/gmd:code`       |
| Vertical WKT      | `smXML:verticalCRS/...`                                    | `gmd:MD_ReferenceSystem/.../gmd:RS_Identifier/gmd:code`       |
| Abstract          | `smXML:MD_DataIdentification/abstract`                     | `gmd:MD_DataIdentification/.../gmd:abstract/gco:CharacterString` |

- Files from producers using ArcGIS Maritime Bathymetry 10.2.1 and earlier may use the old schema; 10.2.2+ use the new schema
- GDAL handles both XPath variants automatically

### Version 1.6.2 (2015–present) — Default GDAL Output Version

- Current stable release used as GDAL's default when creating new BAG files
- Incremental clarifications to the specification
- Added guidance on variable resolution grids (later formalized)

### Version 2.0.x (2019–2022)

Version 2.0 is a **major redesign** that includes:
- **Variable Resolution (VR) grids**: Each low-resolution cell can contain a higher-resolution sub-grid
- **Georeferenced metadata layers**: Named 2D raster layers with associated attribute tables
- **Tracking list improvements**: Better provenance tracking
- **Security metadata fields**: Classification and restriction info
- **Compound CRS support**: Explicit horizontal + vertical CRS pairing
- **OGC Community Standard**: BAG 2.0 was submitted as an OGC standard in 2020

**Version 2.0.1** (November 2022) is the current released specification.

---

## 3. Internal HDF5 Structure

A BAG file (all versions) contains the following HDF5 structure:

```
/BAG_root/                          (HDF5 group — root)
├── BAG Version                     (HDF5 attribute, string, e.g. "1.6.2")
├── elevation                       (HDF5 dataset, float32 2D array, rows=N/S, cols=E/W)
│   ├── Maximum Elevation Value     (HDF5 attribute, float)
│   └── Minimum Elevation Value     (HDF5 attribute, float)
├── uncertainty                     (HDF5 dataset, float32 2D array, co-located with elevation)
│   ├── Maximum Uncertainty Value   (HDF5 attribute, float)
│   └── Minimum Uncertainty Value   (HDF5 attribute, float)
├── metadata                        (HDF5 dataset, char array — raw ISO 19115 XML)
├── tracking_list                   (HDF5 dataset, compound type — edit history)
│   └── Tracking List Length        (HDF5 attribute, uint32)
│
│   [BAG 2.0+ additional items:]
├── georef_metadata/                (HDF5 group)
│   └── <layer_name>/               (HDF5 group per named layer)
│       ├── keys                    (HDF5 dataset, uint32 2D array — index into values)
│       └── values                  (HDF5 dataset, compound type — attribute table rows)
└── varres_metadata                 (HDF5 dataset — VR grid cell descriptors, BAG 2.0+)
└── varres_refinements              (HDF5 dataset — actual VR node data, BAG 2.0+)
```

### Grid Orientation
The elevation array is stored **row-major** with:
- Row 0 = **southernmost** latitude (bottom of image)
- Row N-1 = **northernmost** latitude (top of image)
- Column 0 = **westernmost** longitude (left)
- Column M-1 = **easternmost** longitude (right)

This is the **opposite of the typical image convention** (where row 0 is at the top). GDAL handles this inversion transparently via negative Y pixel size in the geotransform.

---

## 4. Coordinate Reference System (CRS) Handling

### How CRS is Stored in BAG Files

CRS information is embedded in the ISO 19115 XML metadata blob. The horizontal CRS is expressed as a **WKT (Well-Known Text) string** within the XML:

**BAG ≤ 1.4 XML path:**
```xml
<smXML:MD_CRS>
  <smXML:projection>
    <smXML:RS_Identifier>
      <smXML:code>PROJCS["NAD83 / UTM zone 19N",...]</smXML:code>
    </smXML:RS_Identifier>
  </smXML:projection>
</smXML:MD_CRS>
```

**BAG 1.5+ XML path (ISO 19139):**
```xml
<gmd:referenceSystemInfo>
  <gmd:MD_ReferenceSystem>
    <gmd:referenceSystemIdentifier>
      <gmd:RS_Identifier>
        <gmd:code>
          <gco:CharacterString>PROJCS["NAD83 / UTM zone 19N",...]</gco:CharacterString>
        </gmd:code>
      </gmd:RS_Identifier>
    </gmd:referenceSystemIdentifier>
  </gmd:MD_ReferenceSystem>
</gmd:referenceSystemInfo>
```

### Common Coordinate Systems in BAG Files

| Projection Type      | Common Usage                    | Example WKT Name                         |
|---------------------|---------------------------------|------------------------------------------|
| UTM Zone N (NAD83)  | NOAA surveys (US coastal)       | `NAD83 / UTM zone 19N`                   |
| UTM Zone N (WGS84)  | International surveys           | `WGS 84 / UTM zone 32N`                  |
| Geographic WGS84    | Global/deep water surveys       | `WGS 84` (EPSG:4326)                     |
| Geographic NAD83    | US surveys (older)              | `NAD83` (EPSG:4269)                      |
| State Plane (US)    | Nearshore US surveys            | `NAD83 / Massachusetts Mainland`         |
| UTM Zone S (WGS84)  | Southern hemisphere surveys     | `WGS 84 / UTM zone 55S`                  |
| ITRF2014 Geographic | Modern precise surveys          | `ITRF2014` (EPSG:9000)                   |

### Vertical Datums

BAG files typically reference one of these vertical datums:
- **MLLW** (Mean Lower Low Water) — US standard for nautical charts
- **MLW** (Mean Low Water) — UK/international
- **MSL** (Mean Sea Level) — scientific use
- **MHWS** (Mean High Water Springs) — some European applications
- **LAT** (Lowest Astronomical Tide) — IHO standard
- **Ellipsoidal** — GPS-referenced (used in some modern surveys)

---

## 5. CRS Edge Cases and Problem Files

### Case 1: Missing or Empty CRS

Some BAG files, particularly older ones or those from non-standard producers, contain either:
- An empty `<code>` element in the metadata XML
- The literal string `"unknown"` as the CRS
- No `referenceSystemInfo` block at all

**GDAL behavior**: Returns an empty/invalid SRS. The dataset will open but `GetProjectionRef()` returns `""` or a blank WKT.

**Recommended handling**: Default to geographic WGS84 (EPSG:4326) if no CRS is detected, with a warning to the user.

### Case 2: Non-WKT CRS Encoding

Some producers stored CRS as bare EPSG code strings:
```xml
<gco:CharacterString>EPSG:32617</gco:CharacterString>
```

**GDAL behavior**: Modern GDAL (3.x+) can often parse these via `OGRSpatialReference::SetFromUserInput()`. Older GDAL may fail silently.

**Recommended handling**: Attempt `SetFromUserInput()` if direct WKT parse fails.

### Case 3: Malformed WKT

Early software produced slightly non-standard WKT. Common issues:
- Missing `AUTHORITY["EPSG","XXXX"]` nodes
- Incorrect TOWGS84 parameters
- Custom/local datums with no EPSG mapping

**GDAL behavior**: May partially parse, may return incorrect SRS. The `morphFromESRI()` function can sometimes help with ESRI-style WKT variants.

### Case 4: Geographic CRS with Projected Coordinates

Some files declare a geographic CRS (lat/lon) but the corner coordinates in the metadata are actually in projected units (meters). This is a producer error but does occur.

**Detection**: Check if `SW corner X/Y` values are in the range expected for geographic (±180, ±90) vs. projected (large meter values).

### Case 5: NAD27 vs NAD83

Older US surveys may use NAD27. The difference can be up to ~200 meters from NAD83. GDAL will report the CRS correctly, but users comparing data across datums need to be aware.

---

## 6. GDAL BAG Driver Capabilities

### Version Support
- GDAL supports all BAG versions (1.0 through 2.0+) via its HDF5-based BAG driver
- The driver requires **libhdf5** as a build dependency
- BAG support is compiled in by default in most GDAL distributions

### Read Capabilities

| Feature                              | Supported | Notes                                       |
|--------------------------------------|-----------|---------------------------------------------|
| Elevation band                       | Yes       | Band 1, float32                             |
| Uncertainty band                     | Yes       | Band 2, float32                             |
| Nominal elevation band               | Yes (3.2+)| Band 3 if present                           |
| Additional 2D numeric bands          | Yes (3.2+)| Any bands matching elevation dimensions     |
| Geotransform (georeferencing)        | Yes       | Extracted from XML metadata                 |
| Horizontal CRS (WKT)                 | Yes       | From XML metadata; may fail for bad WKT     |
| Vertical CRS                         | Yes (3.2+)| `REPORT_VERTCRS=YES` (default)              |
| Compound CRS (horizontal+vertical)   | Yes (3.2+)| Returned as compound WKT                    |
| XML metadata domain                  | Yes       | `"xml:BAG"` metadata domain                 |
| Nodata value                         | Yes       | Reported as 1e6                             |
| Min/Max values                       | Yes       | From HDF5 attributes                        |
| Variable resolution (VR) grids       | Yes (2.0+)| Multiple modes available                    |
| Georef metadata layers               | Yes (3.2+)| As subdatasets                              |
| Tracking list (as OGR vector)        | Yes       | Open in vector mode                         |
| Compression (DEFLATE)               | Yes       | Transparent read                            |

### Open Options

| Option              | Values              | Default     | Description                                           |
|--------------------|---------------------|-------------|-------------------------------------------------------|
| `REPORT_VERTCRS`   | YES / NO            | YES         | Include vertical CRS in compound CRS output           |
| `MODE`             | See below           | LOW_RES_GRID| Controls how the dataset is presented                 |

**MODE values:**

| Mode              | Description                                                                            |
|-------------------|----------------------------------------------------------------------------------------|
| `LOW_RES_GRID`    | Default. Returns the low-resolution overview grid.                                     |
| `LIST_SUPERGRIDS` | Lists variable-resolution sub-grids as subdatasets.                                    |
| `RESAMPLED_GRID`  | Combines VR sub-grids into a target resolution grid using value population strategy.   |
| `INTERPOLATED`    | (GDAL 3.8+) Bilinear interpolation across VR sub-grids.                               |
| `AUTO`            | Automatically selects appropriate mode.                                                |

### Variable Resolution (VR) Specific Options (MODE=RESAMPLED_GRID)

| Option              | Values                  | Default | Description                                   |
|--------------------|-------------------------|---------|-----------------------------------------------|
| `RESX`             | Float                   | Auto    | Target X resolution                           |
| `RESY`             | Float                   | Auto    | Target Y resolution                           |
| `RES_STRATEGY`     | AUTO/MIN/MAX/MEAN       | AUTO    | How to determine target resolution            |
| `VALUE_POPULATION` | MIN/MAX/MEAN/COUNT      | MAX     | How to populate cells from overlapping nodes  |
| `SUPERGRIDS_MASK`  | YES/NO                  | NO      | Output boolean mask of supergrid coverage     |

### Write/Creation Capabilities (GDAL 3.2+)

GDAL can create new BAG files using `CreateCopy()` or `Create()`:

| Creation Option       | Description                                        |
|-----------------------|----------------------------------------------------|
| `BAG_VERSION`         | Output BAG version string (default: "1.6.2")       |
| `COMPRESS`            | NONE or DEFLATE (default: DEFLATE)                 |
| `ZLEVEL`              | DEFLATE level 1–9 (default: 6)                     |
| `BLOCK_SIZE`          | HDF5 chunk size (default: 100)                     |
| `VAR_ABSTRACT`        | Dataset abstract/description text                  |
| `VAR_VERT_WKT`        | Vertical CRS WKT string                            |
| `VAR_DATE`            | Creation date (YYYY-MM-DD)                         |
| `VAR_INDIVIDUAL_NAME` | Contact name for metadata                          |
| `VAR_ORGANISATION_NAME`| Contact organization                              |
| `TEMPLATE`            | Custom XML metadata template path                  |

---

## 7. GDAL C++ API for BAG Files

### Opening a BAG File

```cpp
#include "gdal_priv.h"
#include "ogr_spatialref.h"

GDALAllRegister();

// Basic open (low-resolution grid mode)
GDALDataset* ds = (GDALDataset*)GDALOpen("file.bag", GA_ReadOnly);

// Open with explicit mode options
char** openOptions = nullptr;
openOptions = CSLSetNameValue(openOptions, "MODE", "LOW_RES_GRID");
openOptions = CSLSetNameValue(openOptions, "REPORT_VERTCRS", "YES");
GDALDataset* ds = (GDALDataset*)GDALOpenEx("file.bag",
    GDAL_OF_RASTER | GDAL_OF_READONLY, nullptr, openOptions, nullptr);
CSLDestroy(openOptions);
```

### Reading the CRS

```cpp
const char* wkt = ds->GetProjectionRef();
if (wkt == nullptr || strlen(wkt) == 0) {
    // No CRS detected — fall back to WGS84
    OGRSpatialReference srs;
    srs.importFromEPSG(4326);
    // Use this as the assumed CRS
}
```

### Reading the Geotransform

```cpp
double gt[6];
if (ds->GetGeoTransform(gt) == CE_None) {
    // gt[0] = top-left X (west edge of west pixel)
    // gt[1] = pixel width (positive, E-W resolution)
    // gt[2] = rotation (0 for north-up)
    // gt[3] = top-left Y (north edge of north pixel)
    // gt[4] = rotation (0 for north-up)
    // gt[5] = pixel height (negative for north-up rasters)
}
```

### Reading BAG-specific Metadata

```cpp
// Get the full ISO 19115 XML
const char* bagXml = ds->GetMetadataItem("", "xml:BAG");

// Get standard metadata
char** meta = ds->GetMetadata();
// Contains items like ABSTRACT, PROCESS_STEP_DESCRIPTION, etc.
```

---

## 8. BAG-to-GeoTiff Conversion Considerations

### Band Mapping

| BAG Band | Content           | GeoTiff Band | Notes                               |
|----------|------------------|--------------|-------------------------------------|
| 1        | Elevation         | 1            | Float32; nodata = 1e6               |
| 2        | Uncertainty       | 2 (optional) | Float32; nodata = 1e6               |
| 3        | Nominal elevation | 3 (optional) | Float32, if present (BAG 2.0+)      |

### GeoTiff Creation Options for BAG Data

Recommended GeoTiff creation options for bathymetric data:
- `COMPRESS=DEFLATE` — Lossless compression (important for float data)
- `PREDICTOR=2` — Horizontal differencing (improves compression of raster data)
- `TILED=YES` — Tiled storage for large files
- `BIGTIFF=IF_SAFER` — Handle files >4GB
- `NUM_THREADS=ALL_CPUS` — Multi-threaded compression

### CRS Assignment Strategy

When converting BAG to GeoTiff, the CRS must be handled carefully:

1. **Attempt to read CRS from BAG metadata** (standard case)
2. **If CRS is empty/invalid**, apply the configured fallback:
   - Default fallback: **WGS84 geographic** (EPSG:4326) — safe assumption for marine data
   - User-specified: Allow EPSG code or WKT override via command-line
3. **Validate the CRS** against the corner coordinates:
   - If CRS is geographic, coordinates should be in decimal degrees (-180 to 180 / -90 to 90)
   - If CRS is projected, coordinates should be large meter values
4. **Handle compound CRS**: The vertical component (MLLW, MSL, etc.) should be preserved in the GeoTiff metadata even if not natively supported as a GeoTiff CRS component

### Nodata Handling

The BAG nodata sentinel (1.0e6) should be set as the GeoTiff nodata value for all bands. This allows GIS tools to correctly mask land areas and survey gaps.

---

## 9. Variable Resolution (VR) BAG Files (BAG 2.0)

Variable resolution BAG files store data at multiple resolutions:
- A **low-resolution overview grid** (always present, accessible by default)
- **High-resolution sub-grids** ("supergrids") attached to each low-resolution cell

### GDAL Handling of VR BAGs

GDAL exposes VR BAGs as:
1. **Default (LOW_RES_GRID)**: Only the coarse overview grid
2. **LIST_SUPERGRIDS**: Each supergrid as a separate subdataset, e.g.:
   - `BAG:"file.bag":georef_metadata:uncertainty`
3. **RESAMPLED_GRID**: Virtual merged grid at a user-specified resolution
4. **INTERPOLATED** (GDAL 3.8+): Interpolated grid with bilinear/barycentric resampling

### Recommendation for VR BAG Conversion

For complete VR BAG conversion:
1. Open in `RESAMPLED_GRID` mode with `RES_STRATEGY=MIN` to get full resolution
2. Or open in `LIST_SUPERGRIDS` mode and convert each supergrid separately
3. The `MODE=AUTO` option lets GDAL decide the best strategy

---

## 10. Known GDAL BAG Driver Limitations

1. **Non-WKT CRS**: CRS stored as bare EPSG codes or in non-standard encoding may not be read
2. **Very old BAG files**: Pre-2006 draft files may have non-standard HDF5 structure
3. **S-102 files**: IHO S-102 files follow BAG structure but with different metadata namespaces; may require special handling
4. **Missing libhdf5**: If GDAL is built without HDF5 support, BAG files cannot be opened
5. **Compound CRS export**: Some older GeoTiff tools don't understand compound CRS WKT; vertical datum info may be lost when writing GeoTiff
6. **BAG 2.0 georef_metadata**: Raster attribute table layers in BAG 2.0 are not converted to GeoTiff (GeoTiff doesn't support this concept)
7. **Large VR files**: Very large variable-resolution BAG files can require significant memory in `RESAMPLED_GRID` mode

---

## 11. Testing and Validation

### Recommended Test Files

NOAA maintains a public archive of BAG files at:
```
https://data.ngdc.noaa.gov/platforms/ocean/nos/coast/
```

The URL structure is:
```
https://data.ngdc.noaa.gov/platforms/ocean/nos/coast/[HRANGE]/[SURVEY_ID]/BAG/[filename].bag
```

Where `[HRANGE]` is e.g. `H12001-H14000` for surveys numbered H12001–H14000.

**Test files used in this project** (downloaded from NOAA):

| File                              | Survey  | Size  | Grid        | CRS (as reported by GDAL)                     | Notes                                        |
|-----------------------------------|---------|-------|-------------|-----------------------------------------------|----------------------------------------------|
| H12023_MBVB_4m_MLLW_combined.bag  | H12023  | 18 MB | 5772×3142   | COMPD: NAD83/UTM zone 19N + MLLW depth        | Combined MB+VB, 4m res; full compound CRS    |
| H12048_MB_2m_MLLW_2of2.bag        | H12048  | 133 MB| 20680×9042  | COMPD: NAD83/UTM zone 15N + MLLW depth        | Gulf region, 2m res; full compound CRS       |
| H12238_MB_2m_MLLW_1of3.bag        | H12238  | 201 MB| 4842×5416   | PROJCS["unnamed"] → resolved NAD83/UTM zone 18N | Unnamed CRS in BAG; GDAL resolves correctly |

**Real-world CRS observation**: The H12238 file uses an unnamed PROJCS in its BAG metadata WKT but GDAL 3.8 successfully resolves it to NAD83/UTM zone 18N via the projection parameters. This is a common pattern in older NOAA survey files where the CRS name was not standardized.

### Validation Tools
- `gdalinfo file.bag` — Inspect metadata, CRS, bands, geotransform
- `gdalinfo -checksum file.tif` — Verify GeoTiff integrity
- QGIS / ArcGIS — Visual inspection
- HDF5 tools: `h5dump -n file.bag` — Inspect raw HDF5 structure
- `h5dump -a /BAG_root/"BAG Version" file.bag` — Check BAG version

---

## 12. References and Further Reading

- [BAG Format Specification (ReadTheDocs)](https://bag.readthedocs.io/en/master/fsd/index.html)
- [OpenNavigationSurface BAG GitHub](https://github.com/OpenNavigationSurface/BAG)
- [GDAL BAG Driver Documentation](https://gdal.org/en/stable/drivers/raster/bag.html)
- [OGC BAG Community Standard](https://www.ogc.org/standards/bag/)
- [NOAA NOS Hydrographic Survey Page](https://www.ncei.noaa.gov/products/nos-hydrographic-survey)
- [NOAA BAG File Archive](https://www.ngdc.noaa.gov/mgg/bathymetry/hydro.html)
- [BAG Format Specification v1.0 PDF (NOAA)](https://www.ngdc.noaa.gov/mgg/bathymetry/noshdb/ons_fsd.pdf)
- [ArcGIS Internal BAG Metadata XML Schema](https://desktop.arcgis.com/en/arcmap/latest/extensions/maritime-bathymetry/internal-bag-metadata-xml-schema.htm)
- [BAG Explorer Tool (HydrOffice)](https://www.hydroffice.org/bag/main)
- [Exploring BAG Files with Python (UNH)](https://salishsea-meopar-tools.readthedocs.io/en/latest/bathymetry/ExploringBagFiles.html)
