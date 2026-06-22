#' Combine simulation cells across multiple admin units, deduplicating
#' boundary cells
#'
#' Supports two complementary ways of specifying which cells to pull,
#' both returning cells at the same `admin_level` granularity:
#'
#' \describe{
#'   \item{By parent units}{Supply \code{parent_level}/\code{parent_ids}
#'     or \code{parent_names} (e.g. a list of oblasts) to pull every
#'     unit at \code{admin_level} (e.g. every ADM2 district) nested
#'     under those parents, without enumerating districts by hand.
#'     Requires \code{parent_id} to have been populated correctly in
#'     \code{\link{update_admin_boundaries}} when the child level was
#'     ingested.}
#'   \item{By direct unit list}{Supply \code{admin_ids} or
#'     \code{admin_names} directly at \code{admin_level} to combine a
#'     specific, explicit set of units -- e.g. a handful of districts
#'     for small-area parameter testing before a full multi-oblast run.}
#' }
#'
#' Exactly one selection mode must be used per call: either the
#' parent-based arguments, or the direct-unit arguments, not both.
#'
#' Regardless of selection mode, cells that straddle the border between
#' two of the resulting units are deduplicated by \code{cell_id} -- see
#' \code{\link{update_admin_boundaries}} for why a cell can belong to
#' more than one unit at the same level.
#'
#' @param con A DBI connection
#' @param resolution_arcmin Numeric resolution of the grid to query
#' @param admin_level Character level of the units whose cells are
#'   returned, e.g. "ADM2"
#' @param parent_level Character level of the parent units to select
#'   by, e.g. "ADM1". Required if using parent-based selection.
#' @param parent_ids,parent_names Character vector of parent unit
#'   ids/names to select by (e.g. oblast names). Provide one, not both,
#'   when using parent-based selection.
#' @param admin_ids,admin_names Character vector of \code{admin_level}
#'   unit ids/names to select directly. Provide one, not both, when
#'   using direct-unit selection.
#' @param crop,min_frac_area,mask_source Passed through to each
#'   underlying \code{\link{get_simulation_cells}} call -- see that
#'   function's documentation
#' @return sf object of combined, deduplicated cells, with an added
#'   `n_admin_matches` column recording how many of the resolved
#'   admin units each cell intersected
#' @export
#'
#' @examples
#' \dontrun{
#' # Every ADM2 district in three oblasts, no need to list districts:
#' get_simulation_cells_multi(con, resolution_arcmin = 15,
#'                             admin_level = "ADM2",
#'                             parent_level = "ADM1",
#'                             parent_names = c("Almaty", "Zhambyl"))
#'
#' # Just two specific districts, for small-area parameter testing:
#' get_simulation_cells_multi(con, resolution_arcmin = 15,
#'                             admin_level = "ADM2",
#'                             admin_names = c("Balkhash District", "Aksu District"))
#' }
get_simulation_cells_multi <- function(con, resolution_arcmin, admin_level,
                                        parent_level = NULL,
                                        parent_ids = NULL, parent_names = NULL,
                                        admin_ids = NULL, admin_names = NULL,
                                        crop = "cropland", min_frac_area = 0.05,
                                        mask_source = NULL) {
  using_parent <- !is.null(parent_ids) || !is.null(parent_names)
  using_direct <- !is.null(admin_ids) || !is.null(admin_names)

  if (using_parent && using_direct) {
    stop("Use either parent-based selection (parent_level + parent_ids/parent_names) ",
         "or direct-unit selection (admin_ids/admin_names), not both.", call. = FALSE)
  }
  if (!using_parent && !using_direct) {
    stop("Provide either parent_ids/parent_names (with parent_level) ",
         "for parent-based selection, or admin_ids/admin_names for ",
         "direct-unit selection.", call. = FALSE)
  }

  if (using_parent) {
    if (is.null(parent_level)) {
      stop("parent_level is required when using parent-based selection ",
           "(e.g. parent_level = 'ADM1' to select by oblast).", call. = FALSE)
    }
    if (!is.null(parent_ids) && !is.null(parent_names)) {
      stop("Provide only one of parent_ids or parent_names, not both", call. = FALSE)
    }

    # Resolve parent names to ids first, if needed, then look up every
    # admin_level unit nested under those parents via parent_id.
    resolved_parent_ids <- if (!is.null(parent_ids)) {
      parent_ids
    } else {
      vapply(parent_names, function(nm) resolve_admin_id(con, parent_level, nm),
             character(1))
    }

    child_units <- DBI::dbGetQuery(con, sprintf("
      SELECT DISTINCT admin_id FROM masks.cell_admin
      WHERE admin_level = %s AND parent_id IN (%s);
    ", DBI::dbQuoteString(con, admin_level),
       paste(DBI::dbQuoteString(con, resolved_parent_ids), collapse = ", ")))

    if (nrow(child_units) == 0) {
      stop("No ", admin_level, " units found with parent_id matching the ",
           "supplied parent(s). Check that parent_id was populated correctly ",
           "when ", admin_level, " boundaries were ingested.", call. = FALSE)
    }

    admin_ids <- child_units$admin_id
    admin_names <- NULL
  }

  units <- if (!is.null(admin_ids)) admin_ids else admin_names
  use_id <- !is.null(admin_ids)

  results <- vector("list", length(units))
  for (i in seq_along(units)) {
    results[[i]] <- if (use_id) {
      get_simulation_cells(con, resolution_arcmin = resolution_arcmin,
                            admin_level = admin_level, admin_id = units[i],
                            crop = crop, min_frac_area = min_frac_area,
                            mask_source = mask_source)
    } else {
      get_simulation_cells(con, resolution_arcmin = resolution_arcmin,
                            admin_level = admin_level, admin_name = units[i],
                            crop = crop, min_frac_area = min_frac_area,
                            mask_source = mask_source)
    }
  }

  combined <- do.call(rbind, results)

  if (nrow(combined) == 0) {
    warning("Combined query returned 0 cells across all resolved admin units.",
            call. = FALSE)
    return(combined)
  }

  match_counts <- table(combined$cell_id)
  combined$n_admin_matches <- as.integer(match_counts[as.character(combined$cell_id)])

  n_total <- nrow(combined)
  deduped <- combined[!duplicated(combined$cell_id), ]
  n_duplicates_removed <- n_total - nrow(deduped)

  if (n_duplicates_removed > 0) {
    message(n_duplicates_removed, " boundary cell(s) removed as duplicates ",
            "(present in more than one resolved admin unit). ",
            nrow(deduped), " unique cells remain.")
  }

  deduped
}
