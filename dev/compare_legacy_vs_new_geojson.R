# Compare the legacy KZ rice GeoJSON against a FRESH griddb export
# covering the SAME geographic area -- rather than an arbitrary
# different oblast, this derives the legacy file's actual extent and
# reporting_unit(s), and queries griddb for the matching region(s) so
# the comparison is apples-to-apples.
#
# Run block by block.

library(griddb)
library(sf)
library(jsonlite)
library(dplyr)
library(DBI)

con <- get_db_connection()

legacy_path <- "data-raw/boundaries/kaz_polys_ric_15m_v1.geojson"  # adjust path as needed

# ---------------------------------------------------------------------
# 1. Figure out what the legacy file actually covers
# ---------------------------------------------------------------------
legacy_sf <- st_read(legacy_path, quiet = TRUE)

cat("=== reporting_unit values in the legacy file ===\n")
print(unique(legacy_sf$reporting_unit))
# e.g. "Almaty ; Balkash" -- "Balkash" turned out to be an ADM2-level
# district name, not the ADM1 oblast itself, so we match against ADM2.

# Extract the district name component (text after the " ; ")
legacy_sf$district_guess <- sub("^.* ; ", "", legacy_sf$reporting_unit)
cat("\n=== Guessed ADM2 district name(s) ===\n")
print(unique(legacy_sf$district_guess))

cat("\n=== Legacy file's spatial extent ===\n")
print(st_bbox(legacy_sf))

# ---------------------------------------------------------------------
# 2. Check whether the guessed district name matches what's in cell_admin
#    at the ADM2 level
# ---------------------------------------------------------------------
available_districts <- dbGetQuery(con, "
  SELECT DISTINCT admin_name FROM masks.cell_admin WHERE admin_level = 'ADM2'
  ORDER BY admin_name;
")
print(available_districts)

# Transliteration often differs (Balkash / Balkhash / Balqash) -- try a
# loose match first, but be ready to set this manually after
# inspecting `available_districts` above.
matched_district_name <- available_districts$admin_name[
  grepl(legacy_sf$district_guess[1], available_districts$admin_name, ignore.case = TRUE)
][1]

if (is.na(matched_district_name)) {
  stop("No automatic match found -- inspect `available_districts` above and ",
       "set `matched_district_name` manually to the correct value.")
}
cat("\nUsing district:", matched_district_name, "\n")

# ---------------------------------------------------------------------
# 3. Query griddb for the SAME area, using the same crop mask
# ---------------------------------------------------------------------
new_cells <- get_simulation_cells(con, resolution_arcmin = 15,
                                   admin_level = "ADM2",
                                   admin_name = matched_district_name,
                                   crop = "cropland", min_frac_area = 0,
                                   mask_source = "cropland_area_nc4")
cat("New cells found:", nrow(new_cells), "\n")

# ---------------------------------------------------------------------
# 4. Export the matching area to the legacy format
# ---------------------------------------------------------------------
new_path <- paste0("kaz_", gsub("[^A-Za-z0-9]", "_", matched_district_name), "_matched.geojson")

export_cells_to_legacy_geojson(
  cells = new_cells,
  reporting_unit = matched_district_name,
  output_path = new_path
)

new_sf <- st_read(new_path, quiet = TRUE)

# ---------------------------------------------------------------------
# 5. STRUCTURAL COMPARISON
# ---------------------------------------------------------------------
legacy_raw <- fromJSON(legacy_path, simplifyVector = FALSE)
new_raw <- fromJSON(new_path, simplifyVector = FALSE)

cat("\n=== Top-level type ===\n")
cat("Legacy:", legacy_raw$type, " | New:", new_raw$type, "\n")

cat("=== Geometry type (first feature) ===\n")
cat("Legacy:", legacy_raw$features[[1]]$geometry$type,
    " | New:", new_raw$features[[1]]$geometry$type, "\n")

cat("=== Property names ===\n")
cat("Legacy:", paste(names(legacy_raw$features[[1]]$properties), collapse = ", "), "\n")
cat("New:   ", paste(names(new_raw$features[[1]]$properties), collapse = ", "), "\n")

# ---------------------------------------------------------------------
# 6. SUBSTANTIVE COMPARISON -- now genuinely comparable, same geography
# ---------------------------------------------------------------------
cat("\n=== Feature counts (same area, two methods) ===\n")
cat("Legacy:", nrow(legacy_sf), "features\n")
cat("New:   ", nrow(new_sf), "features\n")

cat("\n=== Total area covered (square meters) ===\n")
cat("Legacy total:", sum(legacy_sf$area), "\n")
cat("New total:   ", sum(new_sf$area), "\n")
cat("Difference:  ", sum(new_sf$area) - sum(legacy_sf$area),
    " (", round(100 * (sum(new_sf$area) - sum(legacy_sf$area)) / sum(legacy_sf$area), 1),
    "% ) -- small positive difference is expected since griddb keeps whole\n",
    "    cells at the boundary edge rather than clipping them to slivers\n")

cat("\n=== Spatial extent comparison ===\n")
cat("Legacy:\n"); print(st_bbox(legacy_sf))
cat("New:\n"); print(st_bbox(new_sf))

cat("\n=== Area distribution shape (CV = sd/mean) ===\n")
cat("Legacy CV:", sd(legacy_sf$area) / mean(legacy_sf$area),
    " (higher = more sliver fragments from clipping)\n")
cat("New CV:   ", sd(new_sf$area) / mean(new_sf$area),
    " (should be near 0 -- uniform whole cells)\n")

# ---------------------------------------------------------------------
# 7. VISUAL OVERLAY -- plot both on the same axes to confirm they
#    cover the same physical area
# ---------------------------------------------------------------------
plot(st_geometry(new_sf), border = "darkblue", main = "Legacy (red) vs New griddb (blue)")
plot(st_geometry(legacy_sf), border = "darkred", add = TRUE)

dbDisconnect(con)
