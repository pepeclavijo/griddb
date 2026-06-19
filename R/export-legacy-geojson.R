#' Determine the appropriate UTM zone EPSG code for a given geometry
#'
#' Picks the UTM zone (north or south hemisphere as appropriate) whose
#' central meridian is closest to the geometry's centroid longitude.
#' This gives a reasonably accurate equal-area-ish projection for area
#' calculations local to the geometry's location, which matters for
#' countries spanning multiple UTM zones (e.g. Kazakhstan spans zones
#' 39N-45N) where a single hardcoded zone would distort area unevenly
#' across the country.
#'
#' @param geom sf/sfc object, WGS84 (EPSG:4326)
#' @return Integer EPSG code for the appropriate WGS84 UTM zone
#' @export
utm_zone_for_geometry <- function(geom) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required", call. = FALSE)
  }
  centroid <- sf::st_coordinates(sf::st_centroid(sf::st_union(sf::st_geometry(geom))))
  lon <- centroid[1, "X"]
  lat <- centroid[1, "Y"]

  zone <- floor((lon + 180) / 6) + 1
  if (lat >= 0) {
    32600 + zone   # northern hemisphere UTM EPSG codes
  } else {
    32700 + zone   # southern hemisphere UTM EPSG codes
  }
}

#' Export grid cells to the legacy DSSAT-pipeline GeoJSON format
#'
#' Produces a GeoJSON FeatureCollection matching the format the existing
#' DSSAT-running pipeline expects: one Feature per cell, MultiPolygon
#' geometry, and properties `name` (sequentially numbered within
#' `reporting_unit`, e.g. "Aqmola ; 1"), `area` (square meters), and
#' `reporting_unit`.
#'
#' By default, cells are not geometrically clipped to a boundary --
#' each cell is included whole if its centroid falls within the named
#' admin/reporting unit (this is how cells were already assigned in
#' \code{masks.cell_admin} via \code{\link{update_admin_boundaries}}).
#' This avoids the sliver fragments produced by the legacy
#' intersect-based workflow, since griddb cells are already
#' non-overlapping and stable.
#'
#' If exact-edge clipping against an arbitrary boundary is required
#' (e.g. to reproduce legacy output precisely, or because the delivery
#' boundary isn't one of the admin units already in cell_admin), pass
#' a `clip_boundary` sf/sfc polygon and clipping will be performed with
#' \code{sf::st_intersection()}.
#'
#' @param cells sf object as returned by \code{\link{get_simulation_cells}},
#'   must include `cell_id` and `geometry`
#' @param reporting_unit Character. Single value used for every feature's
#'   `reporting_unit` property and as the prefix for `name`. If NULL,
#'   `reporting_unit` is taken from the `admin_name`/`admin_id` already
#'   used to fetch `cells` (must be supplied by the caller; not inferred
#'   automatically since `cells` does not carry admin columns by default).
#' @param clip_boundary Optional sf/sfc polygon, WGS84. If supplied,
#'   cells are intersected against this boundary (producing fragments
#'   where cells cross the edge) rather than included whole.
#' @param output_path Character path to write the GeoJSON to. If NULL,
#'   the FeatureCollection is returned as an sf object without writing
#'   a file.
#' @param area_crs Integer EPSG code of a projected CRS to use for area
#'   calculation, since area in square meters cannot be computed
#'   directly from geographic (WGS84) coordinates. Default NULL
#'   auto-detects the appropriate local UTM zone from the cells'
#'   centroid via \code{\link{utm_zone_for_geometry}} -- this is more
#'   accurate than a single fixed projection (e.g. Web Mercator) for
#'   countries spanning multiple UTM zones. Supply an explicit EPSG
#'   code to override.
#' @return Invisibly, the sf object written (or returned if output_path is NULL)
#' @export
export_cells_to_legacy_geojson <- function(cells, reporting_unit,
                                            clip_boundary = NULL,
                                            output_path = NULL,
                                            area_crs = NULL) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required", call. = FALSE)
  }
  if (!"cell_id" %in% names(cells)) {
    stop("cells must include a cell_id column", call. = FALSE)
  }
  if (missing(reporting_unit) || is.null(reporting_unit)) {
    stop("reporting_unit must be supplied", call. = FALSE)
  }

  geoms <- sf::st_geometry(cells)

  if (!is.null(clip_boundary)) {
    boundary_union <- sf::st_union(sf::st_geometry(clip_boundary))
    cells <- sf::st_sf(
      cell_id = cells$cell_id,
      geometry = suppressWarnings(sf::st_intersection(geoms, boundary_union))
    )
    # st_intersection can drop empty results or split a cell into
    # multiple pieces; drop empties, keep all surviving fragments
    cells <- cells[!sf::st_is_empty(cells), ]
  }

  if (is.null(area_crs)) {
    area_crs <- utm_zone_for_geometry(cells)
    message("Using auto-detected UTM zone EPSG:", area_crs, " for area calculation")
  }

  # Compute area in square meters via a projected CRS -- WGS84 degrees
  # cannot be used directly for area calculations
  areas_m2 <- as.numeric(sf::st_area(sf::st_transform(cells, area_crs)))

  out <- sf::st_sf(
    name = paste0(reporting_unit, " ; ", seq_len(nrow(cells))),
    area = areas_m2,
    reporting_unit = reporting_unit,
    geometry = sf::st_cast(sf::st_geometry(cells), "MULTIPOLYGON")
  )

  if (!is.null(output_path)) {
    sf::st_write(out, output_path, driver = "GeoJSON",
                 delete_dsn = TRUE, quiet = TRUE)
    message("Wrote ", nrow(out), " features to ", output_path)
  }

  invisible(out)
}
