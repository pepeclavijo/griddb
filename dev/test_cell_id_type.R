# Validates that cell_id is never returned as integer64 (a possible
# round-trip artifact of PostGIS's BIGINT type via RPostgres) from any
# of the export/helper functions -- integer64 can be silently
# mishandled by JSON/CSV serializers (scientific notation, precision
# loss), which would corrupt cell_id values in delivered files without
# any visible error.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

res <- 30
synthetic_boundary <- st_sf(admin_id = "SYN", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'TYPE_TEST';")
region <- st_sf(admin_id = "SYN.R", admin_name = "Type Test Region", parent_id = NA_character_,
                 geometry = st_geometry(synthetic_boundary))
update_admin_boundaries(con, region, admin_level = "TYPE_TEST",
                         resolution_arcmin = res, source = "synthetic")

cells <- get_simulation_cells(con, resolution_arcmin = res,
                               admin_level = "TYPE_TEST", admin_id = "SYN.R",
                               crop = NULL, min_frac_area = NULL)

cat("=== get_simulation_cells() cell_id class ===\n")
print(class(cells$cell_id))
if (!"integer64" %in% class(cells$cell_id)) {
  cat(">>> Note: get_simulation_cells() itself doesn't currently cast -- ",
      "checking downstream functions, which DO cast, below.\n", sep = "")
}

# ---------------------------------------------------------------------
# Test export_cells_to_legacy_geojson()
# ---------------------------------------------------------------------
exported <- export_cells_to_legacy_geojson(cells, reporting_unit = "Test",
                                            output_path = tempfile(fileext = ".geojson"))
cat("\n=== export_cells_to_legacy_geojson() name/cell_id class ===\n")
print(class(exported$name))
print(class(exported$cell_id))

if (is.character(exported$name) && is.numeric(exported$cell_id)) {
  cat(">>> PASS: name is a character string (CLI requirement); cell_id stays numeric.\n")
} else {
  cat(">>> FAIL: name/cell_id do not have the expected types.\n")
}

# ---------------------------------------------------------------------
# Test attach_admin_names()
# ---------------------------------------------------------------------
cells_named <- attach_admin_names(con, cells, admin_level = "TYPE_TEST")
cat("\n=== attach_admin_names() cell_id class ===\n")
print(class(cells_named$cell_id))
if (!"integer64" %in% class(cells_named$cell_id)) {
  cat(">>> PASS: attach_admin_names() cell_id is not integer64.\n")
} else {
  cat(">>> FAIL: attach_admin_names() cell_id is still integer64.\n")
}

# ---------------------------------------------------------------------
# Test attach_admin_hierarchy()
# ---------------------------------------------------------------------
cells_hier <- attach_admin_hierarchy(con, cells, admin_levels = "TYPE_TEST")
cat("\n=== attach_admin_hierarchy() cell_id class ===\n")
print(class(cells_hier$cell_id))
if (!"integer64" %in% class(cells_hier$cell_id)) {
  cat(">>> PASS: attach_admin_hierarchy() cell_id is not integer64.\n")
} else {
  cat(">>> FAIL: attach_admin_hierarchy() cell_id is still integer64.\n")
}

# ---------------------------------------------------------------------
# Test export_admin_lookup()
# ---------------------------------------------------------------------
lookup_table <- export_admin_lookup(con, cells, admin_levels = "TYPE_TEST")
cat("\n=== export_admin_lookup() cell_id class ===\n")
print(class(lookup_table$cell_id))
if (!"integer64" %in% class(lookup_table$cell_id)) {
  cat(">>> PASS: export_admin_lookup() cell_id is not integer64.\n")
} else {
  cat(">>> FAIL: export_admin_lookup() cell_id is still integer64.\n")
}

# ---------------------------------------------------------------------
# Round-trip check: confirm a written GeoJSON's cell_id reads back as
# a plain numeric, not scientific notation or a corrupted value
# ---------------------------------------------------------------------
geojson_path <- tempfile(fileext = ".geojson")
export_cells_to_legacy_geojson(cells, reporting_unit = "Test", output_path = geojson_path)
raw_json <- jsonlite::fromJSON(geojson_path, simplifyVector = FALSE)
cell_id_values <- sapply(raw_json$features, function(f) f$properties$cell_id)
cat("\n=== Raw cell_id values as written in the GeoJSON file ===\n")
print(cell_id_values[1:5])
if (all(cell_id_values == round(cell_id_values)) && !any(grepl("e\\+", as.character(cell_id_values)))) {
  cat(">>> PASS: written cell_id values are clean integers, no scientific notation.\n")
} else {
  cat(">>> FAIL: written cell_id values show signs of corruption.\n")
}

# ---------------------------------------------------------------------
# Confirm cell_id is a clean whole number (no spurious floating-point
# fractional noise) and area has no excessive decimal precision
# ---------------------------------------------------------------------
area_values <- sapply(raw_json$features, function(f) f$properties$area)
cat("\n=== Raw area values as written in the GeoJSON file ===\n")
print(area_values[1:5])

if (all(cell_id_values == round(cell_id_values))) {
  cat(">>> PASS: cell_id values are exact whole numbers, no fractional noise.\n")
} else {
  cat(">>> FAIL: cell_id values have unexpected fractional components.\n")
}

if (all(area_values == round(area_values))) {
  cat(">>> PASS: area values are rounded to whole square meters, no excessive decimal noise.\n")
} else {
  cat(">>> FAIL: area values still carry spurious decimal precision.\n")
}

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'TYPE_TEST';")
dbDisconnect(con)
