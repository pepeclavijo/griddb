#' Ingest administrative boundaries into the cell_admin table
#'
#' Joins a boundary sf object against an existing grid table and writes
#' the resulting (cell_id, admin_level, admin_id) rows into
#' masks.cell_admin.
#'
#' Assignment uses geometric intersection (\code{ST_Intersects}), not
#' centroid containment: a cell is assigned to an admin unit if any
#' part of the cell overlaps that unit's boundary, even slightly. This
#' is a deliberate choice to avoid under-coverage at boundaries -- with
#' centroid-based assignment, a cell whose body genuinely overlaps a
#' region but whose centroid falls just outside it would be excluded
#' entirely, silently leaving out real area at every region's edge.
#'
#' \strong{Consequence: a single cell can be assigned to more than one
#' admin unit at the same level} (e.g. a 15-arcmin cell straddling the
#' boundary between two adjacent districts will appear in both
#' districts' \code{\link{get_simulation_cells}} results). This trades
#' away the previous guarantee that cells belonging to disjoint admin
#' units are themselves disjoint. In exchange, no cell that genuinely
#' touches a region is ever silently dropped from it.
#'
#' \strong{Practical implication for callers}: if aggregating or
#' summing values (e.g. total cropland area) across the results of
#' multiple \code{get_simulation_cells()} calls for adjacent admin
#' units, deduplicate by \code{cell_id} first, or a boundary cell will
#' be double-counted. A single call for a single admin unit is
#' unaffected -- duplication only arises when results from multiple
#' units are combined.
#'
#' This function is source-agnostic: pass in any sf object with the
#' required columns, regardless of whether it originated from GADM,
#' geoBoundaries, or a customer-drawn region upload.
#'
#' @param con A DBI connection
#' @param boundaries sf object with columns: admin_id, admin_name,
#'   parent_id (may be NA), and geometry (WGS84)
#' @param admin_level Character label, e.g. "ADM0", "ADM1", "customer_region"
#' @param resolution_arcmin Numeric resolution of the grid table to join against
#' @param source Character label for provenance, e.g. "geoBoundaries", "GADM"
#' @return Invisibly, the number of rows inserted
#' @export
update_admin_boundaries <- function(con, boundaries, admin_level,
                                     resolution_arcmin, source = NA_character_) {
  required_cols <- c("admin_id", "admin_name", "geometry")
  missing_cols <- setdiff(required_cols, names(boundaries))
  if (length(missing_cols) > 0) {
    stop("boundaries is missing required column(s): ",
         paste(missing_cols, collapse = ", "), call. = FALSE)
  }
  if (!"parent_id" %in% names(boundaries)) {
    boundaries$parent_id <- NA_character_
  }

  table_name <- grid_table_name(resolution_arcmin)
  if (!DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = table_name))) {
    stop("Grid table grids.", table_name, " does not exist. ",
         "Generate and write the grid before ingesting admin boundaries.",
         call. = FALSE)
  }

  staging_name <- "tmp_admin_boundaries"
  sf::st_write(boundaries, con, layer = DBI::Id(schema = "staging", table = staging_name),
               append = FALSE, delete_layer = TRUE)

  n_inserted <- DBI::dbExecute(con, sprintf("
    INSERT INTO masks.cell_admin (cell_id, admin_level, admin_id, admin_name, parent_id, source)
    SELECT g.cell_id, %s, b.admin_id, b.admin_name, b.parent_id, %s
    FROM grids.%s g
    JOIN staging.%s b
      ON ST_Intersects(g.geometry, b.geometry)
    ON CONFLICT (cell_id, admin_level, admin_id) DO NOTHING;
  ", DBI::dbQuoteString(con, admin_level), DBI::dbQuoteString(con, source),
     table_name, staging_name))

  DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS staging.%s;", staging_name))

  message("Inserted ", n_inserted, " cell_admin rows for admin_level = ", admin_level)
  invisible(n_inserted)
}

#' Resolve an admin_name to its admin_id within a given admin_level
#'
#' @param con A DBI connection
#' @param admin_level Character, e.g. "ADM1"
#' @param admin_name Character, human-readable name (case-insensitive match)
#' @return Character admin_id
#' @export
resolve_admin_id <- function(con, admin_level, admin_name) {
  result <- DBI::dbGetQuery(con, sprintf("
    SELECT DISTINCT admin_id, admin_name FROM masks.cell_admin
    WHERE admin_level = %s AND admin_name ILIKE %s
  ", DBI::dbQuoteString(con, admin_level), DBI::dbQuoteString(con, admin_name)))

  if (nrow(result) == 0) {
    stop("No admin_level = '", admin_level, "' unit found matching name '",
         admin_name, "'", call. = FALSE)
  }
  if (nrow(result) > 1) {
    stop("Multiple matches for '", admin_name, "' at admin_level = '", admin_level,
         "': ", paste(result$admin_name, collapse = ", "),
         ". Use admin_id directly instead.", call. = FALSE)
  }

  result$admin_id[1]
}
