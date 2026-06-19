# Verification test for update_crop_mask(raster_type = "percent_area").
#
# Builds a tiny synthetic percent-cropland raster with KNOWN values,
# runs it through update_crop_mask(), and manually computes the
# expected frac_area by hand so we can confirm the function's math is
# actually correct -- not just "it ran without erroring."
#
# Run this block by block, inspecting each step.

library(griddb)
library(sf)
library(terra)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Reuse the same 2deg x 2deg synthetic boundary/grid from the
#    earlier smoke test (regenerate if not already in session)
# ---------------------------------------------------------------------
if (!exists("synthetic_boundary")) {
  synthetic_boundary <- st_sf(
    admin_id = "SYN",
    geometry = st_sfc(
      st_polygon(list(matrix(c(
        10, 10,
        12, 10,
        12, 12,
        10, 12,
        10, 10
      ), ncol = 2, byrow = TRUE))),
      crs = 4326
    )
  )
}

res <- 30  # 30 arcmin = 0.5 deg cells, same as before -- 16 cells total

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

# ---------------------------------------------------------------------
# 2. Build a tiny synthetic percent-cropland raster with KNOWN values.
#    Use a native resolution finer than the grid (e.g. 0.1 deg, so each
#    0.5deg grid cell contains 5x5 = 25 native pixels) and set every
#    pixel to a KNOWN constant percent, so the expected frac_area is
#    trivial to compute by hand: it should equal exactly that percent
#    / 100, regardless of cell area (since percent is constant
#    everywhere, the area-weighted fraction must equal that same
#    percent).
# ---------------------------------------------------------------------
known_percent <- 40  # 40% cropland everywhere, by construction

synthetic_raster <- rast(
  xmin = 10, xmax = 12, ymin = 10, ymax = 12,
  resolution = 0.1,
  crs = "EPSG:4326"
)
values(synthetic_raster) <- known_percent

raster_path <- tempfile(fileext = ".tif")
writeRaster(synthetic_raster, raster_path, overwrite = TRUE)

# ---------------------------------------------------------------------
# 3. Run update_crop_mask() with raster_type = "percent_area"
# ---------------------------------------------------------------------
update_crop_mask(
  con,
  raster_path = raster_path,
  resolution_arcmin = res,
  mask_source = "synthetic_percent_test",
  raster_type = "percent_area"
)

# ---------------------------------------------------------------------
# 4. Verify: every cell's frac_area should be (known_percent / 100),
#    i.e. 0.40, regardless of cell area, since the percent is constant
#    everywhere in the synthetic raster.
# ---------------------------------------------------------------------
result <- dbGetQuery(con, "
  SELECT cell_id, frac_area FROM masks.crop_presence
  WHERE mask_source = 'synthetic_percent_test'
  ORDER BY cell_id;
")
print(result)

expected <- known_percent / 100
max_error <- max(abs(result$frac_area - expected))
cat("Expected frac_area:", expected, "\n")
cat("Max absolute error across all cells:", max_error, "\n")

if (max_error < 0.01) {
  cat(">>> PASS: frac_area matches expected value within tolerance.\n")
} else {
  cat(">>> FAIL: frac_area does not match expected value -- check the function logic.\n")
}

# ---------------------------------------------------------------------
# 5. A second check with a NON-constant pattern, to catch bugs that
#    only the constant-value test above would miss (e.g. an
#    accidental mean-instead-of-sum, or an area-weighting error that
#    happens to cancel out when the input is uniform).
#
#    Set the left half of the raster to 100% and the right half to 0%.
#    Each 0.5deg grid cell straddles the boundary identically (since
#    cells are 0.5deg wide and the raster's left/right split is also
#    at the midpoint of the bbox), so every cell should end up with
#    frac_area = 0.5 if the split lands exactly on a cell boundary --
#    adjust expectation based on where 11.0 (the midpoint) falls
#    relative to the 0.5deg grid lines.
# ---------------------------------------------------------------------
split_values <- known_percent  # reset, just being explicit
synthetic_raster2 <- rast(
  xmin = 10, xmax = 12, ymin = 10, ymax = 12,
  resolution = 0.1,
  crs = "EPSG:4326"
)
# Left half (lon < 11) = 100%, right half (lon >= 11) = 0%
xy <- xyFromCell(synthetic_raster2, seq_len(ncell(synthetic_raster2)))
values(synthetic_raster2) <- ifelse(xy[, "x"] < 11, 100, 0)

raster_path2 <- tempfile(fileext = ".tif")
writeRaster(synthetic_raster2, raster_path2, overwrite = TRUE)

update_crop_mask(
  con,
  raster_path = raster_path2,
  resolution_arcmin = res,
  mask_source = "synthetic_percent_test_split",
  raster_type = "percent_area"
)

result2 <- dbGetQuery(con, "
  SELECT c.cell_id, c.lon_center, m.frac_area
  FROM grids.cells_30_arcmin c
  JOIN masks.crop_presence m ON c.cell_id = m.cell_id
  WHERE m.mask_source = 'synthetic_percent_test_split'
  ORDER BY c.cell_id;
")
print(result2)
# Expect: cells with lon_center < 11 -> frac_area ~1.0
#         cells with lon_center > 11 -> frac_area ~0.0
# (the grid lines at 10, 10.5, 11, 11.5, 12 mean no cell straddles 11
#  exactly, so this should be a clean split, not a 0.5 case)

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
# dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
# dbExecute(con, "DELETE FROM masks.crop_presence WHERE mask_source IN ('synthetic_percent_test', 'synthetic_percent_test_split');")

dbDisconnect(con)
