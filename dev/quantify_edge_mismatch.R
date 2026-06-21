# Quantify exactly how much of the legacy boundary's area is NOT
# covered by the centroid-assigned griddb cells, to decide whether the
# edge mismatch we're seeing visually is a minor, expected effect or
# something worth changing the admin-assignment rule for.
#
# Run block by block, following on from compare_legacy_vs_new_geojson.R
# (assumes legacy_sf, new_sf, new_cells, con, and matched_district_name
# already exist in session).

library(sf)
library(dplyr)

# ---------------------------------------------------------------------
# 1. How much of the legacy boundary's footprint do the new cells
#    actually cover?
# ---------------------------------------------------------------------
legacy_union <- st_union(st_geometry(legacy_sf))
new_union <- st_union(st_geometry(new_sf))

legacy_area_m2 <- as.numeric(st_area(st_transform(st_sf(geometry = legacy_union), 32642)))  # adjust UTM zone if needed
new_area_m2 <- as.numeric(st_area(st_transform(st_sf(geometry = new_union), 32642)))

cat("Legacy total footprint area (m2):", legacy_area_m2, "\n")
cat("New total footprint area (m2):   ", new_area_m2, "\n\n")

# Area of legacy boundary NOT covered by any new cell
legacy_not_in_new <- suppressWarnings(st_difference(legacy_union, new_union))
uncovered_area_m2 <- if (length(legacy_not_in_new) > 0 && !st_is_empty(legacy_not_in_new)) {
  as.numeric(st_area(st_transform(st_sf(geometry = legacy_not_in_new), 32642)))
} else {
  0
}

cat("Legacy area NOT covered by any new cell (m2):", uncovered_area_m2, "\n")
cat("As % of legacy total footprint:",
    round(100 * uncovered_area_m2 / legacy_area_m2, 1), "%\n\n")

# ---------------------------------------------------------------------
# 2. How many ADJACENT districts' cells would we need to pull in to
#    cover the gap? (i.e. is the "missing" red area actually sitting
#    inside a NEIGHBORING district's cell_admin assignment instead of
#    being unassigned entirely?)
# ---------------------------------------------------------------------
# Get ALL cells (any admin assignment) that intersect the uncovered sliver
if (uncovered_area_m2 > 0) {
  uncovered_sf <- st_sf(geometry = legacy_not_in_new, crs = 4326)

  nearby_cells <- st_read(con, query = sprintf("
    SELECT g.cell_id, a.admin_name, g.geometry
    FROM grids.cells_15_arcmin g
    LEFT JOIN masks.cell_admin a ON g.cell_id = a.cell_id AND a.admin_level = 'ADM2'
    WHERE g.geometry && ST_Envelope(ST_GeomFromText('%s', 4326));
  ", st_as_text(st_combine(uncovered_sf))))

  overlapping <- nearby_cells[st_intersects(nearby_cells, uncovered_sf, sparse = FALSE)[, 1], ]
  cat("=== Admin assignment of cells overlapping the 'missing' area ===\n")
  print(table(overlapping$admin_name, useNA = "always"))
}

# ---------------------------------------------------------------------
# 3. Conclusion guide
# ---------------------------------------------------------------------
cat("\n=== Interpretation ===\n")
cat("If uncovered % is small (a few percent) and the overlapping cells\n")
cat("in section 2 are mostly assigned to ADJACENT districts (not NA),\n")
cat("this is the expected centroid-vs-edge effect -- cells right at the\n")
cat("boundary got assigned to the neighboring district instead, not lost\n")
cat("entirely. This matches the documented tradeoff in PROCESS_NARRATIVE.md.\n\n")
cat("If uncovered % is large, or many overlapping cells show NA admin_name,\n")
cat("that suggests something else is wrong (e.g. a genuine gap in ADM2\n")
cat("coverage, or the district boundary itself has a different shape than\n")
cat("expected) and needs further investigation before deciding on a fix.\n")
