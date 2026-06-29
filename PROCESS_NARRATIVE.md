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

## 11. Switching admin cell assignment from centroid to intersection

Real-data validation against Kazakhstan's actual ADM1/ADM2 boundaries
surfaced a concrete problem with the original centroid-containment
rule (`ST_Within(ST_Centroid(cell), boundary)`): comparing a
`griddb`-derived export against the legacy KZ rice GeoJSON for the
same district (Balkhash District) showed visible gaps where the
legacy boundary extended beyond the new grid cells. Quantifying it
confirmed the cause -- cells whose body genuinely overlapped the
district, but whose centroid fell just outside it (common right along
any boundary), were being silently excluded.

This was judged unacceptable for the actual use case: missing real
agricultural area at a district's edge is a worse failure mode than
including a small amount of extra area. The fix was to switch
`update_admin_boundaries()`'s join condition from centroid containment
to `ST_Intersects` -- a cell is now assigned to a region if any part of
it overlaps that region's boundary at all.

This trades away one property the system previously had for free:
cells belonging to disjoint admin units were themselves guaranteed
disjoint. Under intersection-based assignment, a single cell can now
be assigned to more than one adjacent admin unit if it straddles their
shared border. This was accepted as the right tradeoff for this use
case, with the consequence made explicit in both
`update_admin_boundaries()`'s and `get_simulation_cells()`'s
documentation: combining results across multiple admin-unit queries
(e.g. summing a value across several adjacent districts) now requires
deduplicating by `cell_id` first to avoid double-counting boundary
cells. A query for a single admin unit is unaffected.

Note that this does not produce pixel-perfect edge matching against
the legacy hand-clipped boundaries either -- it resolves the
under-coverage problem (red sticking out past blue) at the cost of
mild over-coverage at edges (whole cells extending slightly past a
true boundary that cuts through their middle). Exact edge matching, if
ever needed, remains available only via `clip_boundary` in
`export_cells_to_legacy_geojson()`, which performs true geometric
clipping at export time rather than changing how cells are assigned
internally.

## 13. Investigating `frac_poly_covered_by_pt = 0` in pSIMS CLI output

A real Almaty test run (15 arcmin `griddb` cells, `delta_lat`/`delta_lon`
set to 15 in the pSIMS CLI) showed roughly 76% of point-level output
rows with `frac_poly_covered_by_pt = 0`. This looked alarming at first
and prompted a full investigation into whether `griddb`'s grid was
misaligned with the CLI's own internal simulation grid.

**What `frac_poly_covered_by_pt` actually is**: a continuous overlap
fraction between a simulated sample point's representative footprint
and the named polygon -- not a binary match/no-match flag. This was
confirmed by comparing against an unrelated Colombia farm-polygon test
case, where the same column showed genuine fractional values
(0.16-0.42) rather than 0/1.

**What `delta`/`delta_lat`/`delta_lon` actually control**: per the
underlying pSIMS engine's own parameter documentation (not the
`psims_cli` README, which doesn't fully explain this), `delta` is
"simulation delta, gridcell spacing in arcminutes" -- pSIMS's own
internal simulation grid resolution, independent of whatever polygon
shape was uploaded. Units are arcminutes, confirmed directly from that
documentation (resolving an earlier worry that the Almaty value of 15
might have been a units mismatch -- it was not).

**Grid alignment was checked directly and ruled out as a cause**: by
extracting every unique sample-point coordinate pSIMS actually used
across the full Almaty run and checking each one's value modulo the
0.25 deg (15 arcmin) cell size, every single point showed an identical
phase remainder (0.125) on both latitude and longitude. `griddb`'s own
cell centroids, checked the same way, showed the identical 0.125
remainder. This confirms `griddb`'s global-origin-anchored grid and
pSIMS's internal grid are precisely phase-aligned at this resolution --
not an anchor/origin mismatch.

**The actual explanation**: pSIMS appears to sample 4 sub-points per
delta-sized cell (one per quadrant) -- plausibly to characterize
sub-grid soil heterogeneity, given the soil input data's native
resolution (~1km, from the Global Soil Dataset for Earth System
Modeling, http://globalchange.bnu.edu.cn/research/soilw) is far finer
than the 15 arcmin (~28-30km) delta used for this run, while weather
(ERA5) is closer to the delta resolution already. Only one of the 4
sub-points per cell is the true centroid (`frac = 1.0`); the other
three legitimately sample territory outside the named polygon
(`frac = 0`), and are expected to be weighted by `frac_poly_covered_by_pt`
during aggregation rather than discarded or treated as errors.

**Confirmation**: running `aggregate-polygon` (which the
`psims_cli` README notes must run before `aggregate-reporting-unit`)
produced sensible, plausible yield results -- consistent with the
4-point raw output being correctly collapsed and weighted at the
aggregation step, exactly as the point-level data's structure implies
it should be.

**Practical takeaway**: a high `frac_poly_covered_by_pt = 0` rate in
raw, point-level pSIMS CLI output is not necessarily a sign of a
`griddb` grid-alignment problem, a `delta` misconfiguration, or a CLI
bug. The point-level file is an intermediate product reflecting
sub-cell sampling design, not a final per-polygon result -- always
validate against the polygon-aggregated output (`aggregate-polygon`)
before concluding something is wrong upstream. If the aggregated
output looks sensible, the raw zeros are very likely expected
behavior, not a defect.

**Open question, not resolved here**: why this specific run prompted
investigation when (per the person running it) this pattern hadn't
been noticed before in other runs. Possible factors worth checking in
a future investigation: whether `delta` has historically been set
closer to the soil grid's native resolution (in which case sub-points
would mostly coincide with one polygon rather than spilling into
neighbors), whether this was the first time `delta` was set equal to
the `griddb` polygon's own resolution specifically, or whether the
proportion of zero-rows varies meaningfully by crop, region, or some
other run-specific factor. This section reflects what was established
for this one Almaty/winter-wheat run, not a general rule confirmed
across other configurations.

## 14. Current state

As of this writing, grid generation, admin boundary ingestion
(intersection-based assignment), crop mask ingestion (both classified
and percent-area raster styles), and the query/export functions have
all been validated against real Kazakhstan data -- ADM0/ADM1/ADM2
boundaries and a real percent-cropland-area NetCDF mask -- including a
direct comparison against an existing legacy output file for the same
district, which surfaced and led to fixing the admin-assignment
edge-coverage issue in section 11. Section 13 documents a separate
investigation into the downstream pSIMS CLI's output, which concluded
`griddb`'s grid generation was not the cause of the behavior observed.


