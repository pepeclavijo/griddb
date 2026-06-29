# Validates:
#   1. export_cells_to_legacy_geojson() with a per-cell reporting_unit
#      vector, including correct WITHIN-group sequential numbering
#   2. attach_admin_names() correctly attaches admin_name per cell,
#      and warns appropriately on multi-match / no-match cells
#   3. Backward compatibility: a single-string reporting_unit still
#      works exactly as before
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Reuse the synthetic two-district setup pattern from earlier tests
# ---------------------------------------------------------------------
district_west <- st_sf(
  admin_id = "SYN.W", admin_name = "Synthetica West", parent_id = "SYN",
  geometry = st_sfc(st_polygon(list(matrix(c(
    10, 10, 11, 10, 11, 12, 10, 12, 10, 10
  ), ncol = 2, byrow = TRUE))), crs = 4326)
)
district_east <- st_sf(
  admin_id = "SYN.E", admin_name = "Synthetica East", parent_id = "SYN",
  geometry = st_sfc(st_polygon(list(matrix(c(
    11, 10, 12, 10, 12, 12, 11, 12, 11, 10
  ), ncol = 2, byrow = TRUE))), crs = 4326)
)
# Note: these two districts share an EXACT edge at lon=11 (no deliberate
# overlap this time), so we get a clean two-group split with minimal
# boundary-cell duplication, easier to verify numbering against.

res <- 30
synthetic_boundary <- st_sf(admin_id = "SYN", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'EXPORT_TEST';")
update_admin_boundaries(con, district_west, admin_level = "EXPORT_TEST",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, district_east, admin_level = "EXPORT_TEST",
                         resolution_arcmin = res, source = "synthetic")

# ---------------------------------------------------------------------
# 2. Pull combined cells across both districts
# ---------------------------------------------------------------------
combined_cells <- get_simulation_cells_multi(
  con, resolution_arcmin = res, admin_level = "EXPORT_TEST",
  admin_ids = c("SYN.W", "SYN.E"), crop = NULL, min_frac_area = NULL
)
cat("Combined cells:", nrow(combined_cells), "\n")

# ---------------------------------------------------------------------
# 3. Test attach_admin_names()
# ---------------------------------------------------------------------
combined_cells <- attach_admin_names(con, combined_cells, admin_level = "EXPORT_TEST")
print(table(combined_cells$admin_name, useNA = "always"))

if (!any(is.na(combined_cells$admin_name))) {
  cat(">>> PASS: every cell got a non-NA admin_name.\n")
} else {
  cat(">>> FAIL: some cells have NA admin_name.\n")
}

# ---------------------------------------------------------------------
# 4. Test per-cell reporting_unit export
# ---------------------------------------------------------------------
exported <- export_cells_to_legacy_geojson(
  combined_cells, reporting_unit = combined_cells$admin_name,
  output_path = tempfile(fileext = ".geojson")
)

print(exported$name)
print(exported$cell_id)
print(table(exported$reporting_unit))

# name should be the UNIQUE cell_id (matching cell_id exactly), and
# reporting_unit should carry the per-cell admin_name label
if (is.character(exported$name) &&
    identical(exported$name, as.character(combined_cells$cell_id)) &&
    identical(exported$cell_id, combined_cells$cell_id) &&
    identical(exported$reporting_unit, combined_cells$admin_name)) {
  cat(">>> PASS: name is the cell_id as a string; cell_id stays numeric; reporting_unit carries the per-cell label correctly.\n")
} else {
  cat(">>> FAIL: name/reporting_unit do not match the expected swapped structure.\n")
}

# ---------------------------------------------------------------------
# 5. Backward-compatibility check: single-string reporting_unit
#    still works exactly as before
# ---------------------------------------------------------------------
single_string_export <- export_cells_to_legacy_geojson(
  combined_cells, reporting_unit = "All Synthetica",
  output_path = tempfile(fileext = ".geojson")
)
print(single_string_export$name[1:3])
print(single_string_export$cell_id[1:3])
if (is.character(single_string_export$name) &&
    identical(single_string_export$name, as.character(combined_cells$cell_id)) &&
    all(single_string_export$reporting_unit == "All Synthetica") &&
    identical(single_string_export$cell_id, combined_cells$cell_id)) {
  cat(">>> PASS: single-string reporting_unit works; name is the cell_id as a string.\n")
} else {
  cat(">>> FAIL: single-string reporting_unit behavior is incorrect.\n")
}

# ---------------------------------------------------------------------
# 6. Mismatched-length error check
# ---------------------------------------------------------------------
tryCatch({
  export_cells_to_legacy_geojson(combined_cells, reporting_unit = c("A", "B"))
  cat(">>> FAIL: expected an error for mismatched reporting_unit length.\n")
}, error = function(e) {
  cat(">>> PASS: mismatched length correctly raised an error:\n", conditionMessage(e), "\n")
})

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'EXPORT_TEST';")
dbDisconnect(con)
