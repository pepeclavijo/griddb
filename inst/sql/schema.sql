-- griddb schema
-- Run this once against a fresh PostGIS-enabled database (e.g. Supabase)
-- to create the schemas and tables that the griddb package functions
-- read from and write to.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS grids;
CREATE SCHEMA IF NOT EXISTS masks;
CREATE SCHEMA IF NOT EXISTS staging;

-- ---------------------------------------------------------------------
-- Grid cell tables: one per resolution, created dynamically by
-- griddb::write_grid_to_postgis(). This file does not hardcode specific
-- resolution tables since those are created on demand; this comment
-- documents the expected shape of each one.
--
-- CREATE TABLE grids.cells_<resolution>_arcmin (
--     cell_id           BIGINT PRIMARY KEY,
--     lon_center        DOUBLE PRECISION NOT NULL,
--     lat_center        DOUBLE PRECISION NOT NULL,
--     resolution_arcmin  DOUBLE PRECISION NOT NULL,
--     geometry          GEOMETRY(POLYGON, 4326) NOT NULL
-- );
-- CREATE INDEX ON grids.cells_<resolution>_arcmin USING GIST (geometry);
-- CREATE INDEX ON grids.cells_<resolution>_arcmin (lat_center, lon_center);
-- ---------------------------------------------------------------------

-- Political / administrative / customer-region boundaries, keyed by cell_id.
-- One row per (cell_id, admin_level, admin_id) -- a cell can belong to
-- multiple levels at once (its ADM0, its ADM1, its customer_region, etc).
CREATE TABLE IF NOT EXISTS masks.cell_admin (
    cell_id       BIGINT NOT NULL,
    admin_level   TEXT NOT NULL,        -- 'ADM0', 'ADM1', 'ADM2', 'customer_region'
    admin_id      TEXT NOT NULL,        -- e.g. GADM/geoBoundaries code, or customer ID
    admin_name    TEXT,                 -- human-readable name
    parent_id     TEXT,                 -- admin_id of the parent unit, for hierarchy traversal
    source        TEXT,                 -- e.g. 'geoBoundaries', 'GADM', 'customer_upload'
    PRIMARY KEY (cell_id, admin_level, admin_id)
);

CREATE INDEX IF NOT EXISTS idx_cell_admin_level_id
    ON masks.cell_admin (admin_level, admin_id);
CREATE INDEX IF NOT EXISTS idx_cell_admin_level_name
    ON masks.cell_admin (admin_level, admin_name);
CREATE INDEX IF NOT EXISTS idx_cell_admin_parent
    ON masks.cell_admin (admin_level, parent_id);

-- Crop / cropland presence mask, keyed by cell_id.
-- Initial use case is a generic cropland mask (crop = 'cropland'); the
-- schema supports crop-specific masks later without migration, since
-- crop is just another column value.
CREATE TABLE IF NOT EXISTS masks.crop_presence (
    cell_id       BIGINT NOT NULL,
    crop          TEXT NOT NULL DEFAULT 'cropland',
    frac_area     REAL NOT NULL,         -- fraction of cell area under crop, 0-1
    mask_source   TEXT NOT NULL,         -- e.g. 'ESA_WorldCover_2021', 'SPAM2020'
    mask_year     INTEGER,
    PRIMARY KEY (cell_id, crop, mask_source)
);

CREATE INDEX IF NOT EXISTS idx_crop_presence_cell
    ON masks.crop_presence (cell_id);
CREATE INDEX IF NOT EXISTS idx_crop_presence_source
    ON masks.crop_presence (mask_source, crop);

-- Hierarchy tables (fine cell -> coarse cell) are created dynamically by
-- griddb::build_cell_hierarchy(), one per resolution pair actually used.
-- Expected shape:
--
-- CREATE TABLE grids.cell_hierarchy_<fine>_to_<coarse>_arcmin (
--     fine_cell_id    BIGINT PRIMARY KEY,
--     coarse_cell_id  BIGINT NOT NULL
-- );
-- CREATE INDEX ON grids.cell_hierarchy_<fine>_to_<coarse>_arcmin (coarse_cell_id);
