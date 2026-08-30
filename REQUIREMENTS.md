# DuckDB Crawler Extension - Requirements

## Rate Limiting

### Crawl-Delay Enforcement
- **MUST** respect `Crawl-delay` directive from robots.txt
- **MUST NOT** allow multiple threads to bypass crawl-delay for same domain
- Implementation: Update `last_crawl_time` atomically when reserving a slot, before fetch starts
- This ensures only one thread per domain can proceed within the crawl-delay window

### 429 Rate Limit Handling
- When ANY thread receives HTTP 429 from a domain:
  - **MUST** block ALL threads from making requests to that domain
  - **MUST** respect `Retry-After` header if present
  - **MUST** use Fibonacci backoff if no Retry-After header
  - Block duration increases with consecutive 429s
- On successful request to previously-blocked domain:
  - **MUST** immediately clear the block (reset `blocked_until`)
  - **MUST** reset consecutive error counter
  - Other threads can resume immediately

### Adaptive Rate Limiting
- Track response times per domain
- Gradually increase delay if responses slow down
- Never go below robots.txt specified delay or user-configured minimum

## robots.txt Compliance

- **MUST** fetch and parse robots.txt before crawling any domain
- **MUST** respect `Disallow` directives for configured user-agent
- **MUST** check `noindex` meta tag in HTML responses
- **SHOULD** cache robots.txt to avoid re-fetching

## Multi-Threading

- Default thread count: DuckDB's `threads` setting (via `current_setting('threads')`)
- Capped at 32 threads maximum, minimum 1
- Configurable via `crawl(..., workers := n)` (not a `CRAWL … WITH` clause on community)
- Per-domain rate limiting preserved across all threads
- Global connection limit via `max_total_connections`
- Per-domain parallelism limit via `max_parallel_per_domain`

## Content Handling

### Response Size
- Default max: 10MB (`max_response_bytes`)
- Responses exceeding limit: marked as error, body discarded

### Content-Type Filtering
- `accept_content_types`: whitelist (supports wildcards like `text/*`)
- `reject_content_types`: blacklist (checked after accept)
- Rejected responses: marked as error, body discarded

### Compression
- Request gzip/deflate by default (`compress = true`)
- Auto-detect and decompress gzipped sitemaps

## URL Discovery

### Sitemap-Based
- Parse robots.txt for `Sitemap:` directives
- Fallback to common sitemap paths (`/sitemap.xml`, `/sitemap_index.xml`)
- Handle sitemap indexes recursively
- Cache discovered URLs with metadata (lastmod, changefreq)

### Link-Following (Optional)
- BFS crawl from start URL when `follow` is a CSS selector
- Respect `max_depth` and `max_results`
- Honor `rel="nofollow"` when `respect_nofollow = true`
- Follow canonical URLs when `follow_canonical = true`

### Direct URL Input
- When given full URL (e.g., `https://example.com/page`):
  - Still check robots.txt for that domain
  - If no sitemap found, crawl the URL directly
  - Don't cache "not_found" status for direct URLs

## Error Handling

### Retryable Errors
- HTTP 429 (Too Many Requests)
- HTTP 5XX (Server Errors)
- Network timeouts/failures (status_code <= 0)

### Retry Policy
- Max 5 retries per URL
- Fibonacci backoff: 1, 1, 2, 3, 5, 8, 13... seconds
- Capped at `max_retry_backoff_seconds` (default: 600s / 10min)

### Non-Retryable
- HTTP 4XX (except 429): permanent failure
- Content-type rejection: skip

## Database Operations

### Target Table
- Auto-created if not exists
- Schema includes: url, surt_key, http_status, body, content_type, crawl_time, error, etag, last_modified, content_hash, final_url, redirect_count
- Updates via `update_stale = true` based on sitemap lastmod/changefreq

### Batch Processing
- Results batched (default 100 rows) before INSERT
- Per-thread local batching (20 rows) with periodic flush
- Mutex-protected database writes (DuckDB single-writer)

## HTTP Features

- HTTP/2 support (when available)
- Redirect tracking (`final_url`, `redirect_count`)
- ETag and Last-Modified header capture
- Server Date header parsing for accurate timestamps

## DuckDB Settings Integration

Crawler reads these settings from DuckDB configuration at crawl start:

| Setting | Description | Default |
|---------|-------------|---------|
| `crawler_user_agent` | User-Agent header | `DuckDB-Crawler/1.0` |
| `crawler_default_delay` | Default crawl delay **in seconds** | 1.0 |
| `crawler_timeout_ms` | Default HTTP timeout **in milliseconds** | 30000 |
| `crawler_respect_robots` | Honor robots.txt | true |
| `crawler_max_response_bytes` | Max response body size | 10485760 |
| `http_proxy` | HTTP proxy host | empty |
| `http_proxy_username` | Proxy authentication username | empty |
| `http_proxy_password` | Proxy authentication password | empty |

Per-call override: TVF named param `timeout` is **seconds** (`timeout := 30` → 30000 ms). Do not pass `crawler_timeout_ms` as a named argument.

`CRAWL (SELECT …) INTO` parser-errors on stock community. Use table functions:

```sql
SET crawler_timeout_ms = 60000;  -- milliseconds, session default
SET http_proxy = 'http://proxy.example.com:8080';
SELECT * FROM crawl('https://example.com/', timeout := 60);  -- seconds, this call
```

## Named parameters (community `LOAD crawler`)

### crawl()

`timeout`, `max_results`, `max_depth`, `workers`, `delay`, `respect_robots`, `cache`, `cache_ttl`, `user_agent`, `extract`, `follow`, `batch_size`, `state_table`

### crawl_url()

`timeout`, `max_results`, `cache`, `cache_ttl`, `user_agent`, `extract`

### sitemap()

`timeout`, `recursive`, `max_depth`, `discover`, `filter`, `user_agent`
