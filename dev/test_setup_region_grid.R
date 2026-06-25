# Validates setup_region_grid() end-to-end using a small synthetic
# shapefile written to a temp directory -- exercises the full
# load/filter/clean/generate/ingest sequence in one call, the same way
# it would be used against a real Kazakhstan ADM1 file.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Write a small synthetic "ADM1-like" shapefile with two regions
#
# NOTE: shapefiles truncate field names to 10 characters (a legacy
# .dbf format constraint), so REGION_NAME -> REGION_N, REGION_ID ->
# REGION_I, COUNTRY_ID -> COUNTRY after the write/read round-trip.
# Using already-short names here to avoid the truncation surprise
# (real-world files like the Kazakhstan ADM1 shapefile already use
# short names like ADM1_EN, ADM1_PCODE for this same reason).
# ---------------------------------------------------------------------
synthetic_regions <- st_sf(
  RGN_NAME = c("Testistan North", "Testistan South"),
  RGN_ID    = c("TST.1", "TST.2"),
  CTRY_ID   = c("TST", "TST"),
  geometry = st_sfc(
    st_polygon(list(matrix(c(10, 11, 12, 11, 12, 12, 10, 12, 10, 11), ncol = 2, byrow = TRUE))),
    st_polygon(list(matrix(c(10, 10, 12, 10, 12, 11, 10, 11, 10, 10), ncol = 2, byrow = TRUE))),
    crs = 4326
  )
)

tmp_dir <- tempfile()
dir.create(tmp_dir)
shp_path <- file.path(tmp_dir, "synthetic_adm1.shp")
st_write(synthetic_regions, shp_path, quiet = TRUE)

# Confirm what the column names actually survived as, before using them
print(names(st_read(shp_path, quiet = TRUE)))

# ---------------------------------------------------------------------
# 2. Test the "show available values" mode (region_name = NULL)
# ---------------------------------------------------------------------
setup_region_grid(con, boundary_path = shp_path, name_col = "RGN_NAME",
                   region_name = NULL, resolution_arcmin = 30,
                   admin_level = "TEST_ADM1", id_col = "RGN_ID")
# Should print both region names, no database changes made

# ---------------------------------------------------------------------
# 3. The real test: set up the grid + admin entry for one region
# ---------------------------------------------------------------------
result <- setup_region_grid(
  con, boundary_path = shp_path, name_col = "RGN_NAME",
  region_name = "Testistan North", resolution_arcmin = 30,
  admin_level = "TEST_ADM1", id_col = "RGN_ID", parent_id_col = "CTRY_ID",
  source = "synthetic"
)

cat("Resolved admin_id:", result$admin_id, "\n")
cat("Grid table written to:", result$grid_table, "\n")

# ---------------------------------------------------------------------
# 4. Verify the grid and admin entry actually exist in the database
# ---------------------------------------------------------------------
cell_count <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM grids.%s;", result$grid_table
))
cat("Cells in grid table:", cell_count$n, "\n")

admin_count <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM masks.cell_admin
  WHERE admin_level = 'TEST_ADM1' AND admin_id = '%s';
", result$admin_id))
cat("Cells assigned to admin_id '", result$admin_id, "': ", admin_count$n, "\n", sep = "")

if (admin_count$n > 0) {
  cat(">>> PASS: setup_region_grid() correctly generated cells and ingested admin boundary.\n")
} else {
  cat(">>> FAIL: no cells were assigned to the region.\n")
}

# Confirm querying via get_simulation_cells() works downstream, using
# the same id resolved by setup_region_grid()
queried_cells <- get_simulation_cells(con, resolution_arcmin = 30,
                                       admin_level = "TEST_ADM1",
                                       admin_id = result$admin_id,
                                       crop = NULL, min_frac_area = NULL)
cat("get_simulation_cells() returned:", nrow(queried_cells), "cells\n")

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", result$grid_table))
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'TEST_ADM1';")
unlink(tmp_dir, recursive = TRUE)
dbDisconnect(con)
