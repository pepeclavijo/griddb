#' Update the crop presence mask for cells in a grid table
#'
#' Aggregates a crop mask raster onto an existing grid by computing,
#' per cell, the fraction of that cell's area under cropland (or a
#' specific crop). Requires the 'terra' package.
#'
#' Two raster styles are supported, controlled by `raster_type`:
#'
#' \describe{
#'   \item{"classified"}{Each pixel holds a discrete category code
#'     (e.g. ESA WorldCover, where pixel value 40 = cropland). Pixels
#'     matching `crop_class_values` are binarized to 1, others to 0,
#'     then averaged per cell to get a fraction.}
#'   \item{"percent_area"}{Each pixel holds a continuous percent (0-100)
#'     of that pixel's area under cropland (e.g. the cropland.area.nc4
#'     style raster used in the legacy pipeline, where varname =
#'     "area"). Cropland area per pixel is computed as
#'     (value/100) * pixel_area, summed across all pixels within a
#'     cell, then divided by the cell's own total area to give a
#'     fraction -- matching the legacy 1_makePolygons_ric.R logic but
#'     completing the final step (that script kept absolute area,
#'     not a fraction; griddb stores frac_area for comparability across
#'     cell sizes/resolutions).}
#' }
#'
#' @param con A DBI connection
#' @param raster_path Path to a crop mask raster (e.g. ESA WorldCover, SPAM,
#'   or a percent-area raster like cropland.area.nc4)
#' @param resolution_arcmin Numeric resolution of the grid table to aggregate onto
#' @param crop Character crop label, default "cropland" for a generic mask
#' @param mask_source Character label for provenance, e.g. "ESA_WorldCover_2021"
#' @param mask_year Integer year the mask represents, optional
#' @param raster_type Either "classified" (default) or "percent_area".
#'   See Details above.
#' @param crop_class_values Required if `raster_type = "classified"`.
#'   Integer vector of raster values that count as "cropland" / the
#'   crop of interest (depends on the source raster's classification
#'   scheme -- check its legend). Ignored for "percent_area".
#' @param raster_var Optional. If the raster file has multiple
#'   variables/subdatasets (common for NetCDF), the variable name to
#'   read, e.g. "area". Passed to \code{terra::rast(raster_path, subds = raster_var)}.
#' @param admin_level,admin_id Optional: restrict aggregation to cells
#'   within a given admin unit, to avoid processing a global raster when
#'   only one country/region's cells exist in the grid table
#' @return Invisibly, the number of rows inserted
#' @export
update_crop_mask <- function(con, raster_path, resolution_arcmin,
                              crop = "cropland", mask_source,
                              mask_year = NA_integer_,
                              raster_type = c("classified", "percent_area"),
                              crop_class_values = NULL,
                              raster_var = NULL,
                              admin_level = NULL, admin_id = NULL) {
  raster_type <- match.arg(raster_type)

  if (!requireNamespace("terra", quietly = TRUE)) {
    stop("Package 'terra' is required for update_crop_mask()", call. = FALSE)
  }
  if (raster_type == "classified" && is.null(crop_class_values)) {
    stop("crop_class_values is required when raster_type = 'classified'", call. = FALSE)
  }

  table_name <- grid_table_name(resolution_arcmin)
  if (!DBI::dbExistsTable(con, DBI::Id(schema = "grids", table = table_name))) {
    stop("Grid table grids.", table_name, " does not exist.", call. = FALSE)
  }

  admin_filter <- ""
  if (!is.null(admin_level) && !is.null(admin_id)) {
    admin_filter <- sprintf("
      JOIN masks.cell_admin a ON g.cell_id = a.cell_id
        AND a.admin_level = %s AND a.admin_id = %s",
      DBI::dbQuoteString(con, admin_level), DBI::dbQuoteString(con, admin_id)
    )
  }

  cells <- sf::st_read(con, query = sprintf("
    SELECT g.cell_id, g.geometry
    FROM grids.%s g
    %s;
  ", table_name, admin_filter))

  if (nrow(cells) == 0) {
    warning("No cells found to aggregate the crop mask onto.", call. = FALSE)
    return(invisible(0))
  }

  r <- if (!is.null(raster_var)) {
    terra::rast(raster_path, subds = raster_var)
  } else {
    terra::rast(raster_path)
  }

  # Crop to the cells' extent (with a small buffer) before extracting --
  # without this, terra::extract() can end up scanning far more of a
  # large global raster than necessary, which is dramatically slower
  # for small regions like a single country.
  cells_bbox <- sf::st_bbox(cells)
  buffer_deg <- (resolution_arcmin / 60) * 2  # pad by ~2 cells' width
  crop_extent <- terra::ext(
    cells_bbox["xmin"] - buffer_deg, cells_bbox["xmax"] + buffer_deg,
    cells_bbox["ymin"] - buffer_deg, cells_bbox["ymax"] + buffer_deg
  )
  r <- terra::crop(r, crop_extent)

  cells_vect <- terra::vect(cells)

  if (raster_type == "classified") {
    binary_mask <- terra::classify(r, cbind(crop_class_values, 1), others = 0)
    frac <- terra::extract(binary_mask, cells_vect, fun = mean, na.rm = TRUE)
    frac_vals <- frac[, 2]
    frac_vals[is.na(frac_vals)] <- 0
    cells$frac_area <- frac_vals

  } else {
    # percent_area: pixel values are 0-100 percent of that pixel's
    # area under cropland. Convert to absolute cropland area per
    # pixel, sum within each cell, then divide by the cell's own
    # total geodesic area to get a fraction -- mirrors the legacy
    # script's (value/100)*cellSize(...) step, completed with a final
    # normalization by cell area.
    pixel_area <- terra::cellSize(r, unit = "m")
    cropland_area_per_pixel <- (r / 100) * pixel_area

    cropland_area_sum <- terra::extract(cropland_area_per_pixel, cells_vect,
                                          fun = sum, na.rm = TRUE)
    cell_total_area_m2 <- as.numeric(sf::st_area(
      sf::st_transform(cells, utm_zone_for_geometry(cells))
    ))

    frac <- cropland_area_sum[, 2] / cell_total_area_m2
    # A cell with no valid underlying raster data (e.g. right at the
    # edge of the cropped extent, or a region with no data in the
    # source raster) should be treated as zero cropland, not left as
    # NA -- the database column is NOT NULL, and "no data" is a
    # reasonable interpretation of "no known cropland" for this purpose.
    frac[is.na(frac)] <- 0
    cells$frac_area <- pmin(frac, 1)
  }

  cells$crop <- crop
  cells$mask_source <- mask_source
  cells$mask_year <- mask_year

  result_df <- as.data.frame(cells)[, c("cell_id", "crop", "frac_area",
                                          "mask_source", "mask_year")]

  staging_name <- "tmp_crop_presence"
  DBI::dbWriteTable(con, DBI::Id(schema = "staging", table = staging_name), result_df,
                     overwrite = TRUE)

  n_inserted <- DBI::dbExecute(con, sprintf("
    INSERT INTO masks.crop_presence (cell_id, crop, frac_area, mask_source, mask_year)
    SELECT cell_id, crop, frac_area, mask_source, mask_year
    FROM staging.%s
    ON CONFLICT (cell_id, crop, mask_source) DO UPDATE
      SET frac_area = EXCLUDED.frac_area, mask_year = EXCLUDED.mask_year;
  ", staging_name))

  DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS staging.%s;", staging_name))

  message("Inserted/updated ", n_inserted, " crop_presence rows (crop = '", crop, "')")
  invisible(n_inserted)
}
