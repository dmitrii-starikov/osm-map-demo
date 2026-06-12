# OSM Tile Server Demo — Kamchatka

A self-hosted OpenStreetMap raster tile server for the Kamchatka peninsula, shown as a small Leaflet web map. Built on the all-in-one image [`overv/openstreetmap-tile-server`](https://github.com/Overv/openstreetmap-tile-server) _(renderd + mod_tile + osm-carto + PostgreSQL/PostGIS in one container)_ plus our baked config with nginx frontend.

This is the hands-on companion for the articles:
- [Part I]()
- [Part II]()

---

## Architecture

```
PBF dump → osmium (crop to bbox) → osm2pgsql → PostGIS → renderd → Apache/mod_tile
                                                                           │
                                            nginx (/osm/ → /tile/) ◄───────┘
                                                  │
                                              Leaflet (web/index.html)
```

- **tile-server** is our custom image (overv base + baked config). Runs its own PostgreSQL, imports the PBF, builds the osm-carto style, and serves native tiles at `/tile/` (plus the English layer at `/tile-en/`) on port 8080.
- **web** - nginx serving the Leaflet map on port 3000 and proxying `/osm/` to `/tile/` (and `/osm-en/` to `/tile-en/`).

## Quick start

Just `make setup`. 

It downloads the Far-Eastern district PBF (~360 MB), crops it to the Kamchatka bbox, imports it into database, builds the custom image, starts the services, sets up the English layer, and pre-renders zooms 0-10. First run around 10-15 min (most of it importing the global water polygons osm-carto needs for coastlines). Then:

- Map: http://localhost:3000 (the **RU/EN** button switches the interface)
- Tiles: http://localhost:8080/osm/10/961/331.png
- renderd status: http://localhost:8080/mod_tile

![demo.gif](demo.gif)

Requirements: Docker + Docker Compose v2, and around 7 GB free disk for the default region (see the cost table below).

## Commands

| Command                                     | What it does                                           |
|---------------------------------------------|--------------------------------------------------------|
| `make setup`                                | Full first run: download → crop → build → ... → render |
| `make build`                                | Build the custom image (overv + tuning)                |
| `make localize`                             | Create the `en` DB views and load the English layer    |
| `make start` · `make stop` · `make restart` | Manage the containers without rebuilding               |
| `make render` / `make render-high`          | Pre-render z0–z10 / z11     only                       |
| `make clear-tiles`                          | Delete rendered tiles (keeps the DB)                   |
| `make status`                               | Containers, DB size, tiles on disk                     |
| `make logs` · `make logs-tiles`             | Follow logs                                            |
| `make shell-tiles` · `make shell-db`        | bash / psql inside the tile-server                     |
| `make clean`                                | Remove containers, volumes, tiles and downloaded data  |

`make help` lists everything.

## Tuning demos

> **What these demonstrate.** The demo shows how OSM stack works and the *mechanics* of the tuning, not the *payoff*. On 8 MB of data the tuning doesn't visibly speed anything up, and the index benchmark toggles an index the image already created. The payoff only appears at scale - read the demo as "here are the levers" and the article as "here's what they buy you."

| Command                    | Shows                                                   |
|----------------------------|---------------------------------------------------------|
| `make index-benchmark`     | A coastal spatial query with vs without the GIST index  |
| `make render-benchmark`    | On-demand render vs disk-cache hit (why you pre-render) |
| `make style-no-boundaries` | Hides admin boundaries                                  |
| `make style-reset`         | Restores the default osm-carto style                    |

`style-no-boundaries` edits the style in the running container; it survives `make restart` but resets on container recreation (`make clean`/rebuild) - re-run it, or `make style-reset` to undo immediately. After a change, run `make render` (or pan the map) to regenerate tiles.

**Index benchmark. Real numbers from this demo:**

```
WITH GIST index:    Index Scan …   ~1.7 ms
WITHOUT index:      Seq Scan …     ~1250 ms     →  ≈ 740x faster
```

This holds up even on a tiny region because the queried table — global coastline
`water_polygons` (~1.2 GB) — is the **same size regardless of region**. Note this ~740x is a single query, while the ~150x from the article is a whole tile render. Same mechanism (`index scan` vs `seq scan`), different metric. The index itself is `indexes.sql` from osm-carto, which the image runs automatically at import.

**Render benchmark — on-demand vs cache:** `make render-benchmark` fetches a 10x10 tile block at z13 (not pre-rendered) twice — the first pass renders on demand, the second hits the disk cache:

```
cold (on-demand render):   ~3.2 s   per 100 tiles
warm (cache hit):          ~0.7 s   per 100 tiles     →  ~5x — that's why you pre-render
```

(mod_tile renders 8x8 metatiles, so 100 contiguous tiles are ~4 renders; the gap grows with zoom and data density.)

**Localized labels (live English layer):** the **RU/EN** button switches the *whole map*, not just the UI. EN is a second renderd layer (`/tile-en/`, exposed by nginx as `/osm-en/`) that renders `name:en` via DB **views** (`config/localize-views.sql`) — no CartoCSS edits, no data mutation. The layer (mapnik-en.xml + renderd `[en]` + apache config) is **baked into the custom image** (`docker/Dockerfile`); only the views are created at runtime by `make localize` (they need the imported tables). Tiles render lazily on first view, then cache in `tiles/en/`. On Kamchatka the native `name` is already Russian, so the default `/osm/` layer is the Russian map - no separate ru layer needed.

## Other regions (mind the disk!)

The region is parametrized. Override `PBF_URL` and `BBOX` if you want to experiment:

```bash
# Whole country, no cropping (BBOX empty):
make PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf BBOX= setup
```

**DB size depends on the imported region, not on the render zoom** (the zoom limit only caps *tile* disk). DB around 10–15x the PBF, plus a fixed ~2–3 GB of global water/coastline data that every import pulls.

| Region                   | PBF    | DB (≈)   | Import (≈) | Fits a laptop? |
|--------------------------|--------|----------|------------|----------------|
| Kamchatka bbox (default) | 8 MB   | ~3 GB    | ~5–10 min  | yes            |
| Germany                  | ~4 GB  | ~40 GB   | ~30–60 min | yes            |
| USA                      | ~11 GB | ~100 GB+ | hours      | no             |
| Planet                   | ~70 GB | ~1.7 TB  | ~5 days*   | server only    |

_* Planet numbers are from the article's setup (HDD, single-threaded, no flat-nodes)_


## Layout

```
compose.yml         services: tile-server (built from docker/) + web
Makefile            build / run / render + tuning targets
docker/
  Dockerfile        custom image
  postgresql-tuning.conf  modest Postgres tuning, baked in & applied
  renderd.conf      renderd config ([default] + [en] layers)
  nginx.conf        web UI + /osm/ → /tile/, /osm-en/ → /tile-en/ proxies
  localize-views.sql  Postgres views with name:en
web/index.html      Leaflet map
data/               downloaded + cropped PBF (git ignored)
tiles/              rendered tiles, bind-mounted from the container volume (git ignored)
```