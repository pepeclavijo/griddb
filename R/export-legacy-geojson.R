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

#' Attach the full administrative hierarchy path for each cell
#'
#' Looks up each cell's admin_name at multiple admin levels at once
#' (e.g. ADM0, ADM1, ADM2) and attaches a single combined path string,
#' for use as the `reporting_unit` in \code{\link{export_cells_to_legacy_geojson}}
#' when the desired naming convention embeds the full administrative
#' hierarchy rather than a single level.
#'
#' If a cell matches more than one unit at a given level (a boundary
#' cell -- see \code{\link{update_admin_boundaries}}), the first match
#' by `admin_id` is used at that level and a warning lists the
#' affected cells, since a single combined path can only record one
#' name per level per feature.
#'
#' @param con A DBI connection
#' @param cells sf object with a `cell_id` column
#' @param admin_levels Character vector of admin levels to include, in
#'   the order they should appear in the path, e.g.
#'   \code{c("ADM0", "ADM1", "ADM2")}
#' @param sep Character separator joining levels in the path, default "_"
#' @return The input `cells`, with an added `admin_path` column (the
#'   joined hierarchy string, e.g. "Kazakhstan_AlmatyRegion_Talgar")
#'   and one column per requested level (e.g. `ADM0_name`, `ADM1_name`,
#'   `ADM2_name`) for inspection/debugging
#' @export
#'
#' @examples
#' \dontrun{
#' cells <- get_simulation_cells_multi(con, resolution_arcmin = 15,
#'                                      admin_level = "ADM2",
#'                                      parent_level = "ADM1",
#'                                      parent_ids = "KAZ005")
#' cells <- attach_admin_hierarchy(con, cells, admin_levels = c("ADM0", "ADM1", "ADM2"))
#' export_cells_to_legacy_geojson(cells, reporting_unit = cells$admin_path,
#'                                 output_path = "almaty_by_district.geojson")
#' # name becomes e.g. "Kazakhstan_AlmatyRegion_Talgar ; 224238"
#' }
attach_admin_hierarchy <- function(con, cells, admin_levels, sep = "_") {
  if (!"cell_id" %in% names(cells)) {
    stop("cells must include a cell_id column", call. = FALSE)
  }
  if (length(admin_levels) == 0) {
    stop("admin_levels must contain at least one level", call. = FALSE)
  }

  # Normalize cell_id away from integer64 (a possible round-trip
  # artifact of PostGIS BIGINT via RPostgres) so match() below behaves
  # reliably regardless of how cells/lookup happened to be typed.
  cells$cell_id <- as.numeric(cells$cell_id)

  level_name_cols <- character(length(admin_levels))

  for (i in seq_along(admin_levels)) {
    lvl <- admin_levels[i]
    col_name <- paste0(lvl, "_name")
    level_name_cols[i] <- col_name

    lookup <- DBI::dbGetQuery(con, sprintf("
      SELECT cell_id, admin_id, admin_name FROM masks.cell_admin
      WHERE admin_level = %s AND cell_id IN (%s)
      ORDER BY cell_id, admin_id;
    ", DBI::dbQuoteString(con, lvl),
       paste(unique(cells$cell_id), collapse = ", ")))
    lookup$cell_id <- as.numeric(lookup$cell_id)

    n_before <- nrow(lookup)
    lookup <- lookup[!duplicated(lookup$cell_id), ]
    n_dropped <- n_before - nrow(lookup)
    if (n_dropped > 0) {
      warning(n_dropped, " cell(s) matched more than one admin unit at level '",
              lvl, "' -- using the first match (lowest admin_id) for each.",
              call. = FALSE)
    }

    cells[[col_name]] <- lookup$admin_name[match(cells$cell_id, lookup$cell_id)]

    if (any(is.na(cells[[col_name]]))) {
      warning(sum(is.na(cells[[col_name]])), " cell(s) had no matching admin_name ",
              "at level '", lvl, "' -- these will have NA in the combined admin_path.",
              call. = FALSE)
    }
  }

  # Sanitize each level's name for safe use in a path-like string:
  # remove spaces and anything that isn't a letter/digit, since the
  # combined path is meant to read as one clean token rather than a
  # string with embedded spaces.
  #
  # IMPORTANT: explicitly drop geometry before subsetting to the name
  # columns. sf objects have "sticky geometry" -- subsetting with `[`
  # on a column-name vector silently keeps the geometry column
  # attached even when it wasn't requested, which would otherwise feed
  # raw polygon coordinate text into gsub()/paste() below and produce
  # garbage values in admin_path for some rows.
  cells_no_geom <- sf::st_drop_geometry(cells)
  sanitized <- lapply(cells_no_geom[level_name_cols], function(col) {
    gsub("[^A-Za-z0-9]", "", col)
  })

  cells$admin_path <- do.call(paste, c(sanitized, sep = sep))

  cells
}
#'
#' Looks up each cell's admin_name at a given admin_level and attaches
#' it as a new column, so the result can be passed directly as the
#' `reporting_unit` vector to \code{\link{export_cells_to_legacy_geojson}}.
#'
#' If a cell matches more than one admin unit at the given level (a
#' boundary cell -- see \code{\link{update_admin_boundaries}}), the
#' first matching name (by admin_id) is used and a warning lists which
#' cells were affected, since a per-cell export can only record one
#' reporting unit per feature.
#'
#' @param con A DBI connection
#' @param cells sf object with a `cell_id` column, e.g. from
#'   \code{\link{get_simulation_cells_multi}}
#' @param admin_level Character, e.g. "ADM2"
#' @return The input `cells`, with an added `admin_name` column
#' @export
#'
#' @examples
#' \dontrun{
#' cells <- get_simulation_cells_multi(con, resolution_arcmin = 15,
#'                                      admin_level = "ADM2",
#'                                      parent_level = "ADM1",
#'                                      parent_ids = "KAZ005")
#' cells <- attach_admin_names(con, cells, admin_level = "ADM2")
#' export_cells_to_legacy_geojson(cells, reporting_unit = cells$admin_name,
#'                                 output_path = "almaty_by_district.geojson")
#' }
attach_admin_names <- function(con, cells, admin_level) {
  if (!"cell_id" %in% names(cells)) {
    stop("cells must include a cell_id column", call. = FALSE)
  }

  # Normalize cell_id away from integer64 (a possible round-trip
  # artifact of PostGIS BIGINT via RPostgres) so match() below behaves
  # reliably regardless of how cells/lookup happened to be typed.
  cells$cell_id <- as.numeric(cells$cell_id)

  lookup <- DBI::dbGetQuery(con, sprintf("
    SELECT cell_id, admin_id, admin_name FROM masks.cell_admin
    WHERE admin_level = %s AND cell_id IN (%s)
    ORDER BY cell_id, admin_id;
  ", DBI::dbQuoteString(con, admin_level),
     paste(unique(cells$cell_id), collapse = ", ")))
  lookup$cell_id <- as.numeric(lookup$cell_id)

  n_before <- nrow(lookup)
  lookup <- lookup[!duplicated(lookup$cell_id), ]
  n_dropped <- n_before - nrow(lookup)
  if (n_dropped > 0) {
    warning(n_dropped, " cell(s) matched more than one admin unit at level '",
            admin_level, "' -- using the first match (lowest admin_id) for each. ",
            "A per-cell export can only record one reporting_unit per feature.",
            call. = FALSE)
  }

  cells$admin_name <- lookup$admin_name[match(cells$cell_id, lookup$cell_id)]

  if (any(is.na(cells$admin_name))) {
    warning(sum(is.na(cells$admin_name)), " cell(s) had no matching admin_name ",
             "at level '", admin_level, "' and will have NA reporting_unit.",
             call. = FALSE)
  }

  cells
}
#' Export grid cells to a GeoJSON file
#'
#' Produces a GeoJSON FeatureCollection with one Feature per cell and
#' MultiPolygon geometry, with properties `name`, `cell_id`, `area`
#' (square meters), and `reporting_unit` -- matching the legacy
#' DSSAT-pipeline delivery format that the existing CLI/run tool reads
#' (it populates its own `polygon_name`/`polygon_area` output columns
#' directly from `name`/`area`, and produces empty values if those
#' properties are missing, and separately expects `name` to be a
#' unique value per feature).
#'
#' `name` is now the cell's own stable, globally-meaningful `cell_id`
#' (see \code{\link{compute_global_cell_id}}), written as a CHARACTER
#' STRING (e.g. `"265996"`, not the bare number `265996`) -- some
#' downstream consumers expect `name` to be a string type, and a
#' server-side strict-typed JSON validator can otherwise reject the
#' file outright with an opaque error. `cell_id` holds the identical
#' value as a true numeric, for any downstream use that needs to do
#' arithmetic/comparison on it rather than treat it as a label.
#'
#' `reporting_unit` holds the human-readable, cosmetic label (e.g. an
#' admin hierarchy path from \code{\link{attach_admin_hierarchy}} such
#' as "Kazakhstan_AlmatyRegion_Talgar") and is NOT guaranteed unique --
#' many cells in the same district will share the same
#' `reporting_unit` value. It may also legitimately change across
#' re-exports if underlying admin boundaries are re-ingested or
#' renamed. If not supplied, it defaults to `"griddb_export"` so
#' `reporting_unit` is always populated even when no meaningful label
#' is available; pass an explicit value (or build one via
#' \code{\link{attach_admin_names}}/\code{\link{attach_admin_hierarchy}})
#' whenever a real label is available.
#'
#' For administrative context that doesn't need to be squeezed into a
#' single cosmetic label, see \code{\link{export_admin_lookup}} -- a
#' companion file/table that preserves every admin match per cell
#' (including ambiguous boundary cells) for joining on `cell_id`
#' separately, rather than collapsing into one label here.
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
#' @param cells sf object as returned by \code{\link{get_simulation_cells}}
#'   or \code{\link{get_simulation_cells_multi}}, must include `cell_id`
#'   and `geometry`
#' @param reporting_unit Either a single character string, applied to
#'   every feature, or a character vector with one value per row of
#'   `cells` (e.g. each cell's ADM2 district name via
#'   \code{\link{attach_admin_names}}, or a full admin hierarchy path
#'   via \code{\link{attach_admin_hierarchy}}). Defaults to
#'   `"griddb_export"` if not supplied, so `name`/`reporting_unit` are
#'   always populated.
#' @param clip_boundary Optional sf/sfc polygon, WGS84. If supplied,
#'   cells are intersected against this boundary (producing fragments
#'   where cells cross the edge) rather than included whole. Note: if
#'   clipping splits a cell into multiple fragments, those fragments
#'   will share the same `cell_id` -- prefer no clipping when relying
#'   on `cell_id` to uniquely identify a feature.
#' @param output_path Character path to write the GeoJSON to. If NULL,
#'   the FeatureCollection is returned as an sf object without writing
#'   a file.
#' @param area_crs Integer EPSG code of a projected CRS to use for area
#'   calculation, since area in square meters cannot be computed
#'   directly from geographic (WGS84) coordinates. Default NULL
#'   auto-detects the appropriate local UTM zone from the cells'
#'   centroid via \code{\link{utm_zone_for_geometry}}. Supply an
#'   explicit EPSG code to override.
#' @return Invisibly, the sf object written (or returned if output_path is NULL)
#' @export
#'
#' @examples
#' \dontrun{
#' # Single reporting unit for every feature:
#' export_cells_to_legacy_geojson(cells, reporting_unit = "Almaty Region",
#'                                 output_path = "almaty_grid.geojson")
#' # name = cell_id = e.g. 224238 (unique per feature); reporting_unit = "Almaty Region"
#'
#' # Per-cell admin hierarchy path, in one combined file:
#' cells_with_path <- attach_admin_hierarchy(
#'   con,
#'   get_simulation_cells_multi(con, resolution_arcmin = 15, admin_level = "ADM2",
#'                               parent_level = "ADM1", parent_ids = "KAZ005"),
#'   admin_levels = c("ADM0", "ADM1", "ADM2")
#' )
#' export_cells_to_legacy_geojson(
#'   cells_with_path,
#'   reporting_unit = cells_with_path$admin_path,
#'   output_path = "almaty_grid.geojson"
#' )
#' # name = cell_id = e.g. 224238; reporting_unit = "Kazakhstan_AlmatyRegion_Talgar"
#'
#' # No reporting_unit supplied -- still gets name/area/reporting_unit,
#' # using the "griddb_export" fallback for reporting_unit, since the
#' # CLI requires those properties to be present:
#' export_cells_to_legacy_geojson(cells, output_path = "almaty_grid.geojson")
#' }
export_cells_to_legacy_geojson <- function(cells, reporting_unit = "griddb_export",
                                            clip_boundary = NULL,
                                            output_path = NULL,
                                            area_crs = NULL) {
  if (!requireNamespace("sf", quietly = TRUE)) {
    stop("Package 'sf' is required", call. = FALSE)
  }
  if (!"cell_id" %in% names(cells)) {
    stop("cells must include a cell_id column", call. = FALSE)
  }
  if (length(reporting_unit) > 1 && length(reporting_unit) != nrow(cells)) {
    stop("reporting_unit must be either a single string or a vector with ",
         "exactly one value per row of cells (", nrow(cells), " rows supplied, ",
         length(reporting_unit), " reporting_unit values given).", call. = FALSE)
  }

  geoms <- sf::st_geometry(cells)
  # Cast away from integer64 (which can come from PostGIS's BIGINT
  # column type round-tripping through RPostgres/sf::st_read()) to a
  # plain double -- integer64 values can be silently mishandled by
  # JSON serializers (converted to scientific notation, or losing
  # precision), which would corrupt the exported file's cell_id/name
  # values without any visible error. round() removes any spurious
  # floating-point fractional noise (cell_id is always conceptually a
  # whole number; any decimal is print/representation noise, not a
  # real fractional value).
  cell_ids <- round(as.numeric(cells$cell_id))
  reporting_unit_per_cell <- if (length(reporting_unit) == 1) {
    rep(reporting_unit, nrow(cells))
  } else {
    reporting_unit
  }

  if (!is.null(clip_boundary)) {
    boundary_union <- sf::st_union(sf::st_geometry(clip_boundary))
    clipped_geom <- suppressWarnings(sf::st_intersection(geoms, boundary_union))
    keep <- !sf::st_is_empty(clipped_geom)

    cell_ids <- cell_ids[keep]
    reporting_unit_per_cell <- reporting_unit_per_cell[keep]

    cells <- sf::st_sf(cell_id = cell_ids, geometry = clipped_geom[keep])
  }

  if (is.null(area_crs)) {
    area_crs <- utm_zone_for_geometry(cells)
    message("Using auto-detected UTM zone EPSG:", area_crs, " for area calculation")
  }
  # Compute area in square meters via a projected CRS -- WGS84
  # degrees cannot be used directly for area calculations. Round to
  # whole square meters: sub-meter precision is meaningless noise from
  # floating-point geometry arithmetic, not real measurement accuracy
  # (cell areas here are on the order of 5*10^8 m^2, so this preserves
  # far more significant figures than the underlying geometry/raster
  # data could ever actually support).
  areas_m2 <- round(as.numeric(sf::st_area(sf::st_transform(cells, area_crs))))

  out <- sf::st_sf(
    name = as.character(cell_ids),
    cell_id = cell_ids,
    area = areas_m2,
    reporting_unit = reporting_unit_per_cell,
    geometry = sf::st_cast(sf::st_geometry(cells), "MULTIPOLYGON")
  )

  if (!is.null(output_path)) {
    sf::st_write(out, output_path, driver = "GeoJSON",
                 delete_dsn = TRUE, quiet = TRUE)
    message("Wrote ", nrow(out), " features to ", output_path)
  }

  invisible(out)
}

#' Export the full admin lookup table for a set of cells
#'
#' Writes a CSV (or returns a data frame) mapping each cell_id to its
#' admin_id/admin_name/parent_id at one or more admin levels. Unlike
#' \code{\link{attach_admin_names}}/\code{\link{attach_admin_hierarchy}},
#' this keeps EVERY match for a cell at a given level rather than
#' arbitrarily picking one when a boundary cell intersects more than
#' one unit -- the lookup table can simply have multiple rows for that
#' cell_id, so no information is lost or silently collapsed.
#'
#' Intended to be used as a companion to a geometry export that
#' carries only `cell_id` (the default of
#' \code{\link{export_cells_to_legacy_geojson}}): join this lookup
#' table on `cell_id` to recover whatever administrative context is
#' needed, without baking a single, possibly-stale or ambiguous label
#' into the spatial file itself.
#'
#' @param con A DBI connection
#' @param cells sf object (or any data frame) with a `cell_id` column
#' @param admin_levels Character vector of admin levels to include,
#'   e.g. \code{c("ADM0", "ADM1", "ADM2")}
#' @param output_path Optional character path to write a CSV to. If
#'   NULL, the lookup table is returned without writing a file.
#' @return Invisibly, a data frame with columns: cell_id, admin_level,
#'   admin_id, admin_name, parent_id -- one row per (cell_id,
#'   admin_level, admin_id) match
#' @export
#'
#' @examples
#' \dontrun{
#' cells <- get_simulation_cells_multi(con, resolution_arcmin = 15,
#'                                      admin_level = "ADM2",
#'                                      parent_level = "ADM1",
#'                                      parent_ids = "KAZ005")
#' export_cells_to_legacy_geojson(cells, output_path = "almaty_grid.geojson")
#' export_admin_lookup(con, cells, admin_levels = c("ADM0", "ADM1", "ADM2"),
#'                      output_path = "almaty_admin_lookup.csv")
#' }
export_admin_lookup <- function(con, cells, admin_levels, output_path = NULL) {
  if (!"cell_id" %in% names(cells)) {
    stop("cells must include a cell_id column", call. = FALSE)
  }
  if (length(admin_levels) == 0) {
    stop("admin_levels must contain at least one level", call. = FALSE)
  }

  lookup <- DBI::dbGetQuery(con, sprintf("
    SELECT cell_id, admin_level, admin_id, admin_name, parent_id
    FROM masks.cell_admin
    WHERE admin_level IN (%s) AND cell_id IN (%s)
    ORDER BY cell_id, admin_level, admin_id;
  ", paste(DBI::dbQuoteString(con, admin_levels), collapse = ", "),
     paste(unique(as.numeric(cells$cell_id)), collapse = ", ")))

  # Cast away from integer64 (a possible round-trip artifact of
  # PostGIS BIGINT via RPostgres) before returning/writing -- some
  # CSV/JSON writers can mishandle integer64 silently (e.g. scientific
  # notation or precision loss).
  lookup$cell_id <- as.numeric(lookup$cell_id)

  if (!is.null(output_path)) {
    write.csv(lookup, output_path, row.names = FALSE)
    message("Wrote ", nrow(lookup), " lookup rows to ", output_path)
  }

  invisible(lookup)
}
