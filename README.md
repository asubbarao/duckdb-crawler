# DuckDB Crawler Extension

A high-performance web crawler extension for DuckDB that fetches web pages, extracts structured data from HTML, and stores results directly in database tables.

## Quick Start

```sql
-- Install from DuckDB community extensions
INSTALL crawler FROM community;
LOAD crawler;

-- One URL. Named param `timeout` is seconds (default 30).
-- Distinct from SET crawler_timeout_ms (milliseconds).
SELECT url, status, length(html.document) AS size
FROM crawl('https://example.com/', timeout := 30);
```

Stock community `LOAD crawler` registers table functions (`crawl`, `crawl_url`, `sitemap`, …). It does **not** register a `CRAWL` statement — `CRAWL (SELECT …) INTO …` is a parser error. This source tree’s parser (`src/crawl_parser.cpp`) is **MERGE-only** (`CRAWLING MERGE INTO`), and that registration is currently disabled (`parser_extensions` private in DuckDB 1.2+).

## Features

- **SQL table functions** - `crawl()`, `crawl_url()`, `sitemap()` with named parameters
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
│              Table functions (community LOAD crawler)           │
│     crawl(url | urls, timeout := …)  crawl_url()  sitemap()     │
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

The crawler starts with seed URLs from `crawl()` / `crawl_url()`:

```sql
SELECT * FROM crawl('https://example.com/sitemap.xml', timeout := 30);
SELECT * FROM crawl(['https://example.com/a', 'https://example.com/b']);
SELECT * FROM sitemap('https://example.com/sitemap.xml', discover := true);
```

If `follow` is a CSS selector, the crawler extracts matching links and queues them, respecting `max_depth`.

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

These are what community `LOAD crawler` actually registers. Named parameter `timeout` is **seconds** on every TVF (binder multiplies by 1000). Session default is `SET crawler_timeout_ms` (**milliseconds**, default 30000).

### crawl() — batch crawl

```sql
SELECT url, status, length(html.document) AS size
FROM crawl('https://example.com/', timeout := 30);

SELECT url, status
FROM crawl(['https://example.com/a', 'https://example.com/b'],
           timeout := 15, max_results := 10, respect_robots := true);
```

| Named param | Type | Description |
|-------------|------|-------------|
| `timeout` | INTEGER | HTTP request timeout **in seconds** (not ms) |
| `max_results` | BIGINT | Cap on pages returned (LIMIT pushdown) |
| `max_depth` | INTEGER | Max link-follow depth (`1` = seeds only) |
| `workers` | INTEGER | Concurrent requests |
| `delay` | INTEGER | Per-domain delay stored as milliseconds |
| `respect_robots` | BOOLEAN | Honor robots.txt |
| `cache` | BOOLEAN | HTTP response cache |
| `cache_ttl` | INTEGER | Cache TTL in hours |
| `user_agent` | VARCHAR | User-Agent header |
| `extract` | LIST(VARCHAR) | Extraction specs |
| `follow` | VARCHAR | CSS selector for links to follow |
| `batch_size` | INTEGER | URLs per fetch batch |
| `state_table` | VARCHAR | Persistent crawl-state table |

### crawl_url() — LATERAL join support

Use `crawl_url()` for row-by-row crawling with LATERAL joins:

```sql
-- Crawl URLs from a table
SELECT
    seed.category,
    c.url,
    c.status,
    c.html.readability.title
FROM seed_urls seed,
LATERAL crawl_url(seed.url, timeout := 30) AS c
WHERE c.status = 200;

-- Chain with extraction
SELECT
    c.final_url,
    jq(c.html.document, 'h1').text as title,
    c.html.schema['Product'] as product_data
FROM urls_to_check u,
LATERAL crawl_url(u.link, timeout := 15) AS c;
```

| Named param | Type | Description |
|-------------|------|-------------|
| `timeout` | INTEGER | HTTP request timeout **in seconds** |
| `max_results` | BIGINT | Cap on results (also a 2nd positional arg in LATERAL) |
| `cache` | BOOLEAN | HTTP response cache |
| `cache_ttl` | INTEGER | Cache TTL in hours |
| `user_agent` | VARCHAR | User-Agent header |
| `extract` | LIST(VARCHAR) | Extraction specs |

### sitemap() — sitemap parsing

Parse XML sitemaps (supports gzip, recursive sitemap indexes):

```sql
-- Get all URLs from sitemap
SELECT * FROM sitemap('https://example.com/sitemap.xml', timeout := 30);

-- Recursive sitemap discovery
SELECT url, lastmod, priority
FROM sitemap('https://example.com/sitemap_index.xml',
             recursive := true, timeout := 30);
```

| Named param | Type | Description |
|-------------|------|-------------|
| `timeout` | INTEGER | HTTP request timeout **in seconds** |
| `recursive` | BOOLEAN | Follow sitemap indexes |
| `max_depth` | INTEGER | Max index recursion depth |
| `discover` | BOOLEAN | Discover sitemap URL from robots.txt |
| `filter` | VARCHAR | URL filter |
| `user_agent` | VARCHAR | User-Agent header |

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
FROM pages WHERE status = 200;

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

Parser syntax in this source tree only (`CRAWLING MERGE INTO`, not `CRAWL INTO`). **Not registered** on stock community `LOAD crawler` (parser error at `CRAWLING`). On community, use DuckDB `MERGE` / `INSERT` over `crawl()`.

When the parser is enabled, upsert crawl results with MERGE semantics:

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
    WHERE c.status = 200
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

-- Session default request timeout (milliseconds).
-- Per-call override is crawl(..., timeout := seconds), not this name.
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
| `crawler_timeout_ms` | BIGINT | 30000 | Default request timeout **in milliseconds**. TVF named param `timeout` is **seconds**. |
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

## CRAWL statement (not on community)

`CRAWL (SELECT …) INTO … WITH (…)` is **not** registered. On stock community:

```sql
-- Parser Error: syntax error at or near "CRAWL"
CRAWL (SELECT 'https://example.com/') INTO pages;
```

`src/crawl_parser.cpp` handles **`CRAWLING MERGE INTO` only** (not `CRAWL INTO`). That parser is not loaded today (`parser_extensions` private in DuckDB 1.2+). Persist results with `CREATE TABLE AS` / `INSERT` / DuckDB `MERGE` over `crawl()` / `crawl_url()`.

## Output Schema

`crawl()` / `crawl_url()` return:

| Column | Type | Description |
|--------|------|-------------|
| `url` | VARCHAR | Fetched URL |
| `status` | INTEGER | HTTP status code |
| `content_type` | VARCHAR | Content-Type header |
| `html` | STRUCT | `document`, `js`, `meta`, `opengraph`, `schema`, `readability`, `hydration` |
| `final_url` | VARCHAR | URL after redirects |
| `error` | VARCHAR | Error message if failed |
| `extract` | VARCHAR | Result of `extract` specs |
| `response_time_ms` | BIGINT | Request duration |
| `depth` | INTEGER | Crawl depth from seed |

## Examples

### Basic Crawl

```sql
CREATE TABLE pages AS
SELECT * FROM crawl('https://example.com/', timeout := 30, max_results := 100);

SELECT url, status, html.schema FROM pages WHERE status = 200;
```

### Crawl with Link Following

```sql
SELECT * FROM crawl(
    'https://news.example.com/',
    follow := 'a[href]',
    max_depth := 2,
    max_results := 500,
    timeout := 30
);
```

### URL Filtering

```sql
SELECT s.url
FROM sitemap('https://shop.example.com/sitemap.xml',
             filter := '%/product/%', timeout := 30) s;
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
-- Retry failed URLs (timeout := seconds)
SELECT c.*
FROM my_crawl t, LATERAL crawl_url(t.url, timeout := 60, user_agent := 'MyBot/1.0') c
WHERE t.error = 'network_timeout';
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
