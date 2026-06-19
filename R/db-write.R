#' Write a grid sf object to PostGIS as a new resolution table
#'
#' Creates the table (named via grid_table_name()), writes the cells,
#' and adds the standard spatial and lookup indexes. Uses upsert-style
#' behavior: if the table already exists, new cells are appended and
#' conflicting cell_ids are left untouched (existing rows are never
#' silently overwritten).
#'
#' @param con A DBI connection, e.g. from get_db_connection()
#' @param grid_sf An sf object as returned by generate_grid_bbox() or
#'   generate_grid_for_boundary()
#' @return Invisibly, the table name written to
#' @export
write_grid_to_postgis <- function(con, grid_sf) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required", call. = FALSE)
  }

  resolution_arcmin <- unique(grid_sf$resolution_arcmin)
  if (length(resolution_arcmin) != 1) {
    stop("grid_sf must contain cells from exactly one resolution", call. = FALSE)
  }

  table_name <- grid_table_name(resolution_arcmin)
  table_exists <- DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = table_name))

  if (!table_exists) {
    DBI::dbExecute(con, sprintf("
      CREATE TABLE grids.%s (
        cell_id           BIGINT PRIMARY KEY,
        lon_center        DOUBLE PRECISION NOT NULL,
        lat_center        DOUBLE PRECISION NOT NULL,
        resolution_arcmin DOUBLE PRECISION NOT NULL,
        geometry          GEOMETRY(POLYGON, 4326) NOT NULL
      );", table_name))
  }

  staging_name <- paste0("tmp_", table_name)
  sf::st_write(grid_sf, con, layer = DBI::Id(schema = "staging", table = staging_name),
               append = FALSE, delete_layer = TRUE)

  DBI::dbExecute(con, sprintf("
    INSERT INTO grids.%s (cell_id, lon_center, lat_center, resolution_arcmin, geometry)
    SELECT cell_id, lon_center, lat_center, resolution_arcmin, geometry
    FROM staging.%s
    ON CONFLICT (cell_id) DO NOTHING;
  ", table_name, staging_name))

  DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS staging.%s;", staging_name))

  if (!table_exists) {
    DBI::dbExecute(con, sprintf(
      "CREATE INDEX ON grids.%s USING GIST (geometry);", table_name
    ))
    DBI::dbExecute(con, sprintf(
      "CREATE INDEX ON grids.%s (lat_center, lon_center);", table_name
    ))
  }

  message("Wrote ", nrow(grid_sf), " cells to grids.", table_name)
  invisible(table_name)
}

#' Generate and write a grid for a country (or other) boundary in one step
#'
#' Convenience wrapper combining generate_grid_for_boundary() and
#' write_grid_to_postgis().
#'
#' @param con A DBI connection
#' @param resolution_arcmin Numeric grid resolution in arcminutes
#' @param boundary sf/sfc polygon boundary, WGS84
#' @return Invisibly, the table name written to
#' @export
populate_grid_for_boundary <- function(con, resolution_arcmin, boundary) {
  grid_sf <- generate_grid_for_boundary(resolution_arcmin, boundary)
  write_grid_to_postgis(con, grid_sf)
}
