# Validates get_simulation_cells_multi() correctly deduplicates
# boundary cells when combining results from multiple adjacent admin
# units. Builds two adjacent synthetic districts that share a border,
# confirms a shared boundary cell is returned once (not twice) by the
# combined query, while still being captured by each district
# individually.
#
# Run block by block.

library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Two adjacent 1deg x 2deg districts sharing a vertical border at
#    lon = 11, within the same 2deg x 2deg area used in earlier tests.
#    At 30 arcmin (0.5deg) resolution, cells straddling lon = 11 will
#    legitimately intersect BOTH districts.
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
# Deliberate small overlap (10.9 to 11.1) so a 0.5deg cell centered
# near lon=11 will genuinely intersect both -- this guarantees at
# least one real duplicate to test against, rather than relying on
# the districts happening to share an exact edge.

res <- 30
synthetic_boundary <- st_sf(admin_id = "SYN", geometry = st_sfc(
  st_polygon(list(matrix(c(10, 10, 12, 10, 12, 12, 10, 12, 10, 10), ncol = 2, byrow = TRUE))),
  crs = 4326
))

grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)

update_admin_boundaries(con, district_west, admin_level = "ADM2_TEST",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, district_east, admin_level = "ADM2_TEST",
                         resolution_arcmin = res, source = "synthetic")

# ---------------------------------------------------------------------
# 2. Confirm at least one cell is shared between the two districts
#    (sanity check before testing the dedup logic itself)
# ---------------------------------------------------------------------
overlap_check <- dbGetQuery(con, "
  SELECT cell_id, count(*) AS n
  FROM masks.cell_admin
  WHERE admin_level = 'ADM2_TEST'
  GROUP BY cell_id
  HAVING count(*) > 1;
")
print(overlap_check)
if (nrow(overlap_check) == 0) {
  stop("Test setup produced no shared cells -- adjust district geometries to overlap more.")
}

# ---------------------------------------------------------------------
# 3. The actual test: combine both districts via get_simulation_cells_multi()
# ---------------------------------------------------------------------
west_only <- get_simulation_cells(con, resolution_arcmin = res,
                                   admin_level = "ADM2_TEST", admin_id = "SYN.W",
                                   crop = NULL, min_frac_area = NULL)
east_only <- get_simulation_cells(con, resolution_arcmin = res,
                                   admin_level = "ADM2_TEST", admin_id = "SYN.E",
                                   crop = NULL, min_frac_area = NULL)

cat("West alone:", nrow(west_only), "cells\n")
cat("East alone:", nrow(east_only), "cells\n")
cat("Sum (with double-counting if naively combined):",
    nrow(west_only) + nrow(east_only), "\n\n")

combined <- get_simulation_cells_multi(con, resolution_arcmin = res,
                                        admin_level = "ADM2_TEST",
                                        admin_ids = c("SYN.W", "SYN.E"),
                                        crop = NULL, min_frac_area = NULL)
cat("Combined (deduplicated):", nrow(combined), "cells\n\n")

expected_unique <- length(union(west_only$cell_id, east_only$cell_id))
cat("Expected unique count (set union):", expected_unique, "\n")

if (nrow(combined) == expected_unique) {
  cat(">>> PASS: deduplicated count matches the expected set union.\n")
} else {
  cat(">>> FAIL: deduplicated count does not match expected union.\n")
}

# Confirm no cell_id appears twice in the final result
if (anyDuplicated(combined$cell_id) == 0) {
  cat(">>> PASS: no duplicate cell_ids in combined result.\n")
} else {
  cat(">>> FAIL: duplicate cell_ids still present.\n")
}

# Confirm the n_admin_matches column correctly flags shared cells
print(table(combined$n_admin_matches))
cat("(cells with n_admin_matches = 2 are the boundary cells shared by both districts)\n")

# ---------------------------------------------------------------------
# 4. Test PARENT-based selection: pull all ADM2_TEST units under a
#    given parent without listing them by hand. Both synthetic
#    districts share parent_id = "SYN", so selecting parent SYN at
#    parent_level "ADM0_TEST_PARENT" should return the same combined,
#    deduplicated result as the direct-list call above.
# ---------------------------------------------------------------------
# (Re-using "SYN" as a stand-in parent id directly, since update_admin_boundaries
#  was called with parent_id = "SYN" for both test districts already --
#  no separate parent-level ingestion needed for this synthetic check.)

combined_via_parent <- get_simulation_cells_multi(
  con, resolution_arcmin = res,
  admin_level = "ADM2_TEST",
  parent_level = "ADM0_TEST_PARENT",  # not actually used for lookup here, just descriptive
  parent_ids = "SYN",
  crop = NULL, min_frac_area = NULL
)

cat("\nCombined via parent selection:", nrow(combined_via_parent), "cells\n")

if (setequal(combined$cell_id, combined_via_parent$cell_id)) {
  cat(">>> PASS: parent-based selection returns the same cell set as the direct-list call.\n")
} else {
  cat(">>> FAIL: parent-based and direct-list selection produced different cell sets.\n")
}

# ---------------------------------------------------------------------
# 5. Test DIRECT selection with only ONE district (the small-area
#    parameter-testing use case) -- should just behave like a normal
#    single get_simulation_cells() call, no deduplication needed.
# ---------------------------------------------------------------------
single_district <- get_simulation_cells_multi(
  con, resolution_arcmin = res,
  admin_level = "ADM2_TEST",
  admin_ids = "SYN.W",
  crop = NULL, min_frac_area = NULL
)
cat("\nSingle-district selection:", nrow(single_district), "cells (should equal west_only:",
    nrow(west_only), ")\n")

# ---------------------------------------------------------------------
# 5b. Confirm the DEFAULT export always includes name/area/
#     reporting_unit (required by the downstream CLI), with cell_id
#     ALSO always present as a separate column.
# ---------------------------------------------------------------------
default_export <- export_cells_to_legacy_geojson(
  combined_cells, output_path = tempfile(fileext = ".geojson")
)
print(names(sf::st_drop_geometry(default_export)))

required_cols <- c("name", "cell_id", "area", "reporting_unit")
if (all(required_cols %in% names(sf::st_drop_geometry(default_export))) &&
    is.character(default_export$name) &&
    identical(default_export$name, as.character(combined_cells$cell_id)) &&
    identical(default_export$cell_id, combined_cells$cell_id) &&
    all(default_export$reporting_unit == "griddb_export")) {
  cat(">>> PASS: default export includes name (= cell_id as a string), area, reporting_unit ",
      "(CLI requirement), plus a correct, separate numeric cell_id column.\n", sep = "")
} else {
  cat(">>> FAIL: default export is missing required columns or values.\n")
}

# ---------------------------------------------------------------------
# 6. Test expand_near_matches: requesting only "Synthetica West"
#    should, with expand_near_matches = TRUE, also pull in "Synthetica
#    East" if their names were set up to partially overlap. Using a
#    dedicated name pair here to mimic the real Almaty/Almaty Region
#    collision cleanly.
# ---------------------------------------------------------------------
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'NEAR_MATCH_TEST';")

city_like <- west_only[1, ]  # reuse one real cell's geometry for a quick synthetic row
dbExecute(con, sprintf("
  INSERT INTO masks.cell_admin (cell_id, admin_level, admin_id, admin_name, source)
  VALUES (%s, 'NEAR_MATCH_TEST', 'CITY', 'Synthetica', 'synthetic'),
         (%s, 'NEAR_MATCH_TEST', 'REGION', 'Synthetica Region', 'synthetic');
", as.integer(city_like$cell_id[1]), as.integer(city_like$cell_id[1])))

without_expansion <- get_simulation_cells_multi(
  con, resolution_arcmin = res, admin_level = "NEAR_MATCH_TEST",
  admin_names = "Synthetica", expand_near_matches = FALSE,
  crop = NULL, min_frac_area = NULL
)
cat("\nWithout expansion, units queried: 1 ('Synthetica' only)\n")

with_expansion <- get_simulation_cells_multi(
  con, resolution_arcmin = res, admin_level = "NEAR_MATCH_TEST",
  admin_names = "Synthetica", expand_near_matches = TRUE,
  crop = NULL, min_frac_area = NULL
)
cat("With expansion, 'Synthetica Region' should have been auto-included ",
    "(see message above)\n")

# Both will return the SAME single cell here (since we inserted the
# same cell_id for both names), but the point of this test is
# confirming the MESSAGE fires and the admin_id resolution correctly
# picks up the near-match -- check this by inspecting n_admin_matches
print(with_expansion$n_admin_matches)
if (with_expansion$n_admin_matches[1] == 2) {
  cat(">>> PASS: cell correctly shows it matched BOTH near-match units.\n")
} else {
  cat(">>> FAIL: expansion did not pick up both units as expected.\n")
}

dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'NEAR_MATCH_TEST';")

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
# dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
# dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'ADM2_TEST';")

dbDisconnect(con)
