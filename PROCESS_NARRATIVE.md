# How We Got Here: Process Narrative for the `griddb` System

This document captures the reasoning behind the design decisions in
`griddb`, in the order they were made. It's meant as a reference for
understanding *why* the system looks the way it does, separate from
`PACKAGE_DOCUMENTATION.md`, which covers *how to use it*.

## 1. The original problem

The starting point was a proposal to replace irregular, customer- or
deployment-specific polygons as the spatial unit for crop simulations
with a standardized set of global grids at several fixed resolutions
(0.00833 to 15 arcminutes), aligned so that fine (soil) cells nest
exactly inside coarse (weather) cells.

The motivating pain point: under the existing approach, every new
deployment or customer region required generating new polygons, doing
point-in-polygon intersection work to match simulation outputs back to
those polygons, and maintaining polygon identities that weren't
comparable across deployments. The proposal's core idea was to fix the
spatial units once, globally, so that simulation results could be
written directly against a stable ID with no intersection step at
write time.

## 2. Choosing the implementation language and tools

Python with GeoPandas/PostGIS was the first sketch, but since the
team's existing tooling and comfort level was in R, the same design was
reworked using `sf` (vector geometry, PostGIS I/O), `terra` (fast
raster-backed grid generation for fine resolutions), and `DBI` /
`RPostgres` for the database layer. The conclusion was that R is fully
capable for this workflow — `sf` was designed with PostGIS
interoperability in mind — with `terra` closing most of the
performance gap Python's compiled libraries would otherwise have at
very fine resolutions.

## 3. Designing the grid and the database schema

The key technical decision was how to assign cell IDs. The proposal
called for a convention where cell 1 sits in the upper-left of a grid
and IDs increase left-to-right, top-to-bottom — and, crucially, for
those IDs to be *stable across deployments*. A naive implementation
("number whatever cells happen to exist in this run") would break that
property the moment two different runs covered different extents.

The resolution was to make the ID a pure function of position:
`compute_global_cell_id(lon, lat, resolution_arcmin)`, derived from a
fixed global origin at (-180, 90), independent of what's actually been
generated or stored. This means a grid generated for one country today
and a grid generated for the whole world (or a different country)
later will assign *identical* IDs to any cells that overlap, with no
migration or renumbering step required.

The schema was split into three concerns that had previously been
conflated in the existing point/polygon data (where a single
`polygon_name` plus a `frac_poly_covered_by_pt` column implicitly
carried simulation identity, crop presence, and regional grouping all
at once):

- **`grids.cells_<resolution>_arcmin`** — the simulation unit itself:
  cell_id, centroid, geometry. Generated once per region/resolution,
  essentially permanent.
- **`masks.cell_admin`** — political/administrative/customer-region
  membership, keyed by cell_id. Independent of crop presence,
  versioned by source, supports multiple admin levels (ADM0/1/2,
  customer regions) in one table via a `parent_id` column for
  hierarchy traversal.
- **`masks.crop_presence`** — fraction of each cell under crop,
  keyed by cell_id, versioned by mask source/year.

Keeping these three separate means updating a crop mask or redrawing a
customer's operating region never touches grid geometry or requires
reprocessing simulation outputs — both are just joins against
`cell_id` at query time, not geometry operations.

## 4. Deciding what the package is *for*, and what it isn't for

A clarifying moment was distinguishing when this system should be used
at all. The grid system solves the specific problem of giving
spatially independent simulation units *stable, reusable identity*
across deployments — which only matters when results need to be
re-aggregated or compared over time without re-running point-in-polygon
work. For requests that already arrive as an explicit lat/lon or an
explicit customer-drawn polygon, the existing tools remain the right
choice; routing those through the grid system would introduce
unnecessary snapping error or reintroduce the very intersection
overhead the proposal was trying to eliminate, just in the other
direction.

The practical rule landed on: if the simulation unit can be named or
drawn by the requester, use current tools. If the unit only exists
because a resolution was chosen to tile an area, that's `griddb`.

## 5. The primary query pattern

The dominant real-world use case clarified the main public function's
shape: "give me all cropland cells in [political unit]." This became
`get_simulation_cells()` — a single function joining the grid,
`cell_admin`, and `crop_presence` tables on `cell_id`, parameterized by
resolution, admin level, and either an admin ID or a human-readable
admin name (resolved internally via `resolve_admin_id()`).

Scope was deliberately narrowed for the first version: rather than
building crop-specific masking immediately, the schema defaults to a
single generic `crop = 'cropland'` mask, since that's the actual
near-term need. Crop-specific masks remain possible later (it's just
another value in an existing column) without a schema migration.

## 6. Boundary data source selection

GADM was the default first instinct for administrative boundaries, but
a licensing check surfaced that GADM restricts commercial use, while
geoBoundaries offers comparable ADM0–ADM2 coverage under a fully open
CC BY license. Given this system is intended for commercial customer
deployments, geoBoundaries was set as the default source, with the
boundary-ingestion function written source-agnostically so either
(or a customer's own uploaded region) can be passed in without
changing any downstream code.

## 7. The "generate everything globally now, or per-country as needed"
   question

A natural question once the stable-ID property existed: does it
actually require pre-generating the whole world up front? The answer
arrived at was no — the ID formula's independence from storage means
cells can be materialized lazily, per country or region, on demand,
and still retain globally-correct IDs. This avoids paying the storage
and compute cost of ~900 million cells at the finest resolution before
there's a concrete need for global wall-to-wall coverage, while
preserving the option to mosaic results across countries later without
any renumbering.

This is why `generate_grid_for_boundary()` exists as the practical
entry point rather than a "generate the whole planet" function — it
generates only the cells overlapping a given boundary, using the same
global formula, snapped to global grid lines so adjacent regions always
align exactly.

## 8. Packaging decision

Given the stability guarantees the whole system depends on (cell ID
determinism, naming convention consistency), and the intent for this
to be a shared tool other pipelines would depend on, the decision was
made to build this as a proper R package (`griddb`) rather than a
folder of loose scripts. This buys `R CMD check`, `roxygen2`
documentation, and — most importantly — a `testthat` suite that can
directly assert the one property a silent bug would be hardest to
detect and most damaging to get wrong: that the same lon/lat always
produces the same cell_id, regardless of what's been generated before
or what bounding box was used.

## 9. Infrastructure choice for testing

Rather than requiring local PostGIS infrastructure (Docker, with its
own commercial licensing wrinkle for larger organizations, or a native
install), a free-tier Supabase project was used to get a real
PostGIS-enabled Postgres instance running with minimal setup — no
local server management, disposable for testing, and structurally
identical to what production usage would look like (a remote
Postgres connection string), so nothing about the package's design
needs to change when moving from a test instance to a production one.

## 10. Current state and the immediate next test

As of this writing, the package skeleton, schema, and core functions
(grid generation, admin boundary ingestion, crop mask ingestion, and
the `get_simulation_cells()` query function) have been written and
pushed to GitHub. The immediate validation step is a single-country
slice: Kazakhstan, one grid resolution, a generic cropland mask, and
ADM0/ADM1 boundaries from geoBoundaries — confirming the full pipeline
end-to-end before considering whether/when to expand to additional
countries or resolutions.
