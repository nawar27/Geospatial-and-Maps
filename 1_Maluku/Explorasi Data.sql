-- ============================================================
-- ANALISIS DATA \\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet (DuckDB)
-- Kolom: osm_id, code, fclass, population, name, geometry, bbox
-- ============================================================

-- Aktifkan untuk bagian == 2.  ANALISIS SPASIAL / GEOGRAFIS ==
-- Macro pengganti ST_Distance_Sphere: hitung jarak antar 2 titik lon/lat
-- (dalam kilometer, pakai rumus Haversine) digunakan dalam Analisis Spatial (Case 2)

CREATE OR REPLACE MACRO haversine_km(lon1, lat1, lon2, lat2) AS (
    6371 * 2 * ASIN(SQRT(
        POWER(SIN(RADIANS(lat2 - lat1) / 2), 2) +
        COS(RADIANS(lat1)) * COS(RADIANS(lat2)) *
        POWER(SIN(RADIANS(lon2 - lon1) / 2), 2)
    ))
);

-- ============================================================
-- 1. DEMOGRAFI & SEBARAN PENDUDUK
-- ============================================================

-- 1.1 Ranking wilayah dengan populasi terbesar
SELECT name, fclass, population
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet'
WHERE population > 0
ORDER BY population DESC
LIMIT 20;

-- 1.2 Total & rata-rata populasi per jenis wilayah (fclass)
SELECT
    fclass,
    COUNT(*)                       AS jumlah_entitas,
    SUM(population)                AS total_populasi,
    ROUND(AVG(population), 2)      AS rata_rata_populasi,
    MAX(population)                AS populasi_terbesar
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet'
GROUP BY fclass
ORDER BY total_populasi DESC;

-- 1.3 Jumlah & proporsi tiap kategori fclass
SELECT
    fclass,
    code,
    COUNT(*) AS jumlah,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS persen
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet'
GROUP BY fclass, code
ORDER BY jumlah DESC;

-- ============================================================
-- 2. ANALISIS SPASIAL / GEOGRAFIS
-- ============================================================

-- 2.1 Jarak antar kota-kota besar (fclass = 'city'), dalam km
SELECT
    a.name AS kota_a,
    b.name AS kota_b,
    ROUND(haversine_km(a.bbox.xmin, a.bbox.ymin, b.bbox.xmin, b.bbox.ymin), 2) AS jarak_km
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' a
JOIN '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' b
    ON a.fclass = 'city' AND b.fclass = 'city' AND a.osm_id < b.osm_id
ORDER BY jarak_km;

-- 2.2 Kota/desa terdekat dari sebuah titik acuan (contoh: pelabuhan/bandara)
--     Ganti nilai lon/lat sesuai titik acuan yang diinginkan
WITH acuan AS (
    SELECT 128.190 AS lon, -3.700 AS lat  -- contoh: sekitar Ambon
)
SELECT
    m.name,
    m.fclass,
    ROUND(haversine_km(m.bbox.xmin, m.bbox.ymin, acuan.lon, acuan.lat), 2) AS jarak_km
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' m, acuan
ORDER BY jarak_km
LIMIT 10;

-- 2.3 Pulau paling terisolasi (jarak ke kota terdekat paling jauh)
WITH kota AS (
    SELECT name, bbox.xmin AS lon, bbox.ymin AS lat
    FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' WHERE fclass = 'city'
),
pulau AS (
    SELECT name, bbox.xmin AS lon, bbox.ymin AS lat
    FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' WHERE fclass = 'island'
)
SELECT
    p.name AS nama_pulau,
    MIN(ROUND(haversine_km(p.lon, p.lat, k.lon, k.lat), 2)) AS jarak_ke_kota_terdekat_km
FROM pulau p
CROSS JOIN kota k
GROUP BY p.name
ORDER BY jarak_ke_kota_terdekat_km DESC
LIMIT 15;

-- 2.4 Cek titik-titik yang berdekatan (< 500 meter) 
-- untuk mencari duplikasi entitas yang sama
SELECT
    a.name AS nama_a,
    b.name AS nama_b,
    ROUND(haversine_km(a.bbox.xmin, a.bbox.ymin, b.bbox.xmin, b.bbox.ymin) * 1000, 1) AS jarak_meter
FROM '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' a
JOIN '\\wsl$\Ubuntu\home\nawar\maluku\maluku.parquet' b
    ON a.osm_id < b.osm_id
    AND haversine_km(a.bbox.xmin, a.bbox.ymin, b.bbox.xmin, b.bbox.ymin) * 1000 < 500
ORDER BY jarak_meter;


-- ============================================================
-- GENERATE LAYER UNTUK QGIS DARI maluku.gpkg
-- Menggunakan DuckDB + spatial + h3 extension
-- Data sumber: osm_id, code, fclass, population, name, geom (POINT)
-- ============================================================

-- 1. Agregasi data kota/desa ke dalam bentuk heksagon (H3 Index) dan simpan ke Parquet
COPY (
    WITH hexagon_indexed AS (
        SELECT 
            h3_latlng_to_cell(ST_Y(geometry), ST_X(geometry), 5) AS hex_id,
            name,
            fclass,
            population
        FROM 'maluku.parquet'
        WHERE population > 0
    )
    SELECT
        ST_AsWKB(ST_GeomFromText(h3_cell_to_boundary_wkt(hex_id))) AS geometry,
        name,
        fclass,
        population
    FROM hexagon_indexed
) TO 'maluku.cities_hexagons_res5.parquet' (
    FORMAT 'PARQUET', 
    CODEC 'ZSTD',
    COMPRESSION_LEVEL 22, 
    ROW_GROUP_SIZE 15000
);


-- 2. Agregasi data fclass spasial ke dalam bentuk heksagon (H3 Index) dan gabungkan geometri yang sama
COPY (
    WITH hexagon_indexed AS (
        SELECT 
            h3_latlng_to_cell(ST_Y(geometry), ST_X(geometry), 5) AS hex_id,
            fclass,
            code
        FROM 'maluku.parquet'
    ),
    
    hexagon_geoms AS (
        SELECT 
            ST_GeomFromText(h3_cell_to_boundary_wkt(hex_id)) AS geom,
            fclass,
            code
        FROM hexagon_indexed
    ),
    
    dissolved_data AS (
        SELECT 
            fclass,
            code,
            COUNT(*) AS jumlah,
            ST_Union_Agg(geom) AS merged_geom
        FROM hexagon_geoms
        GROUP BY fclass, code
    ),
    total_stats AS (
        SELECT COUNT(*) AS total_entitas FROM 'maluku.parquet'
    )
    SELECT
        ST_AsWKB(merged_geom) AS geometry,
        fclass,
        code,
        jumlah,
        ROUND(jumlah * 100.0 / total_stats.total_entitas, 2) AS persen
    FROM dissolved_data, total_stats
) TO 'maluku.fclass_dissolved_res5.parquet' (
    FORMAT 'PARQUET', 
    CODEC 'ZSTD',
    COMPRESSION_LEVEL 22, 
    ROW_GROUP_SIZE 15000
);

-- 3. Agregasi data populasi spasial ke dalam bentuk heksagon (H3 Index)

CREATE OR REPLACE TABLE h3_population AS
    SELECT
        h3: H3_LATLNG_TO_CELL(ST_Y(geometry), ST_X(geometry), 6),
        jumlah_entitas: COUNT(*),
        total_populasi: SUM(population),
        rata_rata_populasi: ROUND(AVG(population), 2),
        populasi_terbesar: MAX(population)
    FROM 'maluku.parquet'
    WHERE population > 0
    GROUP BY 1;

COPY (
    SELECT
        geometry: ST_ASWKB(H3_CELL_TO_BOUNDARY_WKT(h3)::geometry),
        jumlah_entitas,
        total_populasi,
        rata_rata_populasi,
        populasi_terbesar
    FROM h3_population
) TO 'maluku.fclass_hexagon.parquet' (
        FORMAT 'PARQUET', CODEC 'ZSTD',
        COMPRESSION_LEVEL 22, ROW_GROUP_SIZE 15000);