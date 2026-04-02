# DuckDB Crawler Extension

A high-performance web crawler extension for DuckDB that fetches web pages, extracts structured data from HTML, and stores results directly in database tables.

## Quick Start

```sql
-- Install from DuckDB community extensions
INSTALL crawler FROM community;
LOAD crawler;

-- Simple crawl
CRAWL (SELECT 'https://example.com/')
INTO pages
WITH (max_crawl_pages 10);

-- View results
SELECT url, status_code, length(body) as size FROM pages;
```

## Features

- **Native SQL syntax** - `CRAWL` statement integrates seamlessly with DuckDB
- **HTTP/1.1, HTTP/2** support via reqwest (Rust)
- **Parallel crawling** with configurable thread pools
- **robots.txt compliance** with crawl delay respect
- **Sitemap discovery** and parsing (XML, gzip)
- **Structured data extraction**:
  - JSON-LD (with @graph support)
  - Microdata (schema.org HTML attributes)
  - OpenGraph meta tags
  - CSS selectors
  - JavaScript variables (AST-based via tree-sitter)
  - SPA hydration state (Next.js, Nuxt, Vue/Pinia, Apollo)
- **Predicate pushdown** - Filter URLs before fetching
- **Rate limiting** per domain with adaptive backoff
- **Link following** with depth control

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CRAWL Statement                         │
│         CRAWL (SELECT urls) INTO table WHERE ... WITH           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DuckDB Parser Extension                      │
│      Parses CRAWL/INTO/WHERE/WITH into execution plan          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Crawler Thread Pool                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Worker 1 │  │ Worker 2 │  │ Worker 3 │  │ Worker N │       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│       │             │             │             │              │
│       ▼             ▼             ▼             ▼              │
│  ┌─────────────────────────────────────────────────────┐      │
│  │              reqwest (HTTP Client)                   │      │
│  │    HTTP/1.1 · HTTP/2 · TLS · Keep-Alive             │      │
│  │    Connection pooling · Compression · Redirects     │      │
│  └─────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   HTML Parser (Rust FFI)                        │
│  ┌─────────┐ ┌───────────┐ ┌───────┐ ┌───────────┐ ┌───────────┐│
│  │ JSON-LD │ │ Microdata │ │  CSS  │ │ Hydration │ │JS Vars    ││
│  │(scraper)│ │ (scraper) │ │(scpr) │ │(tree-sitr)│ │(tree-sitr)││
│  └─────────┘ └───────────┘ └───────┘ └───────────┘ └───────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        DuckDB Table                             │
│      url | status | body | jsonld | microdata | meta | ...      │
└─────────────────────────────────────────────────────────────────┘
```

## How It Works

### 1. URL Discovery

The crawler starts with seed URLs from the subquery:

```sql
CRAWL (SELECT 'https://example.com/sitemap.xml')  -- Direct URLs
CRAWL (SELECT url FROM my_urls)                    -- From table
CRAWL (SELECT 'example.com')                       -- Auto-discover sitemap
```

If `follow_links` is enabled, it parses HTML for `<a href>` links and adds them to the queue, respecting `max_crawl_depth` and same-domain rules.

### 2. HTTP Fetching (reqwest)

Each URL is fetched using reqwest with:

- **Connection pooling** - Reuses TCP connections for same hosts
- **Keep-alive** - Maintains persistent connections
- **HTTP/2 multiplexing** - Multiple requests over single connection
- **Automatic decompression** - gzip, deflate, brotli
- **Redirect following** - Configurable limit
- **TLS verification** - Certificate validation
- **Timeout handling** - Connect and read timeouts

### 3. HTML Parsing (Rust)

The Rust HTML parser processes each response:

**JSON-LD Extraction:**
- Finds all `<script type="application/ld+json">` tags
- Parses JSON content with error tolerance
- Handles `@graph` arrays (multiple objects)
- Indexes results by `@type` for easy access

**Microdata Extraction:**
- Traverses DOM for `itemscope` attributes
- Builds nested objects from `itemprop` values
- Handles nested itemscopes (e.g., Product > Offer)
- Extracts values from appropriate HTML attributes

**CSS Selector Extraction:**
- Uses `scraper` crate (built on `html5ever`)
- Supports full CSS3 selectors
- Extracts text, attributes, or HTML content

**JavaScript Variable Extraction:**
- Uses `tree-sitter` to build AST of script contents
- Extracts `var`/`let`/`const` declarations
- Captures `window.X = {...}` assignments
- Parses object/array literal values to JSON

### 4. Storage

Results are batch-inserted into the target DuckDB table:

- Table created automatically if not exists
- Efficient batch inserts (configurable batch size)
- Transaction per batch for consistency

## Installation

```sql
-- Install from DuckDB community extensions (recommended)
INSTALL crawler FROM community;
LOAD crawler;
```

### Building from Source

```bash
git clone https://github.com/midwork-finds-jobs/duckdb-crawler
cd duckdb-crawler
./vcpkg/bootstrap-vcpkg.sh
make release VCPKG_TOOLCHAIN_PATH=$(pwd)/vcpkg/scripts/buildsystems/vcpkg.cmake

# Load in DuckDB
duckdb -unsigned -c "LOAD 'build/release/extension/crawler/crawler.duckdb_extension';"
```

## Table Functions

### crawl_url() - LATERAL Join Support

Use `crawl_url()` for row-by-row crawling with LATERAL joins:

```sql
-- Crawl URLs from a table
SELECT
    seed.category,
    c.url,
    c.status_code,
    c.html.readability.title
FROM seed_urls seed,
LATERAL crawl_url(seed.url) AS c
WHERE c.status_code = 200;

-- Chain with extraction
SELECT
    c.final_url,
    jq(c.body, 'h1').text as title,
    c.html.schema['Product'] as product_data
FROM urls_to_check u,
LATERAL crawl_url(u.link) AS c;
```

### sitemap() - Sitemap Parsing

Parse XML sitemaps (supports gzip, recursive sitemap indexes):

```sql
-- Get all URLs from sitemap
SELECT * FROM sitemap('https://example.com/sitemap.xml');

-- Recursive sitemap discovery
SELECT url, lastmod, priority
FROM sitemap('https://example.com/sitemap_index.xml', recursive := true);
```

## Extraction Functions

### jq() - CSS Selector Extraction

Extract data using CSS selectors. Returns a STRUCT with text, html, and attr fields:

```sql
-- Basic usage: returns STRUCT(text, html, attr MAP)
SELECT jq('<div class="price">$19.99</div>', 'div.price').text;
-- Result: '$19.99'

-- Get inner HTML
SELECT jq('<div><span>Hello</span></div>', 'div').html;
-- Result: '<span>Hello</span>'

-- Get attribute
SELECT jq('<a href="/link" title="Click">Text</a>', 'a').attr['href'];
-- Result: '/link'

-- 3-argument form: get specific attribute directly
SELECT jq('<img src="pic.jpg" alt="Photo">', 'img', 'src');
-- Result: 'pic.jpg'
```

### htmlpath() - JSON Path + CSS Extraction

Combine CSS selectors with JSON-like path syntax:

```sql
-- Extract text content (use @text suffix)
SELECT htmlpath('<h1>Title</h1>', 'h1@text');
-- Result: "Title"

-- Extract attribute (use @attr_name suffix)
SELECT htmlpath('<a href="/page">Link</a>', 'a@href');
-- Result: "/page"

-- Extract from JSON-LD
SELECT htmlpath(body, 'script[type="application/ld+json"]@text.Product.name')
FROM pages WHERE status_code = 200;

-- Extract multiple elements (returns JSON array)
SELECT htmlpath(body, 'a.product@href[*]') FROM pages;
```

## HTML Structured Data

Crawl results include pre-extracted structured data:

### html.readability - Article Extraction

Mozilla Readability-style content extraction:

```sql
SELECT
    url,
    html.readability.title,        -- Extracted article title
    html.readability.excerpt,      -- Short summary
    html.readability.text_content, -- Plain text content
    html.readability.content       -- Cleaned HTML content
FROM crawl(['https://example.com/article']);
```

### html.schema - Schema.org Data

JSON-LD and Microdata as MAP(VARCHAR, JSON):

```sql
SELECT
    url,
    html.schema['Product'] as product,        -- Product schema
    html.schema['Organization'] as org,       -- Organization schema
    html.schema['BreadcrumbList'] as breadcrumbs
FROM crawl(['https://example.com/product/123']);

-- Access nested fields
SELECT
    html.schema['Product']->>'name' as name,
    html.schema['Product']->'offers'->>'price' as price
FROM crawl(['https://shop.example.com/item']);
```

### html.hydration - SPA Framework State

Extracts embedded application state from JavaScript SPA frameworks. Returns `MAP(VARCHAR, JSON)` — access by framework key. Supports Next.js, Nuxt, Vue/Pinia, Apollo, and generic `window.X` assignments.

```sql
-- See what hydration data a site exposes
SELECT url, map_keys(html.hydration) as keys
FROM crawl(['https://www.prisma.fi/']);
-- keys: [__NEXT_DATA__]

-- Access Next.js page props directly
SELECT
    html.hydration['__NEXT_DATA__']->'props'->'pageProps'->>'title' as title,
    html.hydration['__NEXT_DATA__']->'props'->'pageProps'->'pageProducts' as products
FROM crawl(['https://www.prisma.fi/']);

-- Access Nuxt/Vue hydration data (e.g., Lidl.fi)
SELECT
    html.hydration['unified_datalayer_product']->>'name' as name,
    html.hydration['unified_datalayer_product']->>'price' as price,
    html.hydration['unified_datalayer_product']->>'brand' as brand
FROM crawl(['https://www.lidl.fi/p/milbona-mozzarella/p10032843']);
-- name: Mozzarella, price: 1.99, brand: MILBONA

-- Works with any SPA framework that embeds state in HTML
SELECT url, map_keys(html.hydration) as keys
FROM crawl(['https://www.verkkokauppa.com/']);
-- keys: [state, __CONFIG__, data, translations, ...]
```

Supported extraction patterns:
- `<script id="__NEXT_DATA__" type="application/json">` (Next.js)
- `window.__NUXT__`, `window.__pinia`, `window.__APOLLO_STATE__` (Vue/Nuxt/Apollo)
- `window.dataLayer`, `window.__INITIAL_STATE__` (generic)
- Any `<script type="application/json">` block (keyed by `id` attribute)
- HTML entity decoding for encoded state (`&quot;` → `"`)
- Devalue format deserialization (Pinia/Nuxt reference arrays → nested JSON)

## CRAWLING MERGE INTO

Upsert crawl results with MERGE semantics. Supports conditional updates and handling of stale rows:

```sql
-- Basic upsert: update existing, insert new
CRAWLING MERGE INTO products
USING (
    SELECT * FROM crawl(['https://shop.example.com/products'])
) AS src
ON (src.url = products.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME;

-- Conditional update: only update stale rows (>24 hours old)
CRAWLING MERGE INTO jobs
USING (
    SELECT
        c.final_url as url,
        jq(c.body, 'h1.title').text as title,
        current_timestamp as crawled_at
    FROM crawl(['https://jobs.example.com/listings']) AS listing,
    LATERAL unnest(cast(htmlpath(listing.body, 'a.job@href[*]') as VARCHAR[])) AS t(job_url),
    LATERAL crawl_url(job_url) AS c
    WHERE c.status_code = 200
) AS src
ON (src.url = jobs.url)
WHEN MATCHED AND age(jobs.crawled_at) > INTERVAL '24 hours' THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
LIMIT 100;

-- Handle rows no longer in source (soft delete)
CRAWLING MERGE INTO listings
USING (SELECT * FROM crawl([...]) WHERE status = 200) AS src
ON (src.url = listings.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN UPDATE SET is_deleted = true;

-- Hard delete rows not in source
CRAWLING MERGE INTO listings
USING (...) AS src
ON (src.url = listings.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED BY SOURCE AND is_archived = false THEN DELETE;
```

### MERGE Clauses

| Clause | Description |
|--------|-------------|
| `WHEN MATCHED THEN UPDATE BY NAME` | Update existing rows, match columns by name |
| `WHEN MATCHED THEN DELETE` | Delete matched rows |
| `WHEN MATCHED AND <condition>` | Conditional match (e.g., stale check) |
| `WHEN NOT MATCHED THEN INSERT BY NAME` | Insert new rows |
| `WHEN NOT MATCHED BY SOURCE THEN UPDATE SET ...` | Soft-delete rows no longer in source |
| `WHEN NOT MATCHED BY SOURCE THEN DELETE` | Hard-delete rows no longer in source |
| `WHEN NOT MATCHED BY SOURCE AND <condition>` | Conditional handling of missing rows |

## Global Settings

Configure crawler defaults with `SET` statements:

```sql
-- Set default user agent
SET crawler_user_agent = 'MyBot/1.0 (+https://example.com/bot)';

-- Set default delay between requests (seconds)
SET crawler_default_delay = 1.0;

-- Respect robots.txt (default: true)
SET crawler_respect_robots = true;

-- Request timeout (milliseconds)
SET crawler_timeout_ms = 30000;

-- Maximum response size (bytes)
SET crawler_max_response_bytes = 10485760;  -- 10MB
```

### Available Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `crawler_user_agent` | VARCHAR | required | HTTP User-Agent header |
| `crawler_default_delay` | DOUBLE | 1.0 | Delay between requests (seconds) |
| `crawler_respect_robots` | BOOLEAN | true | Honor robots.txt |
| `crawler_timeout_ms` | INTEGER | 30000 | Request timeout |
| `crawler_max_response_bytes` | INTEGER | 10485760 | Max response size |

## Proxy Support

### Via DuckDB HTTP Settings

```sql
-- Set proxy via DuckDB's built-in settings
SET http_proxy = 'http://proxy.example.com:8080';
SET http_proxy_username = 'user';
SET http_proxy_password = 'pass';
```

### Via CREATE SECRET

```sql
-- Create secret for API authentication
CREATE SECRET my_api (
    TYPE HTTP,
    EXTRA_HTTP_HEADERS MAP {
        'Authorization': 'Bearer sk-xxxx',
        'X-Custom-Header': 'value'
    }
);

-- Crawler automatically uses secrets matching URL patterns
```

## Example SQL Files

See the `examples/` directory for complete working examples:

| File | Description |
|------|-------------|
| `examples/crawl_job_listings.sql` | Job board scraping with schema.org |
| `examples/crawl_products.sql` | E-commerce price monitoring |
| `examples/crawl_blog_posts.sql` | Blog article extraction with readability |
| `examples/crawl_events.sql` | Event page crawling with Event schema |

## CRAWL Statement Syntax

```sql
CRAWL (subquery)
INTO table_name
[WHERE url_filter]
[WITH (options)]
[LIMIT n]
```

### Components

| Clause | Required | Description |
|--------|----------|-------------|
| `CRAWL (subquery)` | Yes | Source URLs - any SELECT returning URL strings |
| `INTO table_name` | Yes | Target table (created if not exists) |
| `WHERE condition` | No | URL filter applied before fetching |
| `WITH (options)` | No | Crawler configuration |
| `LIMIT n` | No | Maximum pages to crawl |

## Output Schema

The output table contains standard columns:

| Column | Type | Description |
|--------|------|-------------|
| `url` | VARCHAR | Fetched URL |
| `surt_key` | VARCHAR | SURT-normalized URL (Common Crawl format) |
| `status_code` | INTEGER | HTTP status code |
| `body` | VARCHAR | Response body |
| `content_type` | VARCHAR | Content-Type header |
| `crawled_at` | TIMESTAMP | Fetch timestamp |
| `elapsed_ms` | BIGINT | Request duration |
| `error` | VARCHAR | Error message if failed |
| `error_type` | VARCHAR | Classified error type |
| `final_url` | VARCHAR | URL after redirects |
| `redirect_count` | INTEGER | Number of redirects |
| `etag` | VARCHAR | ETag header |
| `last_modified` | VARCHAR | Last-Modified header |
| `content_hash` | VARCHAR | SHA-256 of body |
| `jsonld` | JSON | Full JSON-LD data |
| `opengraph` | JSON | Full OpenGraph data |
| `meta` | JSON | Full meta tags |
| `js` | JSON | Full JS variables |

## Examples

### Basic Crawl

```sql
-- Crawl a website
CRAWL (SELECT 'https://example.com/')
INTO pages
WITH (max_crawl_pages 100);

-- Query the results
SELECT url, status_code, jsonld FROM pages WHERE status_code = 200;
```

### Crawl with Link Following

```sql
CRAWL (SELECT 'https://news.example.com/')
INTO articles
WHERE url LIKE '%/article/%'
WITH (follow_links true, max_crawl_depth 2, max_crawl_pages 500);
```

### URL Filtering

```sql
CRAWL (SELECT 'https://shop.example.com/sitemap.xml')
INTO products
WHERE url LIKE '%/product/%'
WITH (max_crawl_pages 1000);
```

## Error Handling

Errors are classified for easy filtering:

| Error Type | Description |
|------------|-------------|
| `network_timeout` | Connection or read timeout |
| `network_dns_failure` | DNS resolution failed |
| `network_connection_refused` | Connection refused |
| `network_ssl_error` | SSL/TLS error |
| `http_client_error` | 4XX status codes |
| `http_server_error` | 5XX status codes |
| `http_rate_limited` | 429 Too Many Requests |
| `robots_disallowed` | Blocked by robots.txt |
| `content_too_large` | Response exceeds limit |
| `content_type_rejected` | Content-Type filtered |

```sql
-- Retry failed URLs
CRAWL (
    SELECT url FROM my_crawl
    WHERE error_type = 'network_timeout'
)
INTO my_crawl_retry
WITH (user_agent 'MyBot/1.0', timeout_seconds 60);
```

## Performance

- **Parallel fetching**: Configurable thread pool
- **Connection reuse**: reqwest connection pooling
- **HTTP/2 multiplexing**: Multiple requests per connection
- **Streaming parsing**: HTML parsed incrementally
- **Batch inserts**: Efficient database writes
- **Predicate pushdown**: URL filters skip unwanted pages

Typical throughput: **50-200 pages/second** depending on:
- Network latency to target sites
- Target server response times
- Crawl delay settings
- Page sizes

## Limitations

- JavaScript rendering not supported (static HTML only)
- Maximum response size: 10MB default (configurable)
- Cookies not persisted across requests
- Single database connection

## Dependencies

Built with:
- **reqwest** - HTTP client (Rust, HTTP/1.1, HTTP/2, TLS)
- **scraper** - HTML parsing (Rust, CSS selectors)
- **yyjson** - JSON parsing (C++)
- **readability** - Article extraction (Rust)

## License

MIT
