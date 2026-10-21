-- Seed for the PostgreSQL side of the demos (demo 2: temporary instance, demo 3: Aiven for PostgreSQL).
-- Usage:  psql -v rows=1000000 -f sql/pg_seed.sql
-- Same shape as the ClickHouse table shop.beer_sales from demo 1.

DROP TABLE IF EXISTS beer_sales;

CREATE TABLE beer_sales (
    beer_name text      NOT NULL,
    country   text      NOT NULL,
    liters    real      NOT NULL,
    sold_at   timestamp NOT NULL
);

INSERT INTO beer_sales (beer_name, country, liters, sold_at)
SELECT names[i],
       countries[i],
       round((0.3 + random() * 24)::numeric, 1),
       now() - random() * interval '90 days'
FROM (SELECT 1 + floor(random() * 12)::int AS i FROM generate_series(1, :rows)) r,
     (SELECT ARRAY['Chimay', 'Leffe bruin', 'Duvel', 'Pilsner Urquell', 'Budvar', 'Koelsch',
                   'Weizen', 'Guinness', 'Heineken', 'Estrella Damm', 'Samuel Adams', 'Moretti'] AS names,
             ARRAY['BE', 'BE', 'BE', 'CZ', 'CZ', 'DE',
                   'DE', 'IE', 'NL', 'ES', 'US', 'IT'] AS countries) a;

ANALYZE beer_sales;
