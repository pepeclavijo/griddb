#' Connect to the griddb PostGIS database
#'
#' Reads connection parameters from environment variables (set via a
#' project-level .Renviron, which should never be committed to version
#' control). See the package README for setup instructions.
#'
#' Required environment variables:
#' \itemize{
#'   \item SUPABASE_DB_HOST
#'   \item SUPABASE_DB_PORT
#'   \item SUPABASE_DB_NAME
#'   \item SUPABASE_DB_USER
#'   \item SUPABASE_DB_PASSWORD
#' }
#'
#' @return A DBI connection object
#' @export
get_db_connection <- function() {
  if (!requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("RPostgres", quietly = TRUE)) {
    stop("Packages 'DBI' and 'RPostgres' are required", call. = FALSE)
  }

  required_vars <- c(
    "SUPABASE_DB_HOST", "SUPABASE_DB_PORT", "SUPABASE_DB_NAME",
    "SUPABASE_DB_USER", "SUPABASE_DB_PASSWORD"
  )
  missing <- required_vars[Sys.getenv(required_vars) == ""]
  if (length(missing) > 0) {
    stop(
      "Missing required environment variable(s): ", paste(missing, collapse = ", "),
      "\nSet these in a project-level .Renviron file (see package README).",
      call. = FALSE
    )
  }

  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = Sys.getenv("SUPABASE_DB_HOST"),
    port     = as.integer(Sys.getenv("SUPABASE_DB_PORT")),
    dbname   = Sys.getenv("SUPABASE_DB_NAME"),
    user     = Sys.getenv("SUPABASE_DB_USER"),
    password = Sys.getenv("SUPABASE_DB_PASSWORD")
  )
}
