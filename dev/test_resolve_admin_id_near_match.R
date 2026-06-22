# Validates resolve_admin_id() warns on near-matches (e.g. "Almaty" vs
# "Almaty Region") even when it successfully resolves an exact match,
# and still errors correctly on genuinely ambiguous exact matches.
#
# Run block by block.

library(griddb)
library(DBI)

con <- get_db_connection()

# ---------------------------------------------------------------------
# 1. Set up synthetic admin units replicating the city-vs-region
#    collision pattern, directly in masks.cell_admin (no need for
#    real geometry -- this only tests the name-resolution SQL logic)
# ---------------------------------------------------------------------
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'NAME_TEST';")

dbExecute(con, "
  INSERT INTO masks.cell_admin (cell_id, admin_level, admin_id, admin_name, source)
  VALUES
    (900001, 'NAME_TEST', 'CITY', 'Almaty', 'synthetic'),
    (900002, 'NAME_TEST', 'REGION', 'Almaty Region', 'synthetic'),
    (900003, 'NAME_TEST', 'OTHER', 'Akmola', 'synthetic');
")

# ---------------------------------------------------------------------
# 2. Exact match WITH a near-match present -- should resolve correctly
#    but emit a warning naming the near-match.
# ---------------------------------------------------------------------
result <- withCallingHandlers(
  resolve_admin_id(con, "NAME_TEST", "Almaty"),
  warning = function(w) {
    cat(">>> Warning issued, as expected:\n", conditionMessage(w), "\n\n")
    invokeRestart("muffleWarning")
  }
)
cat("Resolved admin_id:", result, "\n")
if (result == "CITY") {
  cat(">>> PASS: exact match still correctly resolved to 'CITY'.\n\n")
} else {
  cat(">>> FAIL: resolved to unexpected admin_id.\n\n")
}

# ---------------------------------------------------------------------
# 3. Exact match with NO near-match present -- should resolve silently,
#    no warning.
# ---------------------------------------------------------------------
no_warning_fired <- TRUE
result2 <- withCallingHandlers(
  resolve_admin_id(con, "NAME_TEST", "Akmola"),
  warning = function(w) {
    no_warning_fired <<- FALSE
    invokeRestart("muffleWarning")
  }
)
cat("Resolved admin_id:", result2, "\n")
if (result2 == "OTHER" && no_warning_fired) {
  cat(">>> PASS: unambiguous name resolved with no spurious warning.\n\n")
} else {
  cat(">>> FAIL: either wrong id resolved, or an unexpected warning fired.\n\n")
}

# ---------------------------------------------------------------------
# 4. Genuinely ambiguous EXACT match -- should still error, not warn.
# ---------------------------------------------------------------------
dbExecute(con, "
  INSERT INTO masks.cell_admin (cell_id, admin_level, admin_id, admin_name, source)
  VALUES (900004, 'NAME_TEST', 'DUPLICATE', 'Almaty', 'synthetic');
")

tryCatch({
  resolve_admin_id(con, "NAME_TEST", "Almaty")
  cat(">>> FAIL: expected an error for a duplicate exact match, but none was raised.\n")
}, error = function(e) {
  cat(">>> PASS: duplicate exact match correctly raised an error:\n", conditionMessage(e), "\n")
})

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------
dbExecute(con, "DELETE FROM masks.cell_admin WHERE admin_level = 'NAME_TEST';")
dbDisconnect(con)
