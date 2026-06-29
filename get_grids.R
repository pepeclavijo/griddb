library(griddb)
library(sf)
library(DBI)

con <- get_db_connection()


exported <- export_cells_to_legacy_geojson(cells_masked, reporting_unit = cells_masked$admin_path,
                                           output_path = "almaty_grid_15arcmin.geojson")

export_admin_lookup(con, cells_masked, admin_levels = c("ADM0", "ADM1", "ADM2"),
                    output_path = "almaty_admin_lookup.csv")