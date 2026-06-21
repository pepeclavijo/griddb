# Real Kazakhstan end-to-end run.
#
# Captures the full sequence for real data: ADM1 boundaries (20
# oblasts), ADM0 (country, derived via union), the cropland.area.nc4
# percent-area crop mask, and a final query + legacy export test.
# Run block by block, top to bottom.
#
# STATUS as of last update:
#   Steps 1-4 (grid + ADM1 + ADM0 ingestion): COMPLETED in a prior
#     session. Safe to re-run -- write_grid_to_postgis() and
#     update_admin_boundaries() both use ON CONFLICT DO NOTHING, so
#     re-running these steps will not duplicate or error on existing rows.
#   Step 5 (crop mask ingestion): IN PROGRESS / PENDING -- this is the
#     long-running step (real ~727M-pixel global raster). Re-running is
#     safe (uses ON CONFLICT DO UPDATE) but will redo the full
#     computation each time, so avoid re-running unnecessarily once it
#     completes once.
#   Steps 6-8 (spot-check, query, export): PENDING, not yet run.

library(griddb)
library(sf)
library(dplyr)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Load and clean the ADM1 boundary shapefile
# ---------------------------------------------------------------------
oblast_boundary <- st_read("data-raw/boundaries/kaz_adm1/kaz_admbnda_adm1_unhcr_2023.shp")

oblast_boundary <- st_transform(oblast_boundary, 4326)
oblast_boundary <- st_make_valid(oblast_boundary)

# names(oblast_boundary):
# [1] "ADM0_EN"    "ADM0_PCODE" "ADM1_EN"    "ADM1_PCODE" "geometry"

# ---------------------------------------------------------------------
# 2. Generate and write the grid at 15 arcmin (matches legacy filename)
# ---------------------------------------------------------------------
grid_table <- populate_grid_for_boundary(con, resolution_arcmin = 15,
                                          boundary = oblast_boundary)
# Wrote 5618 cells to grids.cells_15_arcmin

# ---------------------------------------------------------------------
# 3. Ingest ADM1 (oblast) boundaries
# ---------------------------------------------------------------------
adm1_for_ingest <- oblast_boundary |>
  mutate(
    admin_id = ADM1_PCODE,
    admin_name = ADM1_EN,
    parent_id = ADM0_PCODE
  )

update_admin_boundaries(con, adm1_for_ingest, admin_level = "ADM1",
                         resolution_arcmin = 15, source = "geoBoundaries")
# Inserted 5286 cell_admin rows for admin_level = ADM1
# (332 cells near the northern Kazakhstan/Russia border have centroids
#  falling outside every oblast polygon -- confirmed via spot check,
#  this is a real gap in the source shapefile, not a code bug)

# ---------------------------------------------------------------------
# 4. Ingest ADM0 (country), derived by unioning all oblasts
# ---------------------------------------------------------------------
adm0_for_ingest <- oblast_boundary |>
  group_by(ADM0_EN, ADM0_PCODE) |>
  summarise(geometry = st_union(geometry), .groups = "drop") |>
  mutate(
    admin_id = ADM0_PCODE,
    admin_name = ADM0_EN,
    parent_id = NA_character_
  )

update_admin_boundaries(con, adm0_for_ingest, admin_level = "ADM0",
                         resolution_arcmin = 15, source = "geoBoundaries")
# Inserted 5286 cell_admin rows for admin_level = ADM0
# (identical count to ADM1 -- the union doesn't fill gaps in the
#  source data, so the same border cells are excluded at both levels)

# ---------------------------------------------------------------------
# 4b. Ingest ADM2 (district/rayon level), needed for fine-grained
#     comparisons against legacy reporting_unit values like
#     "Almaty ; Balkash" -- "Balkash" turned out to be an ADM2-level
#     district, not the full ADM1 oblast.
# ---------------------------------------------------------------------
adm2_boundary <- st_read("data-raw/boundaries/kaz_adm2/kaz_admbnda_adm2_unhcr_2023.shp")
adm2_boundary <- st_transform(adm2_boundary, 4326)
adm2_boundary <- st_make_valid(adm2_boundary)

print(names(adm2_boundary))
# expect something like ADM0_EN, ADM1_EN, ADM1_PCODE, ADM2_EN, ADM2_PCODE, geometry

adm2_for_ingest <- adm2_boundary |>
  mutate(
    admin_id = ADM2_PCODE,
    admin_name = ADM2_EN,
    parent_id = ADM1_PCODE
  )

update_admin_boundaries(con, adm2_for_ingest, admin_level = "ADM2",
                         resolution_arcmin = 15, source = "geoBoundaries")

print(sort(unique(adm2_for_ingest$admin_name)))
# look for the entry matching "Balkash" / "Balkhash" / "Balqash" etc.

kz_admin_id <- adm0_for_ingest$admin_id[1]
print(kz_admin_id)  # confirm the actual KZ admin_id value


# ---------------------------------------------------------------------
# 5. Ingest the real cropland mask (percent-area NetCDF)
# ---------------------------------------------------------------------
# NOTE: if this is slow, consider copying cropland.area.nc4 to a local
# (non-cloud-synced) path first -- repeated random-access reads over
# a cloud-sync folder (e.g. Google Drive) can be much slower than a
# genuinely local disk.

update_crop_mask(con,
                  raster_path = "data-raw/crop_masks/cropland.area.nc4",
                  resolution_arcmin = 15,
                  mask_source = "cropland_area_nc4",
                  raster_type = "percent_area",
                  raster_var = "area",
                  admin_level = "ADM0",
                  admin_id = kz_admin_id)

# ---------------------------------------------------------------------
# 6. Spot-check a few frac_area values
# ---------------------------------------------------------------------
spot_check <- dbGetQuery(con, "
  SELECT cell_id, frac_area FROM masks.crop_presence
  WHERE mask_source = 'cropland_area_nc4'
  ORDER BY frac_area DESC
  LIMIT 10;
")
print(spot_check)

summary_stats <- dbGetQuery(con, "
  SELECT count(*) AS n_cells,
         avg(frac_area) AS mean_frac,
         max(frac_area) AS max_frac,
         sum(CASE WHEN frac_area > 0 THEN 1 ELSE 0 END) AS n_with_cropland
  FROM masks.crop_presence
  WHERE mask_source = 'cropland_area_nc4';
")
print(summary_stats)

# ---------------------------------------------------------------------
# 7. Query simulation-ready cells for one oblast, as a real test
# ---------------------------------------------------------------------
print(unique(adm1_for_ingest$admin_name))  # see the actual oblast name spellings

# Pick the first oblast alphabetically as the test case -- change this
# string to test a different one specifically.
example_oblast_name <- sort(unique(adm1_for_ingest$admin_name))[1]
print(example_oblast_name)

example_oblast_cells <- get_simulation_cells(con, resolution_arcmin = 15,
                                              admin_level = "ADM1",
                                              admin_name = example_oblast_name,
                                              crop = "cropland", min_frac_area = 0,
                                              mask_source = "cropland_area_nc4")
print(nrow(example_oblast_cells))
print(example_oblast_cells)

# ---------------------------------------------------------------------
# 8. Export to the legacy GeoJSON format
# ---------------------------------------------------------------------
export_cells_to_legacy_geojson(
  cells = example_oblast_cells,
  reporting_unit = example_oblast_name,
  output_path = paste0("kaz_", gsub("[^A-Za-z0-9]", "_", example_oblast_name), "_test.geojson")
)

dbDisconnect(con)
