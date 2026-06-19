# Synthetic smoke test for the griddb database-dependent functions.
#
# Uses a tiny synthetic boundary (no real country data) to exercise the
# full pipeline -- grid generation/write, admin boundary ingestion, a
# fake crop mask, and the query function -- before touching any real
# Kazakhstan data. Run this interactively, line by line, so you can see
# where things break if they do.

library(griddb)
library(sf)
library(dplyr)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. A small synthetic "country" boundary: a 2deg x 2deg square,
#    located somewhere with no real-world ambiguity (middle of an
#    ocean-ish area is fine since this is purely synthetic).
# ---------------------------------------------------------------------
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

res <- 30  # coarse resolution (30 arcmin = 0.5 deg) keeps cell counts tiny

# ---------------------------------------------------------------------
# 2. Generate + write the grid
# ---------------------------------------------------------------------
grid_table <- populate_grid_for_boundary(con, resolution_arcmin = res,
                                          boundary = synthetic_boundary)
# Expect a message like "Wrote 16 cells to grids.cells_30_arcmin"
# (2deg / 0.5deg = 4 cells per side = 16 cells)

# Sanity check: read it back
check <- st_read(con, query = sprintf("SELECT * FROM grids.%s;", grid_table))
print(nrow(check))
print(head(check))

# ---------------------------------------------------------------------
# 3. Ingest a synthetic ADM0 boundary (the whole square) and a
#    synthetic ADM1 boundary (just the bottom-left half of it)
# ---------------------------------------------------------------------
adm0 <- synthetic_boundary |>
  mutate(admin_id = "SYN", admin_name = "Synthetica", parent_id = NA_character_)

adm1_half <- st_sf(
  admin_id = "SYN.1",
  admin_name = "Synthetica South",
  parent_id = "SYN",
  geometry = st_sfc(
    st_polygon(list(matrix(c(
      10, 10,
      12, 10,
      12, 11,
      10, 11,
      10, 10
    ), ncol = 2, byrow = TRUE))),
    crs = 4326
  )
)

update_admin_boundaries(con, adm0, admin_level = "ADM0",
                         resolution_arcmin = res, source = "synthetic")
update_admin_boundaries(con, adm1_half, admin_level = "ADM1",
                         resolution_arcmin = res, source = "synthetic")

# Sanity check
admin_check <- dbGetQuery(con, "SELECT * FROM masks.cell_admin ORDER BY admin_level, cell_id;")
print(admin_check)
# Expect 16 rows for ADM0 (all cells), ~8 rows for ADM1 (bottom half)

# ---------------------------------------------------------------------
# 4. Fake a crop mask WITHOUT needing a real raster file: insert
#    directly into masks.crop_presence to isolate the query function
#    from update_crop_mask()/terra for this first pass.
# ---------------------------------------------------------------------
fake_crop_presence <- check |>
  st_drop_geometry() |>
  select(cell_id) |>
  mutate(
    crop = "cropland",
    frac_area = runif(n(), 0, 1),   # random fractions, just to have varying values
    mask_source = "synthetic_test",
    mask_year = 2024
  )

dbWriteTable(con, c("staging", "tmp_fake_crop"), fake_crop_presence, overwrite = TRUE)
dbExecute(con, "
  INSERT INTO masks.crop_presence (cell_id, crop, frac_area, mask_source, mask_year)
  SELECT cell_id, crop, frac_area, mask_source, mask_year FROM staging.tmp_fake_crop
  ON CONFLICT (cell_id, crop, mask_source) DO NOTHING;
")
dbExecute(con, "DROP TABLE IF EXISTS staging.tmp_fake_crop;")

# ---------------------------------------------------------------------
# 5. The real test: get_simulation_cells()
# ---------------------------------------------------------------------

# ADM0, no crop filter -- should return all 16 cells
all_cells <- get_simulation_cells(con, resolution_arcmin = res,
                                   admin_level = "ADM0", admin_id = "SYN",
                                   crop = NULL, min_frac_area = NULL)
print(nrow(all_cells))   # expect 16

# ADM1 by name, with crop filter at threshold 0 -- should return ~8 cells
south_cells <- get_simulation_cells(con, resolution_arcmin = res,
                                     admin_level = "ADM1", admin_name = "Synthetica South",
                                     crop = "cropland", min_frac_area = 0,
                                     mask_source = "synthetic_test")
print(nrow(south_cells))  # expect ~8
print(south_cells)

# ADM1 with a high threshold -- should return fewer cells (random fractions, so count varies)
south_cells_filtered <- get_simulation_cells(con, resolution_arcmin = res,
                                              admin_level = "ADM1", admin_id = "SYN.1",
                                              crop = "cropland", min_frac_area = 0.5,
                                              mask_source = "synthetic_test")
print(nrow(south_cells_filtered))

# ---------------------------------------------------------------------
# 6. Cleanup -- drop everything this script created so it doesn't
#    pollute the database before the real Kazakhstan run
# ---------------------------------------------------------------------
# Uncomment to clean up:
# dbExecute(con, sprintf("DROP TABLE IF EXISTS grids.%s CASCADE;", grid_table))
# dbExecute(con, "DELETE FROM masks.cell_admin WHERE source = 'synthetic';")
# dbExecute(con, "DELETE FROM masks.crop_presence WHERE mask_source = 'synthetic_test';")

dbDisconnect(con)
