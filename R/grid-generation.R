#' Compute the global cell ID for a given lon/lat at a given resolution
#'
#' This is the canonical formula for cell identity in the griddb system.
#' IDs are assigned in row-major order starting at 1 in the upper-left
#' corner of the global WGS84 extent (-180, 90) and proceeding left to
#' right, top to bottom. Because the formula is purely a function of
#' position and resolution (not of "what's in the database"), cells
#' computed for a single country today will retain the same ID if the
#' full global grid is ever materialized later.
#'
#' @param lon Numeric longitude(s) of cell center or any point within the cell
#' @param lat Numeric latitude(s) of cell center or any point within the cell
#' @param resolution_arcmin Numeric grid resolution in arcminutes
#' @return Integer (or numeric, for very fine resolutions) global cell ID
#' @export
#'
#' @examples
#' compute_global_cell_id(-180, 90, resolution_arcmin = 5)  # 1, upper-left
compute_global_cell_id <- function(lon, lat, resolution_arcmin) {
  res_deg <- resolution_arcmin / 60
  ncols <- round(360 / res_deg)

  col <- floor((lon + 180) / res_deg)
  row <- floor((90 - lat) / res_deg)

  # Guard against floating point edge cases at exact boundaries
  col <- pmin(pmax(col, 0), ncols - 1)
  nrows <- round(180 / res_deg)
  row <- pmin(pmax(row, 0), nrows - 1)

  row * ncols + col + 1
}

#' Generate grid cell geometries for a bounding box at a given resolution
#'
#' Unlike generating the full global grid, this only materializes cells
#' within the supplied bounding box, using compute_global_cell_id() so
#' that IDs remain globally consistent regardless of scope. This is the
#' function used for the country-by-country / region-by-region workflow.
#'
#' @param resolution_arcmin Numeric grid resolution in arcminutes
#' @param xmin,ymin,xmax,ymax Numeric bounding box in WGS84 degrees
#' @return sf object with cell_id, lon_center, lat_center, resolution_arcmin, geometry
#' @export
generate_grid_bbox <- function(resolution_arcmin, xmin, ymin, xmax, ymax) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required for generate_grid_bbox()", call. = FALSE)
  }

  res_deg <- resolution_arcmin / 60

  # Snap the bounding box outward to the global grid lines so cells
  # generated for adjacent regions always share exact edges.
  xmin_snap <- floor((xmin + 180) / res_deg) * res_deg - 180
  xmax_snap <- ceiling((xmax + 180) / res_deg) * res_deg - 180
  ymin_snap <- floor((90 - ymax) / res_deg) * res_deg          # note: lat inverted
  ymax_snap <- ceiling((90 - ymin) / res_deg) * res_deg

  lons <- seq(xmin_snap, xmax_snap - res_deg, by = res_deg)
  lat_top_offsets <- seq(ymin_snap, ymax_snap - res_deg, by = res_deg)
  lats_top <- 90 - lat_top_offsets   # convert back to actual latitude (top edge of each row)

  grid_coords <- expand.grid(lon = lons, lat_top = lats_top)
  grid_coords$lat_bottom <- grid_coords$lat_top - res_deg
  grid_coords$lon_right <- grid_coords$lon + res_deg

  grid_coords$lon_center <- grid_coords$lon + res_deg / 2
  grid_coords$lat_center <- grid_coords$lat_top - res_deg / 2

  grid_coords$cell_id <- compute_global_cell_id(
    grid_coords$lon_center, grid_coords$lat_center, resolution_arcmin
  )

  polys <- vector("list", nrow(grid_coords))
  for (i in seq_len(nrow(grid_coords))) {
    lon <- grid_coords$lon[i]
    lat_top <- grid_coords$lat_top[i]
    lat_bottom <- grid_coords$lat_bottom[i]
    lon_right <- grid_coords$lon_right[i]

    polys[[i]] <- sf::st_polygon(list(matrix(c(
      lon,       lat_bottom,
      lon_right, lat_bottom,
      lon_right, lat_top,
      lon,       lat_top,
      lon,       lat_bottom
    ), ncol = 2, byrow = TRUE)))
  }

  sf::st_sf(
    cell_id           = grid_coords$cell_id,
    lon_center        = grid_coords$lon_center,
    lat_center        = grid_coords$lat_center,
    resolution_arcmin = resolution_arcmin,
    geometry          = sf::st_sfc(polys, crs = 4326)
  )
}

#' Generate grid cells clipped to an arbitrary polygon (e.g. a country boundary)
#'
#' Generates the bounding-box grid first (so IDs are computed correctly),
#' then filters to cells that actually intersect the supplied boundary.
#' This avoids materializing cells that fall in the bbox but outside the
#' region of interest (e.g. ocean cells around a coastline).
#'
#' @param resolution_arcmin Numeric grid resolution in arcminutes
#' @param boundary sf or sfc polygon/multipolygon object, WGS84 (EPSG:4326)
#' @return sf object of grid cells intersecting the boundary
#' @export
generate_grid_for_boundary <- function(resolution_arcmin, boundary) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required for generate_grid_for_boundary()", call. = FALSE)
  }

  bbox <- sf::st_bbox(boundary)
  full_grid <- generate_grid_bbox(
    resolution_arcmin,
    xmin = bbox["xmin"], ymin = bbox["ymin"],
    xmax = bbox["xmax"], ymax = bbox["ymax"]
  )

  boundary_union <- sf::st_union(sf::st_geometry(boundary))
  intersects <- sf::st_intersects(full_grid, boundary_union, sparse = FALSE)[, 1]

  full_grid[intersects, ]
}
