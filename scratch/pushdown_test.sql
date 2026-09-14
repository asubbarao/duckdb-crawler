-- STREAM LIMIT Pushdown Test for DuckDB Crawler
--
-- STREAM INTO with LIMIT enables true early termination of HTTP fetches:
-- - Single-stage: crawl() stops after LIMIT rows
-- - Multi-stage (LATERAL): crawl_url() shares pipeline state across calls
--
-- This allows efficient scraping with automatic HTTP request limiting.

LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

.timer on

-- ============================================================================
-- TEST 1: STREAM with LIMIT - pushdown WORKS
-- Expected: 2 rows inserted AND 2 URLs fetched (true early termination)
-- ============================================================================
SELECT 'TEST 1: STREAM with LIMIT 2 (pushdown works)' as test;
DROP TABLE IF EXISTS __crawler_cache;
DROP TABLE IF EXISTS test_results;

STREAM (
    SELECT url, status FROM crawl([
        'https://httpbin.org/delay/0?id=1',
        'https://httpbin.org/delay/0?id=2',
        'https://httpbin.org/delay/0?id=3',
        'https://httpbin.org/delay/0?id=4'
    ])
) INTO test_results LIMIT 2;

SELECT 'Results inserted:' as label;
SELECT * FROM test_results;

SELECT 'HTTP requests made (should be ~2):' as label;
SELECT url, status_code, cached_at FROM __crawler_cache ORDER BY cached_at;

-- ============================================================================
-- TEST 2: Two-stage STREAM with LIMIT (LATERAL pushdown working!)
-- Expected: 2 rows inserted, 4 HTTP requests (2 listing + 2 detail)
-- The pipeline state is shared across LATERAL crawl_url() calls
-- ============================================================================
SELECT 'TEST 2: Two-stage STREAM with LIMIT 2 (LATERAL pushdown works!)' as test;
DROP TABLE IF EXISTS __crawler_cache;
DROP TABLE IF EXISTS job_details;

STREAM (
    SELECT
        detail.url,
        detail.status,
        htmlpath(detail.html.document, 'script@$jobs[0]')::JSON->>'Posting_Title' as title
    FROM crawl([
        'https://carrieres.os4techno.com/',
        'https://recruit.srilankan.com/'
    ]) AS listing,
    LATERAL unnest(htmlpath(listing.html.document, 'input#jobs@value[*].id')::BIGINT[]) AS t(job_id),
    LATERAL crawl_url(format('{}jobs/Careers/{}', listing.url, job_id)) AS detail
    WHERE listing.status = 200 AND detail.status = 200
) INTO job_details LIMIT 2;

SELECT 'Results inserted:' as label;
SELECT * FROM job_details;

SELECT 'HTTP requests made (should be 4 - 2 listing + 2 detail):' as label;
SELECT url, status_code, cached_at FROM __crawler_cache ORDER BY cached_at;
-- Note: Pipeline state is shared via database instance, allowing LIMIT pushdown
-- through LATERAL crawl_url() calls

-- ============================================================================
-- TEST 3: Direct crawl() with max_results (baseline)
-- Expected: 2 rows AND 2 URLs fetched
-- ============================================================================
SELECT 'TEST 3: crawl() with max_results=2 (true early stop)' as test;
DROP TABLE IF EXISTS __crawler_cache;

SELECT url, status FROM crawl([
    'https://httpbin.org/delay/0?id=1',
    'https://httpbin.org/delay/0?id=2',
    'https://httpbin.org/delay/0?id=3',
    'https://httpbin.org/delay/0?id=4'
], max_results := 2);

SELECT 'HTTP requests made (should be 2):' as label;
SELECT url, status_code, cached_at FROM __crawler_cache ORDER BY cached_at;

-- ============================================================================
-- SUMMARY:
-- - STREAM LIMIT: pushes max_results into crawl() calls (works!)
-- - LATERAL crawl_url: shares pipeline state via database instance (works!)
-- - True early termination for both single-stage and multi-stage pipelines
-- ============================================================================
