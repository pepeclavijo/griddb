# Validates attach_admin_hierarchy() correctly builds a combined
# ADM0_ADM1_ADM2-style path per cell, and that export_cells_to_legacy_geojson()
# produces names like "Country_Region_District ; cell_id" when given
# that path as reporting_unit.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Small synthetic grid + a 3-level admin hierarchy: one country,
#    one region, two districts within it.
# ---------------------------------------------------------------------
res <- 30
synthetic_boundary <- st_sf(admin_id = "C1", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level IN ('HIER_ADM0', 'HIER_ADM1', 'HIER_ADM2');")

country <- st_sf(admin_id = "C1", admin_name = "Testlandia", parent_id = NA_character_,
                  geometry = st_geometry(synthetic_boundary))
region <- st_sf(admin_id = "R1", admin_name = "Test Region", parent_id = "C1",
                 geometry = st_geometry(synthetic_boundary))
district_west <- st_sf(admin_id = "D1", admin_name = "West District", parent_id = "R1",
                        geometry = st_sfc(st_polygon(list(matrix(c(
                          10, 10, 11, 10, 11, 12, 10, 12, 10, 10
                        ), ncol = 2, byrow = TRUE))), crs = 4326))
district_east <- st_sf(admin_id = "D2", admin_name = "East District", parent_id = "R1",
                        geometry = st_sfc(st_polygon(list(matrix(c(
                          11, 10, 12, 10, 12, 12, 11, 12, 11, 10
                        ), ncol = 2, byrow = TRUE))), crs = 4326))

update_admin_boundaries(con, country, admin_level = "HIER_ADM0",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, region, admin_level = "HIER_ADM1",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, district_west, admin_level = "HIER_ADM2",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, district_east, admin_level = "HIER_ADM2",
                         resolution_arcmin = res, source = "synthetic")

# ---------------------------------------------------------------------
# 2. Pull all cells (whole grid -- every cell is in Testlandia/Test Region)
# ---------------------------------------------------------------------
all_cells <- get_simulation_cells(con, resolution_arcmin = res,
                                   admin_level = "HIER_ADM0", admin_id = "C1",
                                   crop = NULL, min_frac_area = NULL)
cat("Total cells:", nrow(all_cells), "\n")

# ---------------------------------------------------------------------
# 3. Test attach_admin_hierarchy()
# ---------------------------------------------------------------------
all_cells <- attach_admin_hierarchy(con, all_cells,
                                     admin_levels = c("HIER_ADM0", "HIER_ADM1", "HIER_ADM2"))

print(head(all_cells[, c("cell_id", "HIER_ADM0_name", "HIER_ADM1_name",
                          "HIER_ADM2_name", "admin_path")]))

expected_paths <- unique(paste0("Testlandia_TestRegion_",
                                 c("WestDistrict", "EastDistrict")))
actual_paths <- unique(all_cells$admin_path)

if (all(actual_paths %in% expected_paths)) {
  cat(">>> PASS: admin_path correctly combines all three levels, sanitized.\n")
} else {
  cat(">>> FAIL: admin_path does not match expected combined values.\n")
  print(actual_paths)
}

# ---------------------------------------------------------------------
# 3b. Regression check for the sticky-geometry bug: sf's `[` subsetting
#     silently keeps the geometry column attached even when only name
#     columns are requested, which previously leaked mangled polygon
#     coordinate text into admin_path for some rows (e.g.
#     "...listc797925792579794275427543434275"). Confirm no admin_path
#     value contains anything resembling that pattern, and that every
#     value's length is sane relative to its component name lengths.
# ---------------------------------------------------------------------
suspicious <- grepl("list[a-z]?[0-9]{10,}", all_cells$admin_path)
if (!any(suspicious)) {
  cat(">>> PASS: no admin_path values show signs of leaked geometry text.\n")
} else {
  cat(">>> FAIL: found admin_path values with suspected leaked geometry:\n")
  print(all_cells$admin_path[suspicious])
}

expected_max_len <- max(nchar(paste0(
  gsub("[^A-Za-z0-9]", "", all_cells$HIER_ADM0_name),
  gsub("[^A-Za-z0-9]", "", all_cells$HIER_ADM1_name),
  gsub("[^A-Za-z0-9]", "", all_cells$HIER_ADM2_name),
  sep = "__"  # generous separator allowance, just bounding sanity not exactness
)))
if (all(nchar(all_cells$admin_path) <= expected_max_len + 10)) {
  cat(">>> PASS: admin_path lengths are consistent with just the three sanitized names (no extra data appended).\n")
} else {
  cat(">>> FAIL: some admin_path values are longer than expected -- possible leaked extra content.\n")
}

# ---------------------------------------------------------------------
# 4. Export using the combined path as reporting_unit, with cell_id naming
# ---------------------------------------------------------------------
exported <- export_cells_to_legacy_geojson(
  all_cells, reporting_unit = all_cells$admin_path,
  output_path = tempfile(fileext = ".geojson")
)

print(exported$name[1:5])
print(exported$cell_id[1:5])
print(exported$reporting_unit[1:5])

if (identical(exported$name, as.character(all_cells$cell_id)) &&
    identical(exported$cell_id, all_cells$cell_id) &&
    identical(exported$reporting_unit, all_cells$admin_path)) {
  cat(">>> PASS: name is the cell_id as a string; cell_id stays numeric; reporting_unit carries the admin_path label.\n")
} else {
  cat(">>> FAIL: name/cell_id/reporting_unit do not match the expected combination.\n")
}

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level IN ('HIER_ADM0', 'HIER_ADM1', 'HIER_ADM2');")
dbDisconnect(con)
