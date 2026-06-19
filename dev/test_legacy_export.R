# Validates export_cells_to_legacy_geojson() produces output matching
# the shape of the real kaz_polys_ric_15m_v1.geojson example -- same
# property names, same MultiPolygon geometry type, same naming
# convention. Run this after the synthetic smoke test (reuses the
# same connection/cells if still in session, or re-run from scratch).

library(griddb)
library(sf)

con <- get_db_connection()

# Reuse the south_cells object from the synthetic smoke test if still
# in session; otherwise regenerate it quickly:
if (!exists("south_cells")) {
  res <- 30
  south_cells <- get_simulation_cells(con, resolution_arcmin = res,
                                       admin_level = "ADM1", admin_id = "SYN.1",
                                       crop = "cropland", min_frac_area = 0,
                                       mask_source = "synthetic_test")
}

# Export, no clipping (default: whole cells)
legacy_out <- export_cells_to_legacy_geojson(
  cells = south_cells,
  reporting_unit = "Synthetica South",
  output_path = "/tmp/test_legacy_export.geojson"
)

print(legacy_out)
# Expect: 8 features, name = "Synthetica South ; 1" through "; 8",
# area in square meters, reporting_unit = "Synthetica South" on every row

# Confirm the written file is valid GeoJSON in the expected shape
written <- jsonlite::fromJSON("/tmp/test_legacy_export.geojson", simplifyVector = FALSE)
print(written$type)                                  # "FeatureCollection"
print(written$features[[1]]$geometry$type)            # "MultiPolygon"
print(written$features[[1]]$properties)               # name/area/reporting_unit

dbDisconnect(con)
