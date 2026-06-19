#' Update the crop presence mask for cells in a grid table
#'
#' Aggregates a crop mask raster onto an existing grid by computing,
#' per cell, the area-weighted fraction of that cell classified as
#' cropland (or a specific crop). Requires the 'terra' package.
#'
#' @param con A DBI connection
#' @param raster_path Path to a crop mask raster (e.g. ESA WorldCover, SPAM)
#' @param resolution_arcmin Numeric resolution of the grid table to aggregate onto
#' @param crop Character crop label, default "cropland" for a generic mask
#' @param mask_source Character label for provenance, e.g. "ESA_WorldCover_2021"
#' @param mask_year Integer year the mask represents, optional
#' @param crop_class_values Integer vector of raster values that count as
#'   "cropland" / the crop of interest (depends on the source raster's
#'   classification scheme -- check its legend)
#' @param admin_level,admin_id Optional: restrict aggregation to cells
#'   within a given admin unit, to avoid processing a global raster when
#'   only one country/region's cells exist in the grid table
#' @return Invisibly, the number of rows inserted
#' @export
update_crop_mask <- function(con, raster_path, resolution_arcmin,
                              crop = "cropland", mask_source,
                              mask_year = NA_integer_,
                              crop_class_values,
                              admin_level = NULL, admin_id = NULL) {
  if (!requireNamespace("terra", quietly = TRUE)) {
    stop("Package 'terra' is required for update_crop_mask()", call. = FALSE)
  }

  table_name <- grid_table_name(resolution_arcmin)
  if (!DBI::dbExistsTable(con, c("grids", table_name))) {
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

  r <- terra::rast(raster_path)
  cells_vect <- terra::vect(cells)

  binary_mask <- terra::classify(
    r,
    cbind(crop_class_values, 1),
    others = 0
  )

  frac <- terra::extract(binary_mask, cells_vect, fun = mean, na.rm = TRUE)
  cells$frac_area <- frac[, 2]
  cells$crop <- crop
  cells$mask_source <- mask_source
  cells$mask_year <- mask_year

  result_df <- as.data.frame(cells)[, c("cell_id", "crop", "frac_area",
                                          "mask_source", "mask_year")]

  staging_name <- "tmp_crop_presence"
  DBI::dbWriteTable(con, c("staging", staging_name), result_df,
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
