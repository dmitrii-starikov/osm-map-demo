# ═══════════════════════════════════════════════════════════════════════════════
#  OSM Demo - Makefile
#  Kamchatka · Yelizovo - Petropavlovsk - Paratunka
# ═══════════════════════════════════════════════════════════════════════════════
# Region
# Default: Far Eastern district cropped to a Kamchatka bbox.
# Example for another region:
#   make PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf BBOX= setup
PBF_URL    ?= https://download.geofabrik.de/russia/far-eastern-fed-district-latest.osm.pbf
BBOX       ?= 157.5,52.0,160.0,54.0
PBF_FULL    = data/$(notdir $(PBF_URL))
REGION_PBF  = data/region.osm.pbf
TILE_IMAGE  = overv/openstreetmap-tile-server:2.3.0

# osmium bbox format: left,bottom,right,top
TILE_DIR    = /data/tiles
RENDER_SOCK = /run/renderd/renderd.sock
THREADS     = 4

.PHONY: all setup download crop build import start stop restart restart-renderer \
        wait-renderd localize render render-high clear-tiles \
        index-benchmark render-benchmark style-no-boundaries style-reset \
        logs logs-tiles \
        status shell-tiles shell-db clean help

all: help

# Full first-time run
setup:
	@$(MAKE) download
	@$(MAKE) crop
	@$(MAKE) build
	@$(MAKE) import
	@$(MAKE) start
	@$(MAKE) localize
	@$(MAKE) render
	@echo "Visit http://localhost:3000"

# Download the PBF
download:
	@mkdir -p data
	wget -c --progress=bar:force -O $(PBF_FULL) $(PBF_URL)

# Crop the dump to BBOX (or use it whole when BBOX is empty)
# Cropping shrinks the database a lot: we import only the bbox, not the whole dump.
# osmium is taken from the tile-server image, so no extra package is needed.
crop:
	@if [ -z "$(strip $(BBOX))" ]; then \
		ln -sf $(notdir $(PBF_FULL)) $(REGION_PBF); \
	elif [ -f "$(REGION_PBF)" ] && [ ! -L "$(REGION_PBF)" ]; then \
		true; \
	else \
		docker run --rm --entrypoint osmium -v "$(CURDIR)/data:/data" \
			$(TILE_IMAGE) extract -b $(BBOX) \
			/data/$(notdir $(PBF_FULL)) -o /data/$(notdir $(REGION_PBF)) --overwrite; \
	fi

# Build the custom image (overv image + baked Postgres tuning)
build:
	docker compose build

# Import the PBF into PostgreSQL
import:
	@mkdir -p tiles && chmod 777 tiles
	docker compose run --rm tile-server import

# Start all the services
# Create ./tiles up front with open perms: the bind mount is written by the renderer
# user (uid 1000) inside the container, which differs from the host user. Without this
# Docker would create ./tiles as root and rendering would fail with EACCES.
# (The image's entrypoint must run as root - initdb/postgres/apache - so we can't just
#  set `user:` on the container; pre-creating the dir is the right fix.)
start:
	@mkdir -p tiles && chmod 777 tiles
	docker compose up -d
	@$(MAKE) wait-renderd

stop:
	docker compose stop

restart:
	docker compose restart

restart-renderer:
	docker compose restart tile-server

# Wait until renderd and apache are ready
wait-renderd:
	@until docker compose exec -T tile-server test -S $(RENDER_SOCK) 2>/dev/null \
	     && curl -sf -o /dev/null http://localhost:8080/mod_tile 2>/dev/null; do \
		sleep 1; done

# Create the localized (en) views and load them into renderd
# The English layer itself (renderd [en] + apache + mapnik-en.xml) is baked into the
# image; only the `en` DB views need creating, and they need the imported tables. One
# restart afterwards so renderd reloads the en layer now that the views exist. On later
# starts the views are already in the volume, so this isn't needed again.
localize:
	@$(MAKE) wait-renderd
	docker compose exec -T tile-server sudo -u postgres psql -d gis -q -v ON_ERROR_STOP=1 < config/localize-views.sql
	docker compose restart tile-server >/dev/null
	@$(MAKE) wait-renderd

# Pre-render z0–z10
# z0–z6: the whole world
# z7–z10: the Kamchatka bbox only (fast)
# NOTE: --all is required so render_list renders the given x/y/z range;
#       without it render_list waits for a tile list on STDIN and renders nothing.
render: wait-renderd
	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) -z 0 -Z 6

	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) \
		-x 120 -X 120 -y 41 -Y 41 -z 7 -Z 7

	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) \
		-x 240 -X 241 -y 82 -Y 83 -z 8 -Z 8

	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) \
		-x 480 -X 482 -y 165 -Y 167 -z 9 -Z 9

	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) \
		-x 961 -X 965 -y 331 -Y 335 -z 10 -Z 10

# High zoom render
render-high: wait-renderd
	docker compose exec tile-server \
		render_list --all -f -n $(THREADS) \
		-t $(TILE_DIR) -s $(RENDER_SOCK) \
		-x 1922 -X 1930 -y 663 -Y 670 -z 11 -Z 11

clear-tiles:
	docker compose exec tile-server rm -rf $(TILE_DIR)/default

# -----------------------------------
#  Tuning demos

# GIST index benchmark
# Times a coastal spatial query against the global water_polygons table (~1.2 GB)
# with vs without its GIST index - the index-scan-vs-seq-scan effect from the
# article, measurable even on this small region because that table is global.
index-benchmark:
	@idx=$$(docker compose exec -T tile-server sudo -u postgres psql -d gis -tAc \
		"SELECT indexname FROM pg_indexes WHERE tablename='water_polygons' AND indexdef ILIKE '%gist%';" | tr -d '\r'); \
	q="SELECT count(*) FROM water_polygons WHERE ST_Intersects(way, ST_Transform(ST_MakeEnvelope(158.3,52.7,158.9,53.2,4326),3857));"; \
	docker compose exec -T tile-server sudo -u postgres psql -d gis -P pager=off -c "EXPLAIN ANALYZE $$q" | grep -iE 'Scan|Execution Time'; \
	docker compose exec -T tile-server sudo -u postgres psql -d gis -c "DROP INDEX $$idx;" >/dev/null; \
	docker compose exec -T tile-server sudo -u postgres psql -d gis -P pager=off -c "EXPLAIN ANALYZE $$q" | grep -iE 'Scan|Execution Time'; \
	docker compose exec -T tile-server sudo -u postgres psql -d gis -c "CREATE INDEX $$idx ON water_polygons USING gist(way);" >/dev/null

# On-demand vs cached tile benchmark
# Fetches a 10×10 tile block twice. z13 isn't pre-rendered in the demo, so it's cleared
# first: the cold pass renders on demand, the warm pass hits the disk cache. mod_tile
# renders in 8×8 metatiles, so a 10×10 block triggers ~4 renders. Override BENCH_X/Y/Z.
BENCH_Z ?= 13
BENCH_X ?= 7704
BENCH_Y ?= 2664
render-benchmark: wait-renderd
	@docker compose exec -T tile-server rm -rf $(TILE_DIR)/default/$(BENCH_Z) 2>/dev/null || true
	@z=$(BENCH_Z); x0=$(BENCH_X); y0=$(BENCH_Y); \
	run() { s=$$(date +%s.%N); for x in $$(seq $$x0 $$((x0+9))); do for y in $$(seq $$y0 $$((y0+9))); do \
		curl -s -o /dev/null "http://localhost:8080/tile/$$z/$$x/$$y.png"; done; done; \
		e=$$(date +%s.%N); printf '%.2f' "$$(echo "$$e - $$s" | bc)"; }; \
	run; \
	run

# Hide administrative boundaries (article's `AND 1>2` trick
# Patches the osm-carto project.mml so the admin-boundary layers select nothing,
# recompiles the style, and clears tiles. Run `make render` to see the effect.
style-no-boundaries:
	docker compose exec -T tile-server bash -c "cd /data/style && \
		grep -q \"administrative' AND 1>2\" project.mml || \
		sed -i \"s/boundary = 'administrative'/boundary = 'administrative' AND 1>2/g\" project.mml && \
		carto project.mml > mapnik.xml"
	@$(MAKE) restart-renderer
	@$(MAKE) clear-tiles

# Restore the stock osm-carto style
style-reset:
	docker compose exec -T tile-server bash -c "cp /home/renderer/src/openstreetmap-carto-backup/project.mml /data/style/project.mml && \
		cd /data/style && carto project.mml > mapnik.xml"
	@$(MAKE) restart-renderer
	@$(MAKE) clear-tiles

logs:
	docker compose logs -f

logs-tiles:
	docker compose logs -f tile-server

status:
	@docker compose ps
	@docker compose exec tile-server sudo -u postgres psql -d gis \
		-c "SELECT pg_size_pretty(pg_database_size('gis')) AS \"DB size\";" \
		2>/dev/null || true
	@docker compose exec tile-server du -sh $(TILE_DIR) 2>/dev/null || true

shell-tiles:
	docker compose exec tile-server bash

shell-db:
	docker compose exec tile-server sudo -u postgres psql -d gis

clean:
	@read -p "Containers, volumes, tiles, PBFs will be deleted. Continue? [y/N] " ans && [ "$$ans" = "y" ]
	docker compose down -v --remove-orphans
	-docker run --rm --entrypoint rm -v "$(CURDIR):/work" $(TILE_IMAGE) -rf /work/data /work/tiles
	-rm -rf data tiles

help:
	@echo "  OSM Demo - Kamchatka"
	@echo ""
	@echo "  First run:"
	@echo "    make setup"
	@echo ""
	@echo "  Service management:"
	@echo "    make start"
	@echo "    make stop / restart"
	@echo "    make restart-renderer"
	@echo "    make status"
	@echo ""
	@echo "  Rendering:"
	@echo "    make render"
	@echo "    make render-high"
	@echo "    make clear-tiles"
	@echo ""
	@echo "  Benchmarks:"
	@echo "    make index-benchmark"
	@echo "    make render-benchmark"
	@echo "    make style-no-boundaries"
	@echo "    make style-reset"
	@echo ""
	@echo "  Debug:"
	@echo "    make logs / logs-tiles"
	@echo "    make shell-tiles"
	@echo "    make shell-db"
	@echo "    make clean"
	@echo ""