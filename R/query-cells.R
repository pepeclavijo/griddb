#' Retrieve grid cells for a political/administrative unit, masked for crop presence
#'
#' This is the primary entry point for pulling a set of simulation-ready
#' cells: given an administrative unit (by ID or by name) and a minimum
#' crop area fraction, returns the matching grid cells with their
#' geometry and frac_area. No live geometry intersection happens here --
#' both the admin join and the crop mask join are pre-computed lookups
#' keyed on cell_id, so this is fast regardless of admin unit size.
#'
#' @param con A DBI connection
#' @param resolution_arcmin Numeric resolution of the grid to query
#' @param admin_level Character, e.g. "ADM0", "ADM1", "customer_region"
#' @param admin_id Character admin_id to match (provide this OR admin_name)
#' @param admin_name Character admin_name to match (provide this OR admin_id)
#' @param crop Character crop label to filter on, default "cropland"
#' @param min_frac_area Numeric minimum crop area fraction to include a
#'   cell, default 0.05. Set to 0 (or NULL to skip the crop join
#'   entirely) for admin-only queries with no crop filter.
#' @param mask_source Character, restrict to a specific mask source/version.
#'   If NULL, all matching mask_source rows are returned (will produce
#'   duplicate cell_id rows if multiple sources are loaded -- specify
#'   this explicitly once more than one source exists).
#' @return sf object with cell_id, lon_center, lat_center, geometry, frac_area
#' @export
get_simulation_cells <- function(con, resolution_arcmin, admin_level,
                                  admin_id = NULL, admin_name = NULL,
                                  crop = "cropland", min_frac_area = 0.05,
                                  mask_source = NULL) {
  if (is.null(admin_id) && is.null(admin_name)) {
    stop("Provide either admin_id or admin_name", call. = FALSE)
  }
  if (!is.null(admin_id) && !is.null(admin_name)) {
    stop("Provide only one of admin_id or admin_name, not both", call. = FALSE)
  }
  if (!is.null(admin_name)) {
    admin_id <- resolve_admin_id(con, admin_level, admin_name)
  }

  table_name <- grid_table_name(resolution_arcmin)
  if (!DBI::dbExistsTable(con, c("grids", table_name))) {
    stop("Grid table grids.", table_name, " does not exist.", call. = FALSE)
  }

  skip_crop_filter <- is.null(crop) || is.null(min_frac_area)

  crop_select <- if (skip_crop_filter) "NULL::real AS frac_area" else "m.frac_area"
  crop_join <- if (skip_crop_filter) "" else "JOIN masks.crop_presence m ON g.cell_id = m.cell_id"
  crop_where <- if (skip_crop_filter) "" else sprintf(
    "AND m.crop = %s AND m.frac_area >= %s",
    DBI::dbQuoteString(con, crop), min_frac_area
  )
  mask_source_where <- if (!skip_crop_filter && !is.null(mask_source)) sprintf(
    "AND m.mask_source = %s", DBI::dbQuoteString(con, mask_source)
  ) else ""

  query <- sprintf("
    SELECT g.cell_id, g.lon_center, g.lat_center, g.geometry, %s
    FROM grids.%s g
    JOIN masks.cell_admin a ON g.cell_id = a.cell_id
    %s
    WHERE a.admin_level = %s
      AND a.admin_id = %s
      %s
      %s
    ORDER BY g.cell_id;
  ", crop_select, table_name, crop_join,
     DBI::dbQuoteString(con, admin_level), DBI::dbQuoteString(con, admin_id),
     crop_where, mask_source_where)

  result <- sf::st_read(con, query = query, quiet = TRUE)

  if (nrow(result) == 0) {
    warning(
      "Query returned 0 cells for admin_level = '", admin_level,
      "', admin_id = '", admin_id, "'. This may indicate the admin unit ",
      "has no cells in this grid table, the crop mask join used the wrong ",
      "mask_source/year, or min_frac_area filtered everything out.",
      call. = FALSE
    )
  }

  result
}
