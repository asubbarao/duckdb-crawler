-- Lidl.fi -> DuckLake Pipeline
-- Discovers products via search, crawls product pages, extracts schema.org data
--
-- Usage:
--   ./build/release/duckdb -unsigned \
--     -cmd "LOAD 'build/release/extension/crawler/crawler.duckdb_extension'" \
--     -f scripts/lidl_to_ducklake.sql
--
-- Strategy:
--   1. Crawl Lidl.fi search pages (products are SPA-rendered but URLs are in Pinia state)
--   2. Extract product page URLs from embedded canonicalUrl in Pinia hydration data
--   3. Crawl individual product pages (these have rich schema.org Product JSON-LD)
--   4. Parse Product schema: sku, name, brand, price, availability, category
--   5. MERGE into DuckLake star schema (products dimension + prices fact table)

.timer on

INSTALL ducklake;
LOAD ducklake;

SET crawler_user_agent = 'DuckDB-Crawler/1.0 (price-comparison-research)';
SET crawler_default_delay = 2.0;

-- ============================================================
-- DuckLake setup
-- ============================================================
ATTACH IF NOT EXISTS 'ducklake:lidl.ducklake' AS lake;

CREATE TABLE IF NOT EXISTS lake.products (
    sku VARCHAR,
    name VARCHAR,
    brand VARCHAR,
    description VARCHAR,
    image_url VARCHAR,
    category VARCHAR,
    product_url VARCHAR,
    updated_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS lake.prices (
    sku VARCHAR,
    price DECIMAL(10,2),
    currency VARCHAR,
    availability VARCHAR,
    source_url VARCHAR,
    crawled_at TIMESTAMP
);

-- ============================================================
-- Stage 1: Discover product URLs from search pages
-- ============================================================
CREATE OR REPLACE TABLE search_results AS
SELECT * FROM crawl([
    'https://www.lidl.fi/q/search?q=maito',
    'https://www.lidl.fi/q/search?q=liha',
    'https://www.lidl.fi/q/search?q=juusto',
    'https://www.lidl.fi/q/search?q=kana',
    'https://www.lidl.fi/q/search?q=kala',
    'https://www.lidl.fi/q/search?q=jogurtti',
    'https://www.lidl.fi/q/search?q=pasta',
    'https://www.lidl.fi/q/search?q=kahvi',
    'https://www.lidl.fi/q/search?q=suklaa',
    'https://www.lidl.fi/q/search?q=banaani',
    'https://www.lidl.fi/q/search?q=tomaatti',
    'https://www.lidl.fi/q/search?q=peruna',
    'https://www.lidl.fi/q/search?q=omena',
    'https://www.lidl.fi/q/search?q=mehu',
    'https://www.lidl.fi/q/search?q=voi',
    'https://www.lidl.fi/q/search?q=riisi'
]);

SELECT 'Stage 1: Search pages' as step, count(*) FILTER (WHERE status = 200) as ok FROM search_results;

-- Extract product URLs from Pinia hydration state (HTML-entity-encoded JSON)
CREATE OR REPLACE TABLE product_urls AS
SELECT DISTINCT 'https://www.lidl.fi' || path as url
FROM (
    SELECT unnest(
        regexp_extract_all(html.document, 'canonicalUrl&quot;:&quot;(/p/[^&]+)&quot;', 1)
    ) as path
    FROM search_results WHERE status = 200
);

SELECT 'Stage 2: Product URLs' as step, count(*) as discovered FROM product_urls;

-- ============================================================
-- Stage 2: Crawl product pages (schema.org Product JSON-LD)
-- ============================================================
CREATE OR REPLACE TABLE product_crawls AS
SELECT c.*
FROM product_urls pu,
LATERAL crawl_url(pu.url) AS c;

SELECT 'Stage 3: Product pages' as step,
       count(*) as total,
       count(*) FILTER (WHERE status = 200) as ok,
       count(*) FILTER (WHERE html.schema['Product'] IS NOT NULL) as with_schema
FROM product_crawls;

-- ============================================================
-- Stage 3: Extract structured product data from schema.org
-- ============================================================
CREATE OR REPLACE TABLE parsed_products AS
SELECT
    json_extract_string(html.schema['Product']->0, '$.sku') as sku,
    json_extract_string(html.schema['Product']->0, '$.name') as name,
    json_extract_string(html.schema['Product']->0, '$.brand.name') as brand,
    json_extract_string(html.schema['Product']->0, '$.description') as description,
    json_extract_string(html.schema['Product']->0, '$.image[0]') as image_url,
    json_extract_string(html.schema['BreadcrumbList']->0, '$.name') as category,
    try_cast(
        json_extract_string(html.schema['Product']->0, '$.offers[0].price')
        AS DECIMAL(10,2)
    ) as price,
    json_extract_string(html.schema['Product']->0, '$.offers[0].priceCurrency') as currency,
    json_extract_string(html.schema['Product']->0, '$.offers[0].availability') as availability,
    final_url as source_url,
    current_timestamp as crawled_at
FROM product_crawls
WHERE status = 200
  AND html.schema['Product'] IS NOT NULL;

SELECT 'Stage 4: Parsed' as step, count(*) as products FROM parsed_products;

-- ============================================================
-- Stage 4: Merge into DuckLake
-- ============================================================

-- Upsert product dimension
MERGE INTO lake.products AS tgt
USING (
    SELECT DISTINCT ON (sku)
        sku, name, brand, description, image_url, category,
        source_url as product_url,
        current_timestamp as updated_at
    FROM parsed_products
    WHERE sku IS NOT NULL
    ORDER BY sku
) AS src
ON (tgt.sku = src.sku)
WHEN MATCHED THEN UPDATE SET
    name = src.name, brand = src.brand, description = src.description,
    image_url = src.image_url, category = src.category,
    product_url = src.product_url, updated_at = src.updated_at
WHEN NOT MATCHED THEN INSERT
    (sku, name, brand, description, image_url, category, product_url, updated_at)
    VALUES (src.sku, src.name, src.brand, src.description, src.image_url,
            src.category, src.product_url, src.updated_at);

-- Append price observations
INSERT INTO lake.prices (sku, price, currency, availability, source_url, crawled_at)
SELECT sku, price, currency, availability, source_url, crawled_at
FROM parsed_products
WHERE sku IS NOT NULL AND price IS NOT NULL;

-- ============================================================
-- Results
-- ============================================================
SELECT 'Products in DuckLake' as metric, count(*) as n FROM lake.products
UNION ALL
SELECT 'Price observations', count(*) FROM lake.prices;

SELECT p.sku, p.name, p.brand, p.category, pr.price, pr.currency, pr.availability
FROM lake.products p
JOIN lake.prices pr ON p.sku = pr.sku
ORDER BY p.name;
