# Validates get_nearest_cell() for the point/field-level lookup use
# case: given a lat/lon (or small polygon), return the cell that
# contains it, via direct computation rather than a spatial search.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Reuse the small synthetic grid setup pattern
# ---------------------------------------------------------------------
res <- 30  # 0.5 deg cells
synthetic_boundary <- st_sf(admin_id = "SYN", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

# A fake crop mask: alternating high/low frac_area by hand, so we can
# verify the crop filter behaves correctly
all_cells <- get_simulation_cells(con, resolution_arcmin = res,
                                   admin_level = "NONEXISTENT_LEVEL",
                                   admin_id = "NONE", crop = NULL, min_frac_area = NULL)
# (the above will warn/return 0 rows since there's no admin entry yet --
#  instead, just read the grid table directly for this synthetic test)
all_cells <- st_read(con, query = sprintf("SELECT * FROM grids.%s;", grid_table))

dbExecute(con, "DELETE FROM masks.crop_presence WHERE mask_source = 'nearest_cell_test';")
fake_crop <- data.frame(
  cell_id = all_cells$cell_id,
  crop = "cropland",
  frac_area = rep(c(0.8, 0.02), length.out = nrow(all_cells)),
  mask_source = "nearest_cell_test",
  mask_year = 2024
)
dbWriteTable(con, DBI::Id(schema = "staging", table = "tmp_fake_crop2"), fake_crop, overwrite = TRUE)
dbExecute(con, "
  INSERT INTO masks.crop_presence (cell_id, crop, frac_area, mask_source, mask_year)
  SELECT cell_id, crop, frac_area, mask_source, mask_year FROM staging.tmp_fake_crop2
  ON CONFLICT (cell_id, crop, mask_source) DO UPDATE SET frac_area = EXCLUDED.frac_area;
")
dbExecute(con, "DROP TABLE IF EXISTS staging.tmp_fake_crop2;")

# ---------------------------------------------------------------------
# 2. Single point lookup, no crop filter
# ---------------------------------------------------------------------
single_result <- get_nearest_cell(con, resolution_arcmin = res,
                                   lon = 10.6, lat = 11.3, crop = NULL)
print(single_result)

expected_cell_id <- compute_global_cell_id(10.6, 11.3, res)
if (nrow(single_result) == 1 && single_result$cell_id == expected_cell_id) {
  cat(">>> PASS: single point correctly matched to its containing cell.\n")
} else {
  cat(">>> FAIL: single point lookup did not match the expected cell.\n")
}

# Confirm the point actually falls within the returned cell's geometry
point_sf <- st_sfc(st_point(c(10.6, 11.3)), crs = 4326)
if (isTRUE(st_within(point_sf, single_result, sparse = FALSE)[1, 1])) {
  cat(">>> PASS: the query point genuinely falls within the returned cell's geometry.\n")
} else {
  cat(">>> FAIL: the query point does NOT fall within the returned cell's geometry.\n")
}

# ---------------------------------------------------------------------
# 3. Multiple points at once, preserving order and length
# ---------------------------------------------------------------------
multi_result <- get_nearest_cell(con, resolution_arcmin = res,
                                  lon = c(10.2, 11.7, 10.6),
                                  lat = c(10.3, 11.9, 11.3),
                                  crop = NULL)
print(multi_result[, c("cell_id", "query_lon", "query_lat")])

expected_ids <- compute_global_cell_id(c(10.2, 11.7, 10.6), c(10.3, 11.9, 11.3), res)
if (nrow(multi_result) == 3 && identical(multi_result$cell_id, expected_ids)) {
  cat(">>> PASS: multiple points correctly matched, in original order.\n")
} else {
  cat(">>> FAIL: multi-point lookup did not preserve order/match expected cells.\n")
}

# ---------------------------------------------------------------------
# 4. Polygon input -- centroid should be used
# ---------------------------------------------------------------------
small_field <- st_sf(geometry = st_sfc(
  st_polygon(list(matrix(c(
    10.55, 11.25, 10.65, 11.25, 10.65, 11.35, 10.55, 11.35, 10.55, 11.25
  ), ncol = 2, byrow = TRUE))),
  crs = 4326
))
field_centroid <- st_coordinates(st_centroid(small_field))
expected_field_cell <- compute_global_cell_id(field_centroid[1, "X"], field_centroid[1, "Y"], res)

polygon_result <- get_nearest_cell(con, resolution_arcmin = res, points = small_field, crop = NULL)
if (nrow(polygon_result) == 1 && polygon_result$cell_id == expected_field_cell) {
  cat(">>> PASS: polygon input correctly used its centroid for the lookup.\n")
} else {
  cat(">>> FAIL: polygon centroid lookup did not match the expected cell.\n")
}

# ---------------------------------------------------------------------
# 5. Crop filter: a point landing on a HIGH frac_area cell should
#    pass min_frac_area = 0.5; a point on a LOW frac_area cell should
#    return 0 rows (with a warning) under the same filter.
# ---------------------------------------------------------------------
high_frac_cells <- all_cells$cell_id[seq(1, nrow(all_cells), by = 2)]  # matches the 0.8 pattern above
low_frac_cells <- all_cells$cell_id[seq(2, nrow(all_cells), by = 2)]   # matches the 0.02 pattern above

high_cell_centroid <- all_cells[all_cells$cell_id == high_frac_cells[1], c("lon_center", "lat_center")]
low_cell_centroid <- all_cells[all_cells$cell_id == low_frac_cells[1], c("lon_center", "lat_center")]

cat("\nTesting a point in a high-cropland cell, with min_frac_area = 0.5:\n")
high_result <- get_nearest_cell(con, resolution_arcmin = res,
                                 lon = high_cell_centroid$lon_center,
                                 lat = high_cell_centroid$lat_center,
                                 crop = "cropland", min_frac_area = 0.5,
                                 mask_source = "nearest_cell_test")
print(nrow(high_result))
if (nrow(high_result) == 1) {
  cat(">>> PASS: high-cropland cell correctly returned under the threshold filter.\n")
} else {
  cat(">>> FAIL: expected 1 row for the high-cropland cell.\n")
}

cat("\nTesting a point in a low-cropland cell, with min_frac_area = 0.5 (expect 0 rows + warning):\n")
low_result <- get_nearest_cell(con, resolution_arcmin = res,
                                lon = low_cell_centroid$lon_center,
                                lat = low_cell_centroid$lat_center,
                                crop = "cropland", min_frac_area = 0.5,
                                mask_source = "nearest_cell_test")
print(nrow(low_result))
if (nrow(low_result) == 0) {
  cat(">>> PASS: low-cropland cell correctly excluded by the threshold filter.\n")
} else {
  cat(">>> FAIL: expected 0 rows for the low-cropland cell under this filter.\n")
}

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
dbExecute(con, "DELETE FROM masks.crop_presence WHERE mask_source = 'nearest_cell_test';")
dbDisconnect(con)
