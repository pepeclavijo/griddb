#' Construct the standardized table name for a grid resolution
#'
#' This is the single source of truth for how resolution values map to
#' PostGIS table names. Every other function that needs to reference a
#' grid table should call this rather than reimplementing the naming logic.
#'
#' @param resolution_arcmin Numeric resolution in arcminutes (e.g. 0.00833, 15)
#' @return Character table name, e.g. "cells_0_00833_arcmin"
#' @export
#'
#' @examples
#' grid_table_name(15)
#' grid_table_name(0.00833)
grid_table_name <- function(resolution_arcmin) {
  if (!is.numeric(resolution_arcmin) || length(resolution_arcmin) != 1) {
    stop("resolution_arcmin must be a single numeric value", call. = FALSE)
  }
  if (resolution_arcmin <= 0) {
    stop("resolution_arcmin must be positive", call. = FALSE)
  }

  res_str <- format(resolution_arcmin, trim = TRUE, scientific = FALSE)

  # Only strip trailing zeros if there's a decimal point -- this must
  # never touch whole numbers (e.g. "10" must stay "10", not become "1")
  if (grepl("\\.", res_str)) {
    res_str <- sub("0+$", "", res_str)   # trim trailing zeros after the decimal
    res_str <- sub("\\.$", "", res_str)  # drop a dangling trailing "."
  }

  res_str <- gsub("\\.", "_", res_str)

  paste0("cells_", res_str, "_arcmin")
}

#' Construct the standardized table name for a cell hierarchy table
#'
#' @param fine_arcmin Numeric resolution of the finer grid in arcminutes
#' @param coarse_arcmin Numeric resolution of the coarser grid in arcminutes
#' @return Character table name, e.g. "cell_hierarchy_0_5_to_15_arcmin"
#' @export
hierarchy_table_name <- function(fine_arcmin, coarse_arcmin) {
  if (fine_arcmin >= coarse_arcmin) {
    stop("fine_arcmin must be smaller than coarse_arcmin", call. = FALSE)
  }
  fine_str <- gsub("cells_|_arcmin", "", grid_table_name(fine_arcmin))
  coarse_str <- gsub("cells_|_arcmin", "", grid_table_name(coarse_arcmin))
  paste0("cell_hierarchy_", fine_str, "_to_", coarse_str, "_arcmin")
}
