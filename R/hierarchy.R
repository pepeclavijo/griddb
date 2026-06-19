#' Build a fine-to-coarse cell hierarchy table
#'
#' Computes, for every cell in the fine-resolution grid table, which
#' coarse-resolution cell its centroid falls within, and writes the
#' result as a lookup table. This is computed once and never
#' recomputed -- it is what allows fast aggregation of fine-grid results
#' (e.g. soil-resolution simulation outputs) up to a coarser level
#' (e.g. weather-resolution) without repeated geometry operations.
#'
#' @param con A DBI connection
#' @param fine_arcmin Numeric resolution of the finer grid (smaller number)
#' @param coarse_arcmin Numeric resolution of the coarser grid (larger number)
#' @return Invisibly, the hierarchy table name
#' @export
build_cell_hierarchy <- function(con, fine_arcmin, coarse_arcmin) {
  fine_table <- grid_table_name(fine_arcmin)
  coarse_table <- grid_table_name(coarse_arcmin)
  hierarchy_table <- hierarchy_table_name(fine_arcmin, coarse_arcmin)

  if (!DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = fine_table))) {
    stop("Grid table grids.", fine_table, " does not exist.", call. = FALSE)
  }
  if (!DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = coarse_table))) {
    stop("Grid table grids.", coarse_table, " does not exist.", call. = FALSE)
  }

  DBI::dbExecute(con, sprintf("
    CREATE TABLE IF NOT EXISTS grids.%s (
      fine_cell_id   BIGINT PRIMARY KEY,
      coarse_cell_id BIGINT NOT NULL
    );", hierarchy_table))

  n_inserted <- DBI::dbExecute(con, sprintf("
    INSERT INTO grids.%s (fine_cell_id, coarse_cell_id)
    SELECT s.cell_id, w.cell_id
    FROM grids.%s s
    JOIN grids.%s w
      ON ST_Within(ST_Centroid(s.geometry), w.geometry)
    ON CONFLICT (fine_cell_id) DO NOTHING;
  ", hierarchy_table, fine_table, coarse_table))

  DBI::dbExecute(con, sprintf(
    "CREATE INDEX IF NOT EXISTS idx_%s_coarse ON grids.%s (coarse_cell_id);",
    hierarchy_table, hierarchy_table
  ))

  message("Inserted ", n_inserted, " rows into grids.", hierarchy_table)
  invisible(hierarchy_table)
}
