# data-raw/

This folder holds real, downloaded input data used to populate the
database -- political/administrative boundaries and crop mask
rasters. These are **inputs you provide locally**, not package source
code, and they are **not committed to git** (see `.gitignore` below).

## Structure

```
data-raw/
├── boundaries/     -- admin/political boundary files (geopackage, shapefile, geojson)
│                      e.g. geoBoundaries ADM0/ADM1 downloads for Kazakhstan
└── crop_masks/      -- crop mask rasters (.tif)
                       e.g. ESA WorldCover, SPAM, clipped to your region of interest
```

## Usage

Drop your real files into the appropriate subfolder, then reference
them by path in your R scripts:

```r
oblast_boundary <- sf::st_read("data-raw/boundaries/kaz_adm1_aqmola.gpkg")

update_crop_mask(
  con,
  raster_path = "data-raw/crop_masks/esa_worldcover_kaz.tif",
  resolution_arcmin = 15,
  mask_source = "ESA_WorldCover_2021",
  crop_class_values = 40   # check the raster's own legend for the correct value(s)
)
```

## Why this isn't committed to git

These files are typically large binaries (rasters especially) and are
easily re-downloaded from their original source (geoBoundaries, ESA
WorldCover, etc.) -- committing them would bloat the repository for no
benefit. The `.gitignore` at the project root already excludes this
folder's contents (see the `data-raw/` entry); only this README is
tracked, so the folder structure and usage convention survive even
though the data itself doesn't.

If you need to share a specific input file with a teammate, use a
shared drive or re-download link, not git.
