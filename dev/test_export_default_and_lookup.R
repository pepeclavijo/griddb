# Validates:
#   1. export_cells_to_legacy_geojson() ALWAYS includes
#      name/area/reporting_unit by default (required by the downstream
#      CLI, which populates its own polygon_name/polygon_area columns
#      directly from these), with cell_id ALSO always present as its
#      own separate, correct column.
#   2. export_admin_lookup() preserves EVERY admin match for a cell,
#      including boundary cells that intersect more than one unit --
#      unlike attach_admin_names()/attach_admin_hierarchy(), which
#      must pick one and warn.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Reuse the overlapping two-district setup so we have a guaranteed
#    ambiguous (multi-match) cell to test against.
# ---------------------------------------------------------------------
district_west <- st_sf(
  admin_id = "SYN.W", admin_name = "Synthetica West", parent_id = "SYN",
  geometry = st_sfc(st_polygon(list(matrix(c(
    10, 10, 11.1, 10, 11.1, 12, 10, 12, 10, 10
  ), ncol = 2, byrow = TRUE))), crs = 4326)
)
district_east <- st_sf(
  admin_id = "SYN.E", admin_name = "Synthetica East", parent_id = "SYN",
  geometry = st_sfc(st_polygon(list(matrix(c(
    10.9, 10, 12, 10, 12, 12, 10.9, 12, 10.9, 10
  ), ncol = 2, byrow = TRUE))), crs = 4326)
)

res <- 30
synthetic_boundary <- st_sf(admin_id = "SYN", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'LOOKUP_TEST';")
update_admin_boundaries(con, district_west, admin_level = "LOOKUP_TEST",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, district_east, admin_level = "LOOKUP_TEST",
                         resolution_arcmin = res, source = "synthetic")

combined_cells <- get_simulation_cells_multi(
  con, resolution_arcmin = res, admin_level = "LOOKUP_TEST",
  admin_ids = c("SYN.W", "SYN.E"), crop = NULL, min_frac_area = NULL
)
cat("Combined cells:", nrow(combined_cells), "\n")
print(table(combined_cells$n_admin_matches))

# ---------------------------------------------------------------------
# 2. Test the DEFAULT export: name/area/reporting_unit are always
#    present (CLI requirement), cell_id is ALSO always present as its
#    own separate column.
# ---------------------------------------------------------------------
default_path <- tempfile(fileext = ".geojson")
default_export <- export_cells_to_legacy_geojson(combined_cells, output_path = default_path)

print(names(sf::st_drop_geometry(default_export)))

required_cols <- c("name", "cell_id", "area", "reporting_unit")
if (all(required_cols %in% names(sf::st_drop_geometry(default_export))) &&
    identical(default_export$cell_id, combined_cells$cell_id) &&
    all(default_export$reporting_unit == "griddb_export")) {
  cat(">>> PASS: default export includes name/area/reporting_unit, plus a correct cell_id column.\n")
} else {
  cat(">>> FAIL: default export does not match the expected shape.\n")
}

# Confirm the file on disk also round-trips correctly with all four columns
reread <- st_read(default_path, quiet = TRUE)
if (all(required_cols %in% names(sf::st_drop_geometry(reread)))) {
  cat(">>> PASS: written file round-trips with all required columns.\n")
} else {
  cat(">>> FAIL: written file is missing expected properties:",
      names(sf::st_drop_geometry(reread)), "\n")
}

# ---------------------------------------------------------------------
# 3. Test export_admin_lookup(): the ambiguous cell should appear
#    TWICE (once per matching district), not collapsed to one row.
# ---------------------------------------------------------------------
lookup_table <- export_admin_lookup(con, combined_cells, admin_levels = "LOOKUP_TEST")
print(lookup_table)

ambiguous_cell_id <- combined_cells$cell_id[combined_cells$n_admin_matches == 2][1]
n_rows_for_ambiguous <- sum(lookup_table$cell_id == ambiguous_cell_id)

if (n_rows_for_ambiguous == 2) {
  cat(">>> PASS: export_admin_lookup() preserves both matches for the ambiguous cell.\n")
} else {
  cat(">>> FAIL: expected 2 rows for the ambiguous cell_id, got", n_rows_for_ambiguous, "\n")
}

# Confirm a non-ambiguous cell only has 1 row, as expected
unambiguous_cell_id <- combined_cells$cell_id[combined_cells$n_admin_matches == 1][1]
n_rows_for_unambiguous <- sum(lookup_table$cell_id == unambiguous_cell_id)
if (n_rows_for_unambiguous == 1) {
  cat(">>> PASS: an unambiguous cell correctly has exactly 1 lookup row.\n")
} else {
  cat(">>> FAIL: expected 1 row, got", n_rows_for_unambiguous, "\n")
}

# ---------------------------------------------------------------------
# 4. CSV write/read round-trip check
# ---------------------------------------------------------------------
csv_path <- tempfile(fileext = ".csv")
export_admin_lookup(con, combined_cells, admin_levels = "LOOKUP_TEST", output_path = csv_path)
reread_csv <- read.csv(csv_path)
if (nrow(reread_csv) == nrow(lookup_table)) {
  cat(">>> PASS: CSV round-trips with the same row count as the in-memory lookup table.\n")
} else {
  cat(">>> FAIL: CSV row count does not match.\n")
}

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'LOOKUP_TEST';")
dbDisconnect(con)
