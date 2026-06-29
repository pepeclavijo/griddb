#' Find the grid cell containing a given point (or set of points)
#'
#' For the point/field-level use case -- a customer's farm location,
#' a single lat/lon, or a small polygon's centroid -- rather than a
#' regional/aggregate query. Returns the cell whose extent contains
#' the point, found via direct computation
#' (\code{\link{compute_global_cell_id}}), not a spatial nearest-
#' neighbor search: since the grid's cell boundaries are known and
#' fixed, the containing cell can be computed exactly from the
#' point's coordinates alone, with no distance calculation needed.
#'
#' This deliberately does not reshape or carve cell geometry around
#' the point -- consistent with standard practice in this modeling
#' tradition (DSSAT/pSIMS/AgMIP), a grid cell is a representative
#' point sample of its surrounding area, and the customer's actual
#' field (assumed small relative to the cell) is simply assigned that
#' cell's value, the same way a coarse climate/weather grid is treated
#' as constant within each cell.
#'
#' @param con A DBI connection
#' @param resolution_arcmin Numeric resolution of the grid to query
#' @param lon,lat Numeric vectors of longitude/latitude (WGS84,
#'   decimal degrees), or provide `points` instead
#' @param points Optional sf/sfc POINT or POLYGON object. If polygons
#'   are supplied, each one's centroid is used as the query point
#'   (since the goal is "which cell does this small area best
#'   correspond to", not a geometry operation). Provide this OR
#'   lon/lat, not both.
#' @param crop,min_frac_area,mask_source Passed through to the
#'   underlying crop-presence join, same meaning as in
#'   \code{\link{get_simulation_cells}}. Set `crop = NULL` to skip
#'   the crop mask join and just return cell geometry/centroid.
#' @return sf object with one row per input point: `cell_id`,
#'   `lon_center`, `lat_center`, `frac_area` (if crop mask requested),
#'   `query_lon`, `query_lat` (the original input coordinates, for
#'   reference), and `geometry` (the matched cell's polygon)
#' @export
#'
#' @examples
#' \dontrun{
#' # A single farm location
#' get_nearest_cell(con, resolution_arcmin = 15, lon = 77.2, lat = 43.9,
#'                   mask_source = "cropland_area_nc4")
#'
#' # Several customer field locations at once
#' get_nearest_cell(con, resolution_arcmin = 15,
#'                   lon = c(77.2, 78.1), lat = c(43.9, 44.5),
#'                   mask_source = "cropland_area_nc4")
#'
#' # A small field polygon -- its centroid is used
#' get_nearest_cell(con, resolution_arcmin = 15, points = my_field_boundary,
#'                   mask_source = "cropland_area_nc4")
#' }
get_nearest_cell <- function(con, resolution_arcmin, lon = NULL, lat = NULL,
                              points = NULL, crop = "cropland",
                              min_frac_area = NULL, mask_source = NULL) {
  if (!is.null(points) && (!is.null(lon) || !is.null(lat))) {
    stop("Provide either points OR lon/lat, not both", call. = FALSE)
  }
  if (is.null(points) && (is.null(lon) || is.null(lat))) {
    stop("Provide either points, or both lon and lat", call. = FALSE)
  }

  if (!is.null(points)) {
    if (!requireNamespace("sf", quietly = TRUE)) {
      stop("Package 'sf' is required when using the points argument", call. = FALSE)
    }
    geom_types <- unique(sf::st_geometry_type(points))
    if (!all(geom_types %in% c("POINT", "MULTIPOINT"))) {
      # Polygons (or anything else): use centroid, per documented behavior
      points <- sf::st_centroid(points)
    }
    coords <- sf::st_coordinates(points)
    lon <- coords[, "X"]
    lat <- coords[, "Y"]
  }

  if (length(lon) != length(lat)) {
    stop("lon and lat must be the same length", call. = FALSE)
  }

  query_cell_ids <- compute_global_cell_id(lon, lat, resolution_arcmin)

  table_name <- grid_table_name(resolution_arcmin)
  if (!DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = table_name))) {
    stop("Grid table grids.", table_name, " does not exist.", call. = FALSE)
  }

  skip_crop_filter <- is.null(crop)

  crop_select <- if (skip_crop_filter) "NULL::real AS frac_area" else "m.frac_area"
  crop_join <- if (skip_crop_filter) "" else "LEFT JOIN masks.crop_presence m ON g.cell_id = m.cell_id"
  crop_where <- if (skip_crop_filter || is.null(mask_source)) "" else sprintf(
    "AND (m.mask_source = %s OR m.mask_source IS NULL)",
    DBI::dbQuoteString(con, mask_source)
  )
  crop_filter_clause <- if (skip_crop_filter || is.null(min_frac_area)) "" else sprintf(
    "AND (m.frac_area >= %s OR m.frac_area IS NULL)", min_frac_area
  )

  query <- sprintf("
    SELECT g.cell_id, g.lon_center, g.lat_center, g.geometry, %s
    FROM grids.%s g
    %s
    WHERE g.cell_id IN (%s)
    %s
    %s
    %s;
  ", crop_select, table_name, crop_join,
     paste(unique(query_cell_ids), collapse = ", "),
     if (!skip_crop_filter) sprintf("AND (m.crop = %s OR m.crop IS NULL)",
                                     DBI::dbQuoteString(con, crop)) else "",
     crop_where, crop_filter_clause)

  result <- sf::st_read(con, query = query, quiet = TRUE)

  if (nrow(result) == 0) {
    warning(
      "No matching cell(s) found for the supplied point(s) at resolution_arcmin = ",
      resolution_arcmin, ". This may mean the grid does not cover this location, ",
      "or the crop mask filter excluded it.", call. = FALSE
    )
    return(result)
  }

  # Cast away from integer64 (a possible round-trip artifact of
  # PostGIS's BIGINT type via RPostgres/sf::st_read()) so cell_id
  # comparisons/matching below are reliable, and so callers don't
  # silently inherit a type that some downstream tools (e.g. JSON
  # serializers) can mishandle.
  result$cell_id <- as.numeric(result$cell_id)

  # Map each ORIGINAL query point back to its result row, preserving
  # input order and length (including duplicates if multiple input
  # points happen to fall in the same cell).
  match_idx <- match(query_cell_ids, result$cell_id)
  out <- result[match_idx, ]
  out$query_lon <- lon
  out$query_lat <- lat

  if (any(is.na(match_idx))) {
    warning(sum(is.na(match_idx)), " of ", length(query_cell_ids),
            " point(s) had no matching cell (likely excluded by the crop mask filter ",
            "or outside the grid's coverage).", call. = FALSE)
  }

  out
}
