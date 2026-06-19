# griddb

Standardized global grid system for crop simulation. Provides stable,
globally-consistent grid cells as spatial simulation units, with
supporting lookups for administrative boundaries and crop presence
masks, backed by PostGIS.

## Setup

### 1. Database

This package expects a PostGIS-enabled Postgres database (e.g. a free
Supabase project). Connection parameters are read from environment
variables -- set these in a **project-level** `.Renviron` (never commit
this file):

```
SUPABASE_DB_HOST=aws-0-<region>.pooler.supabase.com
SUPABASE_DB_PORT=5432
SUPABASE_DB_NAME=postgres
SUPABASE_DB_USER=postgres.<project-ref>
SUPABASE_DB_PASSWORD=<your-password>
```

Create/edit this file via:
```r
usethis::edit_r_environ(scope = "project")
```
Restart R after editing for the variables to take effect.

### 2. Schema

Run `inst/sql/schema.sql` once against your database (e.g. via the
Supabase SQL Editor, or `DBI::dbExecute()` for each statement) to
create the `grids`, `masks`, and `staging` schemas and the
`masks.cell_admin` / `masks.crop_presence` tables. Grid resolution
tables themselves are created on demand by `write_grid_to_postgis()`.

### 3. Install the package

```r
devtools::install()
# or, for development:
devtools::load_all()
```

## Core workflow

```r
library(griddb)

con <- get_db_connection()

# 1. Generate and write a grid for a country boundary
kaz_boundary <- sf::st_read("path/to/kazakhstan_boundary.gpkg")
populate_grid_for_boundary(con, resolution_arcmin = 15, boundary = kaz_boundary)

# 2. Ingest administrative boundaries (ADM0, ADM1, ...)
adm1 <- sf::st_read("path/to/kaz_adm1.gpkg") |>
  dplyr::rename(admin_id = shapeID, admin_name = shapeName)
update_admin_boundaries(con, adm1, admin_level = "ADM1",
                         resolution_arcmin = 15, source = "geoBoundaries")

# 3. Ingest a crop mask
update_crop_mask(con, raster_path = "path/to/cropland_mask.tif",
                  resolution_arcmin = 15, mask_source = "ESA_WorldCover_2021",
                  crop_class_values = 40)  # check raster's legend for correct value(s)

# 4. Query simulation-ready cells
cells <- get_simulation_cells(con, resolution_arcmin = 15,
                               admin_level = "ADM1", admin_name = "Akmola")
```

## Design principles

- **Cell IDs are globally stable.** `compute_global_cell_id()` derives
  an ID from longitude, latitude, and resolution alone -- never from
  what currently exists in the database. Generating a grid for one
  country today and the rest of the world later produces identical IDs
  for the cells that overlap.
- **Admin boundaries and crop masks are independent of the grid and of
  each other.** Both are simple `cell_id`-keyed lookup tables. Updating
  a crop mask or redrawing a customer region never requires touching
  grid geometry or simulation results.
- **No live geometry intersection at query time.** `get_simulation_cells()`
  is a join on integer keys; all spatial computation happens once at
  ingestion time, not on every simulation request.

## Testing

```r
devtools::test()
```

Geometry/naming logic tests run without a database connection.
Database-dependent integration tests (not yet included in this initial
version) should be skipped automatically if no test database is
configured.
