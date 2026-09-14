# DuckDB Crawler - TODO

## Decisions Made

1. **htmlpath() naming**: Keep `htmlpath()`, use `jq()` as primary alias for simple CSS selections
2. **MERGE unseen rows**: Keep unseen rows by default. Add `WHEN NOT MATCHED BY SOURCE` clause (SQL standard) between `WHEN MATCHED` and `LIMIT` for handling rows in target but not in source
3. **SET crawler_option**: Implement `SET crawler_*` settings for global configuration
4. **DuckDB http settings**: Read proxy and timeout from DuckDB's http_* settings
5. **CREATE SECRET**: Integrate with DuckDB secrets for bearer tokens and extra headers
6. **Per-domain overrides**: Not implementing (use WITH clause options instead)

## Community Extensions PR Learnings

### Build Failures (PR #1101)
- **Root cause**: CMakeLists.txt listed non-existent files (`crawler_worker.cpp`, `crawler_batch.cpp`)
- **Fix**: Update description.yml ref to commit with fixed CMakeLists.txt
- **musl builds**: linux_amd64_musl requires all source files to exist

### Yardstick Extension Pattern (recommended for Rust+C++)
Reference: https://github.com/sidequery/yardstick

1. **Use Corrosion for Rust builds** (not pre-built .a files)
   ```cmake
   FetchContent_Declare(Corrosion GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git)
   corrosion_import_crate(MANIFEST_PATH "${CMAKE_CURRENT_SOURCE_DIR}/rust/Cargo.toml")
   ```

2. **Platform-specific Rust target detection**
   - Linux: detect musl vs gnu, arm64 vs x86_64
   - macOS: detect arm64 vs x86_64
   - Windows: detect MSVC vs MinGW, arch

3. **Two library targets**
   - `yardstick-static` for static extension
   - `yardstick` (dynamic) for loadable extension

4. **Platform-specific linking**
   - macOS: Security, CoreFoundation frameworks
   - Linux: pthread, dl
   - Windows: ws2_32, userenv, bcrypt, ntdll

### Future Improvement
Consider migrating from pre-built Rust static library to Corrosion-based build for better cross-platform CI support.

## Open Questions

(none - all major features implemented)

## In Progress

(none)

## Implemented Features

- [x] WHEN NOT MATCHED BY SOURCE clause in CRAWLING MERGE INTO (UPDATE SET, DELETE, with conditions)
- [x] SET crawler_* settings (user_agent, default_delay, respect_robots, timeout_ms, max_response_bytes)
- [x] DuckDB http_proxy settings integration
- [x] CREATE SECRET integration (bearer_token, extra_http_headers)
- [x] robots.txt parsing with 1-hour cache TTL, crawl-delay, and sitemap extraction
- [x] jq() and htmlpath() extraction functions with CSS selectors and JSON path
- [x] Example SQL for job listings, products, blog posts, and events (see examples/)

- [x] F2: Connection pooling (libcurl handle pool)
- [x] F3: Batch inserts
- [x] F5: Parallel sitemap discovery
- [x] G6: Progress reporting
- [x] G7: Error classification
- [x] C1: Compression (Accept-Encoding)
- [x] C2: Response size limits
- [x] C3: Content-Type filtering
- [x] N3: Request-rate support
- [x] N8: Global connection limit
- [x] ETag/Last-Modified headers
- [x] Content hash deduplication
- [x] SURT keys for URL normalization
- [x] Adaptive rate limiting
- [x] Priority queue scheduling
- [x] Gzip sitemap decompression
- [x] HTTP/2 support (libcurl + nghttp2)
- [x] G5: Redirect tracking (final_url, redirect_count columns)
- [x] N5: Meta robots tag support (noindex clears body, nofollow skips link extraction)
- [x] Large HTTP headers support (libcurl has no header size limit)
- [x] html.readability extraction (title, content, text_content, excerpt)
- [x] html.schema as MAP(VARCHAR, JSON) with array support for multiple items
