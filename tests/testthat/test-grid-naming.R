test_that("grid_table_name produces expected names", {
  expect_equal(grid_table_name(15), "cells_15_arcmin")
  expect_equal(grid_table_name(0.5), "cells_0_5_arcmin")
  expect_equal(grid_table_name(0.00833), "cells_0_00833_arcmin")
  expect_equal(grid_table_name(10), "cells_10_arcmin")
})

test_that("grid_table_name is consistent across equivalent float representations", {
  expect_equal(grid_table_name(0.00833), grid_table_name(0.00833000))
  expect_equal(grid_table_name(15), grid_table_name(15.0))
})

test_that("grid_table_name rejects invalid input", {
  expect_error(grid_table_name(-1), "positive")
  expect_error(grid_table_name(c(1, 2)), "single numeric")
  expect_error(grid_table_name("15"), "single numeric")
})

test_that("hierarchy_table_name produces expected names", {
  expect_equal(
    hierarchy_table_name(0.5, 15),
    "cell_hierarchy_0_5_to_15_arcmin"
  )
})

test_that("hierarchy_table_name rejects fine >= coarse", {
  expect_error(hierarchy_table_name(15, 0.5), "smaller")
  expect_error(hierarchy_table_name(5, 5), "smaller")
})
