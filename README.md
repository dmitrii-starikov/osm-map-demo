# OSM Tile Server Demo — Kamchatka

A self-hosted OpenStreetMap raster tile server for the Petropavlovsk–Yelizovo–Paratunka
area of Kamchatka, shown as a small Leaflet web map. Built on the all-in-one
[`overv/openstreetmap-tile-server`](https://github.com/Overv/openstreetmap-tile-server)
image (renderd + mod_tile + osm-carto + PostgreSQL/PostGIS in one container) with an
nginx front-end.

This is the **hands-on companion** to [`osm-tile-server-article.md`](./osm-tile-server-article.md):
the article covers a planet-scale server on bare metal; this demo runs the same pipeline
laptop-sized and exposes the article's **tuning techniques as runnable `make` targets**.

## Architecture

```
PBF dump → osmium (crop to bbox) → osm2pgsql → PostGIS → renderd → Apache/mod_tile
                                                                          │
                                            nginx (/osm/ → /tile/) ◄───────┘
                                                  │
                                              Leaflet (web/index.html)
```

- **tile-server** — the overv image. Runs its own PostgreSQL, imports the PBF, builds the
  osm-carto style, and serves tiles at `/tile/` on port 8080.
- **web** — nginx serving the Leaflet map on port 3000 and proxying `/osm/` to `/tile/`.

## Quick start

```bash
make setup
```

Downloads the Far-Eastern district PBF (~360 MB), crops it to the Kamchatka bbox, imports
it, starts the services, and pre-renders zooms 0–10. First run ≈ 5–10 min (most of it
importing the global water polygons osm-carto needs for coastlines). Then:

- Map: http://localhost:3000  (the **RU/EN** button switches the interface)
- Tiles: http://localhost:8080/osm/10/961/331.png
- renderd status: http://localhost:8080/mod_tile

Requirements: Docker + Docker Compose v2, and ~7 GB free disk for the default region
(see the cost table below).

## Commands

| Command | What it does |
|---|---|
| `make setup` | Full first run: download → crop → build → import → start → localize → render |
| `make build` | Build the custom image (overv image + baked tuning & English layer) |
| `make localize` | Create the `en` DB views and load the baked English layer |
| `make start` · `make stop` · `make restart` | Manage the containers |
| `make render` / `make render-high` | Pre-render z0–z10 / z11 |
| `make clear-tiles` | Delete rendered tiles (keeps the DB) |
| `make status` | Containers, DB size, tiles on disk |
| `make logs` · `make logs-tiles` | Follow logs |
| `make shell-tiles` · `make shell-db` | bash / psql inside the tile-server |
| `make clean` | Remove containers, volumes, tiles and downloaded data |

`make help` lists everything.

## Tuning demos (the article's techniques, runnable)

> **What these demonstrate.** The demo shows the *mechanics* of the article's tuning, not
> the *payoff*. On 8 MB of data the tuning doesn't visibly speed anything up, and the index
> benchmark toggles an index the image already created. The payoff only appears at scale —
> read the demo as "here are the levers" and the article as "here's what they buy you."

| Command | Shows |
|---|---|
| `make index-benchmark` | A coastal spatial query with vs without the GIST index |
| `make render-benchmark` | On-demand render vs disk-cache hit (why you pre-render) |
| `make style-no-boundaries` | Hides admin boundaries (the article's `AND 1>2` trick) |
| `make style-reset` | Restores the stock osm-carto style |

`style-no-boundaries` edits the style in the running container; it survives `make restart`
but resets on container recreation (`make clean`/rebuild) — re-run it, or `make style-reset`
to undo immediately. After a change, run `make render` (or pan the map) to regenerate tiles.

**Index benchmark — real numbers from this demo:**

```
WITH GIST index:    Index Scan …   ~1.7 ms
WITHOUT index:      Seq Scan …     ~1250 ms     →  ≈ 740× faster
```

This holds up even on a tiny region because the queried table — global coastline
`water_polygons` (~1.2 GB) — is the **same size regardless of region**. Note this ~740× is
a *single query*; the article's ~150× is a *whole tile render* (dozens of such queries).
Same mechanism (`index scan` vs `seq scan`), different metric. The index itself is
`indexes.sql` from osm-carto, which the image runs automatically at import.

**Render benchmark — on-demand vs cache:** `make render-benchmark` fetches a 10×10 tile
block at z13 (not pre-rendered) twice — the first pass renders on demand, the second hits
the disk cache:

```
cold (on-demand render):   ~3.2 s   per 100 tiles
warm (cache hit):          ~0.7 s   per 100 tiles     →  ~5× — that's why you pre-render
```

(mod_tile renders 8×8 metatiles, so 100 contiguous tiles are ~4 renders; the gap grows with
zoom and data density.)

**Localized labels (live English layer):** the **RU/EN** button switches the *whole map*,
not just the UI. EN is a second renderd layer (`/tile-en/`, exposed by nginx as `/osm-en/`)
that renders `name:en` via DB **views** (`config/localize-views.sql`) — no CartoCSS edits,
no data mutation. The layer (mapnik-en.xml + renderd `[en]` + apache config) is **baked into
the custom image** (`docker/Dockerfile`); only the views are created at runtime by
`make localize` (they need the imported tables). Tiles render lazily on first view, then
cache in `tiles/en/`. On Kamchatka the native `name` is already Russian, so the default
`/osm/` layer *is* the Russian map — no separate ru layer needed.

## Other regions (mind the disk!)

The region is parametrized. Override `PBF_URL` and `BBOX`:

```bash
# Whole country, no cropping (BBOX empty):
make PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf BBOX= setup
```

**DB size depends on the imported region, not on the render zoom** (the zoom limit only
caps *tile* disk). DB ≈ 10–15× the PBF, plus a fixed ~2–3 GB of global water/coastline
data that every import pulls.

| Region | PBF | DB (≈) | Import (≈) | Fits a laptop? |
|---|---|---|---|---|
| Kamchatka bbox (default) | 8 MB | ~3 GB | ~5–10 min | yes |
| Luxembourg | ~40 MB | ~3–4 GB | ~10 min | yes |
| Germany | ~4 GB | ~40 GB | ~30–60 min | only with disk |
| USA | ~11 GB | ~100 GB+ | hours | no |
| Planet | ~70 GB | ~1.7 TB | ~5 days | server only |

For the planet, follow the bare-metal path in the article (tuned Postgres, separate
volumes, chunked rendering) — Docker is for experimenting, not for the planet.

## Layout

```
compose.yml         services: tile-server (built from docker/) + web
Makefile            build / run / render + tuning targets
docker/
  Dockerfile        custom image = overv image + baked tuning + English layer
  postgresql-tuning.conf  Postgres tuning, baked in and APPLIED (see note)
  renderd.conf      renderd config ([default] + [en] layers), baked in
config/
  nginx.conf        web UI + /osm/ → /tile/ and /osm-en/ → /tile-en/ proxies
  localize-views.sql  DB views with name:en, read by the baked English layer
web/index.html      Leaflet map (+ RU/EN toggle)
data/               downloaded + cropped PBF (gitignored)
tiles/              rendered tiles, bind-mounted from the container (gitignored)
```

## Notes

- **The base image is a toolkit, not a tuned/customized server.** `overv/openstreetmap-tile-server`
  bundles the whole stack (PostgreSQL/PostGIS + renderd + mod_tile + stock osm-carto) with
  *generic, conservative* defaults (e.g. `shared_buffers=128MB`) — not tuned to your hardware
  and not customized (no boundary removal, no Russian names). Everything beyond that is on us.
- **Customizations are baked into a custom image.** `docker/Dockerfile` (built by
  `make build`, referenced from `compose.yml` via `build: ./docker`) bakes in: the Postgres
  tuning (`postgresql-tuning.conf`, appended to the image's template), the renderd config
  (`renderd.conf`, `[default]` + `[en]`), the compiled osm-carto style, and the English
  layer (`mapnik-en.xml` + apache config). Baked, so
  it all survives container recreation — only the DB `en` views are created at runtime
  (`make localize`). To use the stock image instead, flip the `image:`/`build:` lines in
  `compose.yml`. Tuning values are for ~16 GB RAM; the article covers planet-scale 64 GB.
- **Why bake config instead of bind-mounting it?** The image `sed -i`'s its own configs on
  start; a single-file bind mount breaks that ("Device or resource busy"). Baked files are
  normal files, so the image's sed works and our config persists.
- **Public tile URL** is `/osm/` (what Leaflet requests); nginx proxies it to the image's
  native `/tile/`.
- **`tiles/` permissions:** the renderer writes as uid 1000 inside the container, so the
  Makefile pre-creates `./tiles` with open perms before any `docker compose` command —
  otherwise Docker creates it as root and rendering fails. The image's entrypoint must run
  as root (initdb/postgres/apache), so setting `user:` on the container is not an option.
```
