-- ============================================================================
-- Crawler Extension Examples
-- ============================================================================

LOAD crawler;

-- ============================================================================
-- Example 1: Link-following crawl (httpbin.org - no sitemap)
-- ============================================================================

CRAWL (SELECT 'httpbin.org')
INTO httpbin_pages
WITH (
    user_agent 'CrawlBot/1.0 (+https://example.com/bot)',
    follow_links true,
    max_crawl_pages 10,
    max_crawl_depth 2
);

SELECT * FROM _crawl_sitemap_discovery_status WHERE hostname = 'httpbin.org';
SELECT url, http_status, elapsed_ms FROM httpbin_pages;

-- ============================================================================
-- Example 2: Sitemap-based crawl (fyff.ee)
-- ============================================================================

CRAWL (SELECT 'fyff.ee')
INTO fyff_pages
WITH (user_agent 'CrawlBot/1.0 (+https://example.com/bot)');

SELECT * FROM _crawl_sitemap_discovery_status WHERE hostname = 'fyff.ee';
SELECT url, http_status, elapsed_ms FROM fyff_pages;

-- ============================================================================
-- Example 3: Stop a running crawl
-- ============================================================================

-- STOP CRAWL INTO httpbin_pages;
