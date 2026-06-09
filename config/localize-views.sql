-- localize-views.sql - per-language schemas of views over the osm2pgsql tables where the
-- `name` column is replaced by COALESCE(tags->'name:<lang>', name). The localized tile
-- layers (mapnik-<lang>.xml → /tile-<lang>/) read from these, so the same osm-carto style
-- renders localized labels without editing 90 KB of CartoCSS and without mutating the data.
--
-- Applied once by `make localize` (after import). Add languages to the array as needed;
-- the demo only serves `en` live (on Kamchatka the native `name` is already Russian, so
-- the default /osm/ layer IS the Russian map - no separate ru layer needed).

DO $$
DECLARE
  lang text;
  t    text;
  cols text;
BEGIN
  FOREACH lang IN ARRAY ARRAY['en'] LOOP
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', lang);
    EXECUTE format('CREATE SCHEMA %I', lang);
    FOREACH t IN ARRAY ARRAY['planet_osm_point','planet_osm_line','planet_osm_polygon','planet_osm_roads'] LOOP
      SELECT string_agg(
               CASE WHEN column_name = 'name'
                    THEN format('COALESCE(tags->%L, name) AS name', 'name:' || lang)
                    ELSE format('%I', column_name) END,
               ', ' ORDER BY ordinal_position)
        INTO cols
        FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = t;
      EXECUTE format('CREATE VIEW %I.%I AS SELECT %s FROM public.%I', lang, t, cols, t);
    END LOOP;
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO renderer', lang);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO renderer', lang);
  END LOOP;
END $$;
