# `griddb` Package Documentation

## Purpose

`griddb` provides a standardized, globally-consistent grid system for
use as the spatial simulation unit in crop modeling workflows. It
replaces irregular, deployment-specific polygons with fixed-resolution
grid cells whose IDs are stable across regions, time, and re-generation
— enabling simulation results to be written and queried by integer key
rather than requiring point-in-polygon geometry work at every step.

It also provides supporting lookup tables for administrative/political
boundaries and crop presence masks, both keyed to the same cell IDs.

## When to use this package (and when not to)

Use `griddb` when a simulation needs **wall-to-wall coverage over a
region at a chosen resolution** — i.e. the simulation units only exist
because a resolution was chosen to tile an area (a country, a
catchment, a customer's full operating region).

Use your existing point/polygon tooling instead when a request already
arrives as an **explicit lat/lon** (a known farm location, a weather
station) or an **explicit polygon** (a customer-drawn paddock or AOI).
In both of those cases the request already names its own spatial unit;
routing it through `griddb` would add snapping error or unnecessary
intersection work with no benefit.

| Input type | Use |
|---|---|
| Explicit lat/lon | Current tools |
| Explicit polygon | Current tools |
| Wall-to-wall coverage over a region at a resolution | `griddb` |
| Cross-referencing with another raster dataset (crop mask, climate layer) | `griddb` |
| Aggregating results up to weather-cell / regional / country level over time | `griddb` |

## Installation

```r
# from the package directory
devtools::install()

# or for active development
devtools::load_all()
```

### Dependencies

- **Imports:** `sf`, `DBI`, `RPostgres`
- **Suggests:** `terra` (required only for `update_crop_mask()`),
  `testthat` (>= 3.0.0, for running the test suite)

## Database setup

`griddb` expects a PostGIS-enabled Postgres database. Any PostGIS
instance works (local, Supabase, RDS, etc.) — the package only needs a
working `DBI` connection.

### 1. Connection credentials

Connection parameters are read from environment variables, expected to
be set in a **project-level** `.Renviron` file (never committed to
version control):

```
SUPABASE_DB_HOST=aws-0-<region>.pooler.supabase.com
SUPABASE_DB_PORT=5432
SUPABASE_DB_NAME=postgres
SUPABASE_DB_USER=postgres.<project-ref>
SUPABASE_DB_PASSWORD=<your-password>
```

Create/edit this file from R:
```r
usethis::edit_r_environ(scope = "project")
```
Restart R for the variables to take effect. Confirm with:
```r
Sys.getenv("SUPABASE_DB_HOST")
```

Add it to `.gitignore` immediately:
```r
usethis::use_git_ignore(".Renviron")
```

### 2. Schema

Run `inst/sql/schema.sql` once against a fresh database. This creates:
- the `grids`, `masks`, and `staging` schemas
- `masks.cell_admin` and `masks.crop_presence` tables with their indexes

Grid resolution tables themselves (`grids.cells_<resolution>_arcmin`)
are **not** created by this script — they're created on demand by
`write_grid_to_postgis()` the first time a given resolution is
populated.

You can run the schema file via the Supabase SQL Editor (paste and
run), or from R:
```r
con <- get_db_connection()
sql <- readLines(system.file("sql/schema.sql", package = "griddb"))
sql <- paste(sql, collapse = "\n")
statements <- strsplit(sql, ";\\s*\\n")[[1]]
for (s in statements) if (nzchar(trimws(s))) DBI::dbExecute(con, paste0(s, ";"))
```

## Core concepts

### Cell IDs are globally stable

`compute_global_cell_id(lon, lat, resolution_arcmin)` derives a cell's
ID purely from its position and the chosen resolution, using a fixed
global origin at (-180°, 90°) and row-major ordering (cell 1 = upper
left, increasing left-to-right then top-to-bottom).

This means:
- The same lon/lat at the same resolution **always** produces the same
  cell_id, regardless of what's currently stored in the database.
- A grid generated for one country today and a grid generated for the
  whole world (or a different, overlapping country) later will assign
  **identical IDs** to any cells that overlap — no renumbering or
  migration is ever needed.
- Grids for adjacent regions, generated independently, share exact
  cell boundaries (achieved by snapping bounding boxes to global grid
  lines before generating).

### Three independent concerns, one key

| Table | Concern | Keyed by |
|---|---|---|
| `grids.cells_<res>_arcmin` | The simulation unit itself (geometry, centroid) | `cell_id` (primary) |
| `masks.cell_admin` | Political/administrative/customer-region membership | `cell_id` |
| `masks.crop_presence` | Fraction of cell under crop | `cell_id` |

Because these are independent tables joined only on `cell_id`:
- Updating a crop mask never touches grid geometry.
- Redrawing a customer's region never touches simulation results.
- No live geometry intersection happens at query time — every join in
  `get_simulation_cells()` is an integer-key lookup.

## Function reference

### Grid generation

#### `compute_global_cell_id(lon, lat, resolution_arcmin)`
Pure function: returns the global cell ID for a given position and
resolution. Vectorized over `lon`/`lat`.

#### `generate_grid_bbox(resolution_arcmin, xmin, ymin, xmax, ymax)`
Generates grid cell geometries (as an `sf` object) for a bounding box,
with the box snapped outward to global grid lines first so adjacent
calls produce cells with shared edges. Returns columns: `cell_id`,
`lon_center`, `lat_center`, `resolution_arcmin`, `geometry`.

#### `generate_grid_for_boundary(resolution_arcmin, boundary)`
Generates the bounding-box grid for a boundary's extent, then filters
to cells that actually intersect the boundary (so coastline/ocean
cells outside the region aren't materialized). `boundary` is any
`sf`/`sfc` polygon or multipolygon in WGS84 (EPSG:4326).

### Naming conventions

#### `grid_table_name(resolution_arcmin)`
Returns the standardized table name for a resolution, e.g.
`grid_table_name(15)` → `"cells_15_arcmin"`. This is the single source
of truth for naming — all other functions call this rather than
reimplementing the logic.

#### `hierarchy_table_name(fine_arcmin, coarse_arcmin)`
Returns the standardized name for a fine-to-coarse hierarchy table,
e.g. `hierarchy_table_name(0.5, 15)` → `"cell_hierarchy_0_5_to_15_arcmin"`.

### Database I/O

#### `get_db_connection()`
Returns a `DBI` connection built from the `.Renviron` environment
variables described above. Errors with a clear message listing any
missing variables.

#### `write_grid_to_postgis(con, grid_sf)`
Writes an `sf` grid object (from `generate_grid_bbox()` or
`generate_grid_for_boundary()`) to its resolution's table, creating the
table and indexes on first use. Subsequent calls append new cells;
existing `cell_id`s are never overwritten (`ON CONFLICT DO NOTHING`).

#### `populate_grid_for_boundary(con, resolution_arcmin, boundary)`
Convenience wrapper: generates and writes a grid for a boundary in one
call.

### Administrative boundaries

#### `update_admin_boundaries(con, boundaries, admin_level, resolution_arcmin, source = NA)`
Joins a boundary `sf` object (any source — geoBoundaries, GADM,
customer-drawn regions) against an existing grid table using
geometric intersection (`ST_Intersects`), and inserts the resulting
`(cell_id, admin_level, admin_id)` rows into `masks.cell_admin`.
`boundaries` must have columns `admin_id`, `admin_name`, and
`geometry`; `parent_id` is optional (added as `NA` if missing).

**Note**: assignment uses intersection, not centroid containment, so
a cell touching two adjacent admin units will be assigned to both.
This avoids silently excluding cells that genuinely overlap a region
but whose centroid falls just outside it (a real problem observed
when validating against actual district boundaries — see
`PROCESS_NARRATIVE.md` section 11). The consequence is that summing
or aggregating across multiple admin-unit queries requires
deduplicating by `cell_id` first to avoid double-counting boundary
cells; a query for a single admin unit is unaffected.

#### `resolve_admin_id(con, admin_level, admin_name)`
Looks up the `admin_id` for a human-readable `admin_name` within a
given `admin_level` (case-insensitive). Errors if zero or multiple
matches are found.

### Crop masks

#### `update_crop_mask(con, raster_path, resolution_arcmin, crop = "cropland", mask_source, mask_year = NA, crop_class_values, admin_level = NULL, admin_id = NULL)`
Aggregates a crop mask raster onto an existing grid table, computing
the area-weighted fraction of each cell classified as cropland (or a
specific crop, per `crop_class_values` — the raster value(s)
corresponding to cropland in that raster's legend). Writes/upserts into
`masks.crop_presence`. Optionally restrict to cells within a given
admin unit (via `admin_level`/`admin_id`) to avoid processing more of
a global raster than necessary.

### Cell hierarchy

#### `build_cell_hierarchy(con, fine_arcmin, coarse_arcmin)`
Computes, once, which coarse cell each fine cell's centroid falls
within, and stores the result as a lookup table
(`grids.cell_hierarchy_<fine>_to_<coarse>_arcmin`). This is what
enables fast aggregation of fine-resolution results up to a coarser
level without repeated geometry operations.

### Querying

#### `get_simulation_cells(con, resolution_arcmin, admin_level, admin_id = NULL, admin_name = NULL, crop = "cropland", min_frac_area = 0.05, mask_source = NULL)`
The primary entry point. Returns simulation-ready cells for a given
administrative unit, optionally filtered by minimum crop area
fraction. Provide exactly one of `admin_id` or `admin_name`. Returns
an `sf` object with `cell_id`, `lon_center`, `lat_center`, `geometry`,
and `frac_area`.

Set `crop = NULL` (or `min_frac_area = NULL`) to skip the crop mask
join entirely and return all cells in the admin unit regardless of
crop presence.

If multiple `mask_source` versions exist for the same crop, specify
`mask_source` explicitly — otherwise the query will return duplicate
rows per cell (one per source).

#### `get_simulation_cells_multi(con, resolution_arcmin, admin_level, parent_level = NULL, parent_ids = NULL, parent_names = NULL, admin_ids = NULL, admin_names = NULL, expand_near_matches = FALSE, crop = "cropland", min_frac_area = 0.05, mask_source = NULL)`
Combines cells across multiple admin units, deduplicating boundary
cells that intersect more than one of the requested units. Two
selection modes, mutually exclusive per call:
- **Parent-based**: `parent_level` + `parent_ids`/`parent_names` (e.g.
  pull every ADM2 district within one or more ADM1 oblasts, without
  enumerating districts by hand).
- **Direct-unit**: `admin_ids`/`admin_names` at `admin_level` directly
  (e.g. a specific handful of districts for small-area testing).

Set `expand_near_matches = TRUE` to automatically also include any
other unit at the same level whose name partially matches a requested
unit's name (handles the city/region naming collision pattern, e.g.
"Almaty" the city vs. "Almaty Region" the oblast — see
`PROCESS_NARRATIVE.md`). A message lists any units added this way.

Returns an `sf` object with an added `n_admin_matches` column showing
how many resolved admin units each cell intersected.

#### `attach_admin_names(con, cells, admin_level)`
Looks up each cell's `admin_name` at a given admin level and attaches
it as a column — used to build a per-cell `reporting_unit` vector for
`export_cells_to_legacy_geojson()`. If a cell matches more than one
unit at that level (a boundary cell), the first match by `admin_id` is
used and a warning lists the affected cells, since a single label can
only record one name per feature. See `export_admin_lookup()` below
for an alternative that preserves every match instead of picking one.

#### `attach_admin_hierarchy(con, cells, admin_levels, sep = "_")`
Like `attach_admin_names()`, but looks up multiple levels at once
(e.g. `c("ADM0", "ADM1", "ADM2")`) and combines them into one
sanitized path string (e.g. `"Kazakhstan_AlmatyRegion_Talgar"`) in a
new `admin_path` column, plus one column per level (e.g.
`ADM1_name`) for inspection. Same boundary-cell caveat as
`attach_admin_names()` applies independently at each level.

#### `export_cells_to_legacy_geojson(cells, reporting_unit = "griddb_export", clip_boundary = NULL, output_path = NULL, area_crs = NULL)`
Produces a GeoJSON FeatureCollection: one Feature per cell, MultiPolygon
geometry, with properties `name`, `cell_id`, `area` (square meters),
and `reporting_unit` — **always present by default**. This matches the
legacy DSSAT-pipeline delivery format that the existing CLI/run tool
reads directly: it populates its own `polygon_name`/`polygon_area`
output columns from `name`/`area`, and those come out empty if the
input file is missing those properties — so they cannot be made
optional without breaking that tool.

`cell_id` is **always** present as its own separate property
regardless of what `reporting_unit` is set to — the cell's own stable,
globally-meaningful identifier, permanent even if admin boundaries are
later re-ingested or renamed. `name` is set directly from
`reporting_unit` and is cosmetic/display-only; anything needing to
reliably re-identify a cell later should key off `cell_id`, never
`name`.

`reporting_unit` accepts a single string (applied to every feature),
a vector with one value per cell (e.g. via `attach_admin_names()` or
`attach_admin_hierarchy()` for a combined multi-district export), or
can be omitted entirely, in which case it defaults to the placeholder
`"griddb_export"` so the required columns are still populated even
when no meaningful label is available yet.

For administrative context that doesn't need to be squeezed into a
single cosmetic label, see `export_admin_lookup()` below — a companion
file/table that preserves every admin match per cell (including
ambiguous boundary cells) for joining on `cell_id` separately.

By default, cells are exported whole (no geometric clipping) — a cell
is included if it was returned by the query, full stop. Pass
`clip_boundary` (an sf/sfc polygon) to perform true edge-clipping via
`st_intersection()` if exact-boundary-matching output is required for
a specific delivery; note that clipping can split a single cell into
multiple fragments sharing the same `cell_id`, so prefer no clipping
when `cell_id` needs to uniquely identify a feature.

#### `export_admin_lookup(con, cells, admin_levels, output_path = NULL)`
Writes a CSV (or returns a data frame) mapping each `cell_id` to its
`admin_id`/`admin_name`/`parent_id` at one or more admin levels.
Unlike `attach_admin_names()`/`attach_admin_hierarchy()`, this
preserves **every** match for a cell at a given level — a boundary
cell that intersects two districts simply gets two rows — rather than
arbitrarily picking one. Intended as a companion file to a
`cell_id`-only spatial export: join on `cell_id` to recover whatever
administrative context is needed, with no information lost or
silently collapsed for ambiguous boundary cells.

#### `get_nearest_cell(con, resolution_arcmin, lon = NULL, lat = NULL, points = NULL, crop = "cropland", min_frac_area = NULL, mask_source = NULL)`
For point/field-level consumers (a specific farm location, a single
lat/lon, or a small field polygon) rather than regional/aggregate
queries. Returns the grid cell that contains the point, computed
directly via `compute_global_cell_id()` rather than a spatial
nearest-neighbor search — since the grid is fixed and known, the
containing cell is computable exactly from the coordinates alone.

This deliberately does not reshape cell geometry around the point,
consistent with standard practice in this modeling tradition
(DSSAT/pSIMS/AgMIP): a cell is treated as a representative sample for
its whole area, and a small field within it is simply assigned that
cell's value — see "Two delivery modes" below.

Accepts either `lon`/`lat` vectors (one or many points at once) or an
sf `points` object (POINT/MULTIPOINT used directly; POLYGON uses its
centroid). Returns one row per input point, in the original order,
with `query_lon`/`query_lat` carried through for reference. Warns
(rather than erroring) if a point has no match, e.g. because a crop
mask filter excluded its cell.

## Two delivery modes

Looking back at the system as a whole, there are two distinct ways
results get delivered, matching two different kinds of consumer:

- **Regional/aggregate** — a customer or analysis wants production
  totals or averages across an administrative area. Deliver whole-cell
  polygons, yields, and `frac_area`; let the consumer area-weight and
  sum as needed (the standard pSIMS/AgMIP aggregation pattern: `P = Σ
  Y(x,t) * W(x,t)`, where `W` is the cropland-area weight). This is
  what `export_cells_to_legacy_geojson()`/`export_admin_lookup()` are
  for.
- **Point/field-level** — a customer has a specific farm or field and
  wants its expected yield. There is no area-weighting or geometry
  reshaping involved; the answer is simply "which cell's value applies
  here", which `get_nearest_cell()` answers directly.

Grid cells are never carved or reshaped to match cropland boundaries
within a cell in either mode — that would reintroduce the
point-in-polygon overhead this whole system was designed to eliminate
(see `PROCESS_NARRATIVE.md`). `frac_area` is used only as an
aggregation weight (regional mode) or a presence filter (both modes
via `min_frac_area`), never to alter geometry.

## Usage example: end-to-end for one country

```r
library(griddb)
library(sf)

con <- get_db_connection()

# 1. Load a country boundary (e.g. from geoBoundaries) and generate/write its grid
kaz_boundary <- st_read("kazakhstan_adm0.gpkg")
populate_grid_for_boundary(con, resolution_arcmin = 15, boundary = kaz_boundary)

# 2. Load and ingest ADM1 boundaries
adm1 <- st_read("kazakhstan_adm1.gpkg") |>
  dplyr::rename(admin_id = shapeID, admin_name = shapeName)
update_admin_boundaries(con, adm1, admin_level = "ADM1",
                         resolution_arcmin = 15, source = "geoBoundaries")

# Don't forget ADM0 too, if you want country-level queries
adm0 <- kaz_boundary |> dplyr::mutate(admin_id = "KAZ", admin_name = "Kazakhstan")
update_admin_boundaries(con, adm0, admin_level = "ADM0",
                         resolution_arcmin = 15, source = "geoBoundaries")

# 3. Ingest a generic cropland mask
update_crop_mask(con, raster_path = "esa_worldcover_kaz.tif",
                  resolution_arcmin = 15, mask_source = "ESA_WorldCover_2021",
                  crop_class_values = 40)  # 40 = cropland in ESA WorldCover's legend

# 4. Query
akmola_cells <- get_simulation_cells(con, resolution_arcmin = 15,
                                      admin_level = "ADM1", admin_name = "Akmola")

# Area-weighted aggregation example, once simulation results exist:
# weighted_mean_yield <- sum(results$yield * akmola_cells$frac_area) /
#                          sum(akmola_cells$frac_area)
```

## Testing

```r
devtools::test()
```

Currently included tests cover:
- `grid_table_name()` / `hierarchy_table_name()` naming consistency
  and input validation (no database required)
- `compute_global_cell_id()` determinism, ordering, and vectorization
  (no database required)
- `generate_grid_bbox()` cell ID/geometry consistency, and — critically
  — that regenerating a grid or generating a *larger* bounding box
  produces **identical cell_ids** for any cells in common with a prior,
  smaller generation. This is the test of the core stability guarantee
  the whole system depends on.

Database-dependent integration tests (ingestion functions, the full
query path) are not yet included and should be added once a stable
test database is available; they should use `skip_if_no_test_db()` (or
equivalent) so the suite still runs cleanly without a live connection.

## Known limitations / open items

- **Boundary cells can belong to multiple admin units.** Since
  `update_admin_boundaries()` uses `ST_Intersects` rather than
  centroid containment, a cell straddling the border between two
  adjacent regions will appear in both regions' query results. This
  was a deliberate tradeoff to avoid silently excluding real area at
  region edges (see `PROCESS_NARRATIVE.md` section 11). Aggregating
  across multiple admin-unit queries requires deduplicating by
  `cell_id` first.
- **Crop-specific masking** is schema-ready (the `crop` column exists)
  but not yet exercised — current usage is a single generic
  `crop = "cropland"` mask. No migration will be needed to add
  crop-specific masks later.
- **Admin name matching** uses simple `ILIKE` — does not yet handle
  transliteration variants or aliases (relevant for non-Latin-script
  country subdivisions; observed in practice with Kazakhstan ADM2
  names like Balkhash/Balkash/Balqash, and with duplicate city/district
  name pairs like "Aksu" vs "Aksu District"). An `admin_name_alt`
  array column is a reasonable future addition if this becomes a
  recurring problem.
- **Boundary source**: geoBoundaries is recommended over GADM for
  commercial use due to licensing (GADM restricts commercial use;
  geoBoundaries is CC BY). Verify current license terms before relying
  on either, since terms can change. The ingestion function is
  source-agnostic, so switching sources requires no code changes
  beyond preparing the input `sf` object with the expected columns.
- **No pixel-perfect edge matching** against hand-clipped legacy
  boundaries. Whole, uncut cells are included if they intersect a
  region at all, which means coverage extends slightly past a true
  boundary in places where it cuts through a cell's middle. Exact
  edge matching is available only via `clip_boundary` in
  `export_cells_to_legacy_geojson()`, performed at export time.
- **Materialized caching** for frequently-queried admin units (e.g. a
  recurring seasonal run for the same country) is not implemented.
  Not needed at current scale — the integer-key join is already cheap
  — but worth revisiting if query latency becomes a problem once usage
  grows.
- **Full global pre-generation** is intentionally not implemented.
  Cells are materialized lazily per region via
  `generate_grid_for_boundary()`. The global ID formula guarantees this
  doesn't sacrifice cross-region comparability if/when broader
  coverage is needed later.
