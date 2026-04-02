-- Probe Lidl.fi search API for product data
-- Products are embedded as HTML-entity-encoded JSON in Pinia state

LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Stage 1: Raw crawl of search pages for common grocery categories
CREATE OR REPLACE TABLE lidl_raw AS
SELECT *
FROM crawl([
    'https://www.lidl.fi/q/search?q=maito',
    'https://www.lidl.fi/q/search?q=leipa',
    'https://www.lidl.fi/q/search?q=liha',
    'https://www.lidl.fi/q/search?q=juusto',
    'https://www.lidl.fi/q/search?q=hedelma'
]);

SELECT 'Raw crawl done' as status, count(*) as pages FROM lidl_raw;

-- Stage 2: Extract product data from the Pinia state
-- The data is HTML-entity-encoded in a script tag
-- Pattern: {"productId":NNN,"productType":"RETAIL",...}
-- We need to: 1) extract the script, 2) decode HTML entities, 3) parse JSON

-- First, let's see what the decoded JSON looks like for one product
CREATE OR REPLACE TABLE lidl_products AS
WITH decoded AS (
    SELECT
        url,
        -- Decode HTML entities in the script content that contains product data
        replace(replace(replace(replace(replace(
            regexp_extract(html.document, '<script[^>]*>([^<]*productId[^<]*)</script>'),
            '&quot;', '"'),
            '&amp;', '&'),
            '&lt;', '<'),
            '&gt;', '>'),
            '&#39;', '''') as pinia_json
    FROM lidl_raw
    WHERE status = 200
),
-- Extract individual product JSON objects
products_raw AS (
    SELECT
        url,
        unnest(regexp_extract_all(pinia_json, '(\{"productId":\d+[^}]*"canonicalUrl":"[^"]*"[^}]*\})')) as product_json
    FROM decoded
    WHERE pinia_json IS NOT NULL AND pinia_json != ''
)
SELECT
    url as source_url,
    product_json,
    json_extract_string(product_json, '$.productId') as product_id,
    json_extract_string(product_json, '$.fullTitle') as full_title,
    json_extract_string(product_json, '$.canonicalUrl') as canonical_url,
    json_extract_string(product_json, '$.stockAvailability') as stock_availability,
    json_extract_string(product_json, '$.productType') as product_type
FROM products_raw;

SELECT 'Products extracted' as status, count(*) as products FROM lidl_products;
SELECT product_id, full_title, stock_availability, product_type, canonical_url
FROM lidl_products
LIMIT 20;
