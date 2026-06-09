# Custom tile-server image = the prebuilt overv image + our config & layers baked in.
#
# Why build our own instead of using overv/openstreetmap-tile-server directly:
# baking config into the image is the clean way to customize it. A single-file bind
# mount breaks the image's `sed -i` on that file ("Device or resource busy"); baked
# files are normal files, so the image's sed works and our changes survive container
# recreation. Everything static lives here; only the DB-side bits (the `en` views) are
# created at runtime by `make localize`, since they need the imported tables.
FROM overv/openstreetmap-tile-server:2.3.0

# 1) Postgres tuning - appended to the image's template (createPostgresConfig copies it
#    into conf.d on start; Postgres takes the last value, so ours override the defaults).
COPY postgresql-tuning.conf /tmp/postgresql-tuning.conf
RUN cat /tmp/postgresql-tuning.conf >> /etc/postgresql/14/main/postgresql.custom.conf.tmpl

# 2) Compile the osm-carto style at build time and bake an English variant whose table
#    references point at the `en` schema views (created at runtime by `make localize`).
RUN set -e; \
    if [ ! "$(ls -A /data/style/ 2>/dev/null)" ]; then \
        cp -a /home/renderer/src/openstreetmap-carto-backup/. /data/style/; \
    fi; \
    cd /data/style && carto project.mml > mapnik.xml; \
    sed -E 's/\bplanet_osm_(point|line|polygon|roads)\b/en.planet_osm_\1/g' mapnik.xml > mapnik-en.xml

# 3) Register the English layer with renderd (/tile-en/) and apache. Both baked, so they
#    load on container start and survive recreation - no runtime patching of these files.
#    renderd.conf is an explicit file (with [default] + [en]); apache gets the AddTileConfig.
COPY renderd.conf /etc/renderd.conf
RUN sed -i '/AddTileConfig \/tile\/ default/a\    AddTileConfig /tile-en/ en' /etc/apache2/sites-available/000-default.conf
