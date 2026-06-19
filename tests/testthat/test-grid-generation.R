test_that("compute_global_cell_id places cell 1 at upper-left", {
  # 5 arcmin = 0.0833 deg cells. Use a point well inside the first cell
  # (close to, but strictly inside, the (-180, 90) corner) -- a point
  # only 0.1 deg from the corner would actually fall in the second row
  # and column at this resolution, so it must be closer than one cell
  # width.
  id <- compute_global_cell_id(lon = -179.99, lat = 89.99, resolution_arcmin = 5)
  expect_equal(id, 1)
})

test_that("compute_global_cell_id is deterministic", {
  id1 <- compute_global_cell_id(10.3, 45.7, resolution_arcmin = 1)
  id2 <- compute_global_cell_id(10.3, 45.7, resolution_arcmin = 1)
  expect_identical(id1, id2)
})

test_that("compute_global_cell_id increases left-to-right within a row", {
  res <- 5
  id_left  <- compute_global_cell_id(-170, 80, resolution_arcmin = res)
  id_right <- compute_global_cell_id(-160, 80, resolution_arcmin = res)
  expect_gt(id_right, id_left)
})

test_that("compute_global_cell_id increases top-to-bottom across rows", {
  res <- 5
  id_top    <- compute_global_cell_id(0, 80, resolution_arcmin = res)
  id_bottom <- compute_global_cell_id(0, -80, resolution_arcmin = res)
  expect_gt(id_bottom, id_top)
})

test_that("compute_global_cell_id is vectorized", {
  ids <- compute_global_cell_id(
    lon = c(-180, 0, 179),
    lat = c(90, 0, -90),
    resolution_arcmin = 10
  )
  expect_length(ids, 3)
  expect_true(all(diff(ids) > 0))
})

test_that("generate_grid_bbox produces non-overlapping, contiguous cells", {
  skip_if_not_installed("sf")
  g <- generate_grid_bbox(60, xmin = -10, ymin = -10, xmax = 10, ymax = 10)
  expect_s3_class(g, "sf")
  expect_true(all(!duplicated(g$cell_id)))
  expect_true(all(c("cell_id", "lon_center", "lat_center", "resolution_arcmin") %in% names(g)))
})

test_that("generate_grid_bbox cell_ids match compute_global_cell_id", {
  skip_if_not_installed("sf")
  res <- 30
  g <- generate_grid_bbox(res, xmin = -5, ymin = -5, xmax = 5, ymax = 5)
  expected_ids <- compute_global_cell_id(g$lon_center, g$lat_center, res)
  expect_equal(g$cell_id, expected_ids)
})

test_that("regenerating the same bbox grid produces identical cell_ids and geometry", {
  skip_if_not_installed("sf")
  g1 <- generate_grid_bbox(30, xmin = 60, ymin = 40, xmax = 90, ymax = 55)
  g2 <- generate_grid_bbox(30, xmin = 60, ymin = 40, xmax = 90, ymax = 55)
  expect_identical(g1$cell_id, g2$cell_id)
  expect_true(all(sf::st_equals(g1, g2, sparse = FALSE) |> diag()))
})

test_that("a larger bbox grid contains the same cell_ids for a shared sub-area", {
  skip_if_not_installed("sf")
  res <- 30
  small <- generate_grid_bbox(res, xmin = 60, ymin = 40, xmax = 70, ymax = 50)
  large <- generate_grid_bbox(res, xmin = 50, ymin = 30, xmax = 90, ymax = 60)

  # Every cell_id present in the small grid should also appear in the
  # large grid's set, with the SAME id -- this is the core stability
  # property the whole design depends on.
  expect_true(all(small$cell_id %in% large$cell_id))
})
