#' Set up a grid and admin boundary entry for a named region, in one call
#'
#' Convenience wrapper around the boundary-loading, grid generation,
#' and admin ingestion steps that otherwise have to be done by hand
#' for every new region/resolution combination. Given a path to an
#' admin boundary file (shapefile, geopackage, or any format
#' \code{sf::st_read()} supports) and the name of a region within it,
#' this loads the file, filters to the requested region, cleans the
#' geometry, generates the grid, and ingests the admin boundary --
#' all at the requested resolution.
#'
#' This function does not have a built-in country/region name
#' registry -- it always requires a path to the actual boundary file,
#' since the geometry has to come from somewhere. What it removes is
#' the manual st_read() / filter() / st_transform() / st_make_valid()
#' / populate_grid_for_boundary() / update_admin_boundaries() sequence
#' that would otherwise need to be repeated for every region.
#'
#' @param con A DBI connection
#' @param boundary_path Path to an admin boundary file readable by
#'   \code{sf::st_read()} (shapefile .shp, geopackage .gpkg, etc.)
#' @param name_col Character name of the column in the boundary file
#'   holding the region's display name (e.g. "ADM1_EN")
#' @param region_name Character value to filter \code{name_col} on
#'   (e.g. "Almaty Region"). Case-sensitive exact match against the
#'   file's actual values -- if unsure of the exact spelling, first
#'   call with \code{region_name = NULL} to print available values.
#' @param resolution_arcmin Numeric grid resolution in arcminutes
#' @param admin_level Character label for the ingested admin level,
#'   e.g. "ADM1"
#' @param id_col Character name of the column holding the region's
#'   stable id (e.g. "ADM1_PCODE"). Used as \code{admin_id}.
#' @param parent_id_col Optional character name of a column holding
#'   the parent unit's id (e.g. "ADM0_PCODE"), used as \code{parent_id}.
#'   If NULL, \code{parent_id} is set to NA.
#' @param source Character label for provenance, passed through to
#'   \code{\link{update_admin_boundaries}}
#' @return Invisibly, a list with \code{boundary} (the filtered,
#'   cleaned sf object), \code{grid_table} (the resolution's table
#'   name), and \code{admin_id} (the resolved admin_id for the region)
#' @export
#'
#' @examples
#' \dontrun{
#' setup_region_grid(
#'   con,
#'   boundary_path = "data-raw/boundaries/kaz_adm1/kaz_admbnda_adm1_unhcr_2023.shp",
#'   name_col = "ADM1_EN", region_name = "Almaty Region",
#'   resolution_arcmin = 30,
#'   admin_level = "ADM1", id_col = "ADM1_PCODE", parent_id_col = "ADM0_PCODE",
#'   source = "geoBoundaries"
#' )
#' }
setup_region_grid <- function(con, boundary_path, name_col, region_name,
                               resolution_arcmin, admin_level,
                               id_col, parent_id_col = NULL,
                               source = NA_character_) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required", call. = FALSE)
  }
  if (!file.exists(boundary_path)) {
    stop("boundary_path does not exist: ", boundary_path, call. = FALSE)
  }

  boundary_all <- sf::st_read(boundary_path, quiet = TRUE)

  if (!name_col %in% names(boundary_all)) {
    stop("name_col '", name_col, "' not found. Available columns: ",
         paste(names(boundary_all), collapse = ", "), call. = FALSE)
  }

  if (is.null(region_name)) {
    message("Available values in '", name_col, "':")
    print(sort(unique(boundary_all[[name_col]])))
    return(invisible(NULL))
  }

  boundary_region <- boundary_all[boundary_all[[name_col]] == region_name, ]

  if (nrow(boundary_region) == 0) {
    stop("No rows found where ", name_col, " == '", region_name, "'. ",
         "Call with region_name = NULL to see available values.", call. = FALSE)
  }

  # Standard cleanup sequence: reproject to WGS84 (boundary files are
  # often delivered in a projected CRS like Web Mercator) and repair
  # any topology issues (a common real-world shapefile problem -- see
  # PROCESS_NARRATIVE.md).
  boundary_region <- sf::st_transform(boundary_region, 4326)
  boundary_region <- sf::st_make_valid(boundary_region)

  grid_table <- populate_grid_for_boundary(con, resolution_arcmin = resolution_arcmin,
                                            boundary = boundary_region)

  if (!id_col %in% names(boundary_region)) {
    stop("id_col '", id_col, "' not found. Available columns: ",
         paste(names(boundary_region), collapse = ", "), call. = FALSE)
  }

  boundary_for_ingest <- boundary_region
  boundary_for_ingest$admin_id <- boundary_region[[id_col]]
  boundary_for_ingest$admin_name <- boundary_region[[name_col]]
  boundary_for_ingest$parent_id <- if (!is.null(parent_id_col)) {
    if (!parent_id_col %in% names(boundary_region)) {
      stop("parent_id_col '", parent_id_col, "' not found. Available columns: ",
           paste(names(boundary_region), collapse = ", "), call. = FALSE)
    }
    boundary_region[[parent_id_col]]
  } else {
    NA_character_
  }

  update_admin_boundaries(con, boundary_for_ingest, admin_level = admin_level,
                           resolution_arcmin = resolution_arcmin, source = source)

  invisible(list(
    boundary = boundary_region,
    grid_table = grid_table,
    admin_id = unique(boundary_for_ingest$admin_id)
  ))
}
