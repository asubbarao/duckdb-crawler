# DuckDB Crawler Extension - Examples

Community `LOAD crawler` registers `crawl()` / `crawl_url()` / `sitemap()`. Named param `timeout` is **seconds**. Session default `crawler_timeout_ms` is **milliseconds**. `CRAWL (SELECT …) INTO` is a parser error on stock community.

## Basic Usage

### Crawl a website

```sql
INSTALL crawler FROM community;
LOAD crawler;

CREATE TABLE pages AS
SELECT * FROM crawl(
    'https://example.com/',
    user_agent := 'MyBot/1.0',
    timeout := 30,
    max_results := 100
);

SELECT url, status, content_type FROM pages;
```

### Crawl localhost for testing

```sql
CREATE TABLE test_pages AS
SELECT * FROM crawl(
    'http://localhost:8080/test.html',
    user_agent := 'TestBot/1.0',
    timeout := 30,
    max_results := 1
);
```

### LIMIT pushdown

`max_results` (and `LIMIT` on `crawl()`) stop the fetch after N pages:

```sql
SELECT * FROM crawl('https://example.com/', user_agent := 'Bot/1.0', timeout := 30, max_results := 50);
SELECT * FROM crawl('https://example.com/', user_agent := 'Bot/1.0', timeout := 30) LIMIT 50;
```

## Result Table Schema

`crawl()` / `crawl_url()` columns:

| Column | Type | Description |
|--------|------|-------------|
| `url` | VARCHAR | Fetched URL |
| `status` | INTEGER | HTTP status code |
| `content_type` | VARCHAR | MIME type |
| `html` | STRUCT | `document`, `js`, `meta`, `opengraph`, `schema`, `readability`, `hydration` |
| `final_url` | VARCHAR | URL after redirects |
| `error` | VARCHAR | Error message if failed |
| `extract` | VARCHAR | Result of `extract` specs |
| `response_time_ms` | BIGINT | Request duration |
| `depth` | INTEGER | Depth from seed |

## Named parameters

`timeout` is **seconds** on every TVF. `SET crawler_timeout_ms` is **milliseconds**.

### crawl()

| Param | Type | Description |
|-------|------|-------------|
| `timeout` | INTEGER | HTTP timeout **in seconds** |
| `max_results` | BIGINT | Cap on pages returned |
| `max_depth` | INTEGER | Max follow depth |
| `workers` | INTEGER | Concurrent requests |
| `delay` | INTEGER | Per-domain delay (milliseconds in the binder) |
| `respect_robots` | BOOLEAN | Honor robots.txt |
| `cache` | BOOLEAN | HTTP response cache |
| `cache_ttl` | INTEGER | Cache TTL (hours) |
| `user_agent` | VARCHAR | User-Agent header |
| `extract` | LIST(VARCHAR) | Extraction specs |
| `follow` | VARCHAR | CSS selector for links to follow |
| `batch_size` | INTEGER | URLs per fetch batch |
| `state_table` | VARCHAR | Persistent crawl-state table |

### crawl_url()

| Param | Type | Description |
|-------|------|-------------|
| `timeout` | INTEGER | HTTP timeout **in seconds** |
| `max_results` | BIGINT | Cap on results |
| `cache` | BOOLEAN | HTTP response cache |
| `cache_ttl` | INTEGER | Cache TTL (hours) |
| `user_agent` | VARCHAR | User-Agent header |
| `extract` | LIST(VARCHAR) | Extraction specs |

### sitemap()

| Param | Type | Description |
|-------|------|-------------|
| `timeout` | INTEGER | HTTP timeout **in seconds** |
| `recursive` | BOOLEAN | Follow sitemap indexes |
| `max_depth` | INTEGER | Max index recursion |
| `discover` | BOOLEAN | Discover sitemap from robots.txt |
| `filter` | VARCHAR | URL filter |
| `user_agent` | VARCHAR | User-Agent header |

## Extracting Structured Data

### JSON-LD (Schema.org)

```sql
-- Get Product schema from e-commerce pages
SELECT
    url,
    html.schema['Product']->>'name' as product_name,
    html.schema['Product']->'offers'->>'price' as price
FROM pages
WHERE html.schema['Product'] IS NOT NULL;
```

### OpenGraph Meta Tags

```sql
-- Extract social sharing metadata
SELECT
    url,
    html.opengraph->>'og:title' as title,
    html.opengraph->>'og:description' as description,
    html.opengraph->>'og:image' as image
FROM pages
WHERE html.opengraph IS NOT NULL;
```

### JavaScript Variables

`html.js` extracts top-level JS variable assignments:

```sql
-- Extract JS variables from pages
SELECT
    url,
    html.js->>'__INITIAL_STATE__' as initial_state,
    html.js->>'productData' as product_data
FROM pages
WHERE html.js IS NOT NULL;
```

Supported patterns:
- `var name = {...}` / `let name = {...}` / `const name = {...}`
- `window.name = {...}`
- `JSON.parse('[...]')` with hex (`\x22`) and unicode (`\uNNNN`) escapes

### Hydration Data (React/Next.js)

```sql
-- Extract Next.js page props
SELECT
    url,
    html.hydration['__NEXT_DATA__']->'props' as page_props
FROM pages
WHERE html.hydration['__NEXT_DATA__'] IS NOT NULL;
```

## Working with JSON Arrays

### Unnest JSON arrays

```sql
-- Extract items from a JSON array in html.js
SELECT
    p.url,
    item->>'title' as title,
    item->>'price' as price
FROM pages p,
LATERAL unnest(
    CASE
        WHEN html.js->'products' IS NOT NULL
        THEN from_json(html.js->>'products', '["JSON"]')
        ELSE []
    END
) as t(item)
WHERE html.js IS NOT NULL;
```

### Parse JSON array directly

```sql
-- If html.js contains an array like: {"items": [{"a":1},{"a":2}]}
WITH parsed AS (
    SELECT
        url,
        json_extract(html.js, '$.items') as items_json
    FROM pages
    WHERE html.js IS NOT NULL
)
SELECT
    url,
    unnest(from_json(items_json::VARCHAR, '["JSON"]'))->>'a' as a_value
FROM parsed
WHERE items_json IS NOT NULL;
```

## Filtering and Analysis

### Find pages with errors

```sql
SELECT url, status, error
FROM pages
WHERE status >= 400 OR error IS NOT NULL
ORDER BY status DESC;
```

### Analyze content types

```sql
SELECT content_type, COUNT(*) as count
FROM pages
GROUP BY content_type
ORDER BY count DESC;
```

### Find slow pages

```sql
SELECT url, response_time_ms
FROM pages
WHERE response_time_ms > 5000
ORDER BY response_time_ms DESC;
```

## Incremental Crawling

### Only crawl new/changed pages

```sql
-- Re-crawl with cache disabled (or a short cache_ttl)
INSERT INTO pages
SELECT * FROM crawl(
    'https://example.com/',
    user_agent := 'MyBot/1.0',
    timeout := 30,
    cache := false
);
```

### Resume interrupted crawl

```sql
-- Persist progress in state_table; re-run with the same name
SELECT * FROM crawl(
    'https://example.com/',
    user_agent := 'MyBot/1.0',
    timeout := 30,
    max_results := 10000,
    state_table := 'crawl_state'
);
```

## Multiple Sites

### Crawl multiple domains

```sql
CREATE TABLE multi_site_pages AS
SELECT * FROM crawl(
    ['https://site1.com/', 'https://site2.com/', 'https://site3.com/'],
    user_agent := 'MyBot/1.0',
    timeout := 30,
    max_results := 100
);
```

### Crawl from a table of URLs

```sql
CREATE TABLE urls_to_crawl AS
SELECT unnest(['https://example1.com/page1', 'https://example2.com/page2']) AS url;

CREATE TABLE crawled_pages AS
SELECT c.*
FROM urls_to_crawl u, LATERAL crawl_url(u.url, timeout := 30, user_agent := 'MyBot/1.0') c;
```
