# DuckDB Crawler Extension - Developer Guide

**See also:** [REQUIREMENTS.md](REQUIREMENTS.md) for behavioral requirements (rate limiting, 429 handling, robots.txt compliance, etc.)

## Code Organization Guidelines

### File Size Limits
- **Max ~500 lines per file** - if approaching this, plan to split
- **Max ~100 lines per function** - extract helpers if longer
- Files over 1000 lines MUST be refactored before adding more code

### When to Refactor
Before adding new features to a large file, split it first:
1. Identify cohesive groups (e.g., thread utils, HTTP handling, parsing)
2. Extract to new `.cpp/.hpp` files
3. Update `CMakeLists.txt` to include new sources
4. Then add the new feature

### Current Structure
```
src/
├── crawler_extension.cpp    # Entry point, registration only
├── crawl_table_function.cpp # crawl() in-out function (bare + LATERAL)
├── crawl_parser.cpp         # CRAWLING MERGE INTO parser extension
├── stream_merge_function.cpp# stream_merge_internal() for CRAWLING MERGE
├── css_extract_function.cpp # htmlpath()/jq()/page_info() scalar functions
├── sitemap_function.cpp     # sitemap() table function
├── importhtml_function.cpp  # read_html() table function
├── crawler_utils.cpp        # Shared helpers (DecompressGzip, quoting, ...)
├── pipeline_state.cpp       # Shared LIMIT-pushdown state across LATERAL
├── rust_ffi.cpp             # FFI into rust_parser (HTTP, parsing, robots)
└── include/                 # Headers
```
HTTP, HTML parsing, extraction, robots.txt, and sitemaps are all implemented
in `rust_parser/` and reached through `rust_ffi.cpp`.

## Build Commands

```bash
# First time setup
git clone https://github.com/microsoft/vcpkg.git
./vcpkg/bootstrap-vcpkg.sh

# Build with ninja (faster)
make release GEN=ninja VCPKG_TOOLCHAIN_PATH=$(pwd)/vcpkg/scripts/buildsystems/vcpkg.cmake

# Clean build
rm -rf build && make release GEN=ninja VCPKG_TOOLCHAIN_PATH=$(pwd)/vcpkg/scripts/buildsystems/vcpkg.cmake

# Run tests
./build/release/test/unittest --test-dir test/sql '*crawl*'

# Test manually
./build/release/duckdb -unsigned -c "
LOAD 'build/release/extension/crawler/crawler.duckdb_extension';
CRAWL (SELECT 'https://example.com/') INTO pages WITH (max_crawl_pages 5);
SELECT * FROM pages;
"
```

## Adding vcpkg Packages

Edit `vcpkg.json`:

```json
{
    "dependencies": [
        "zlib",
        {
            "name": "libxml2",
            "default-features": false,
            "features": ["iconv"]
        },
        "new-package-name"
    ]
}
```

Platform-specific deps:
```json
{
    "name": "some-lib",
    "platform": "!windows"
}
```

Then update `CMakeLists.txt`:
```cmake
find_package(NewPackage REQUIRED)
target_link_libraries(${EXTENSION_NAME} NewPackage::lib)
target_link_libraries(${LOADABLE_EXTENSION_NAME} NewPackage::lib)
```

## Adding Custom Keywords (Parser Extension)

### 1. Register Parser Extension

In `src/crawler_extension.cpp`:
```cpp
static void LoadInternal(ExtensionLoader &loader) {
    auto &config = DBConfig::GetConfig(loader.GetDatabaseInstance());

    ParserExtension parser_ext;
    parser_ext.parse_function = MyParserExtension::Parse;
    parser_ext.plan_function = MyParserExtension::Plan;
    config.parser_extensions.push_back(std::move(parser_ext));
}
```

### 2. Implement Parser

In `src/crawl_parser.cpp`:

```cpp
// Check if statement starts with your keyword
ParserExtensionParseResult MyParserExtension::Parse(ParserExtensionInfo *info, const string &query) {
    string lower = StringUtil::Lower(query);

    // Return empty result if not our statement
    if (!StringUtil::StartsWith(lower, "mykeyword")) {
        return ParserExtensionParseResult();
    }

    // Parse the statement
    auto data = make_uniq<MyParseData>();

    // Find keywords: INTO, WHERE, WITH
    size_t into_pos = lower.find("into");
    size_t where_pos = lower.find("where");
    size_t with_pos = lower.find("with");

    // Extract table name after INTO
    if (into_pos != string::npos) {
        // Parse table name...
        data->table_name = extracted_name;
    }

    // Parse WITH options: WITH (key1 value1, key2 'value2')
    if (with_pos != string::npos) {
        ParseWithOptions(options_str, *data);
    }

    return ParserExtensionParseResult(make_uniq_base<ParserExtensionParseData, MyParseData>(std::move(data)));
}
```

### 3. Implement Planner

Convert parsed data to executable plan:

```cpp
ParserExtensionPlanResult MyParserExtension::Plan(ParserExtensionInfo *info,
                                                   ClientContext &context,
                                                   unique_ptr<ParserExtensionParseData> parse_data) {
    auto &data = dynamic_cast<MyParseData &>(*parse_data);

    // Build SQL to execute
    string sql = StringUtil::Format(
        "INSERT INTO %s SELECT * FROM my_table_function('%s')",
        data.table_name, data.some_param);

    // Parse and return the generated SQL
    Parser parser;
    parser.ParseQuery(sql);

    ParserExtensionPlanResult result;
    result.function = make_uniq<PlanExtensionFunction>();
    result.statements = std::move(parser.statements);
    return result;
}
```

## Predicate Pushdown Patterns

### URL Pattern Filtering (LIKE)

```cpp
// In crawl_table_function.cpp
static bool MatchesLikePattern(const std::string &url, const std::string &pattern) {
    // SQL LIKE: % = any chars, _ = single char
    size_t url_pos = 0, pat_pos = 0;
    size_t star_pos = std::string::npos;
    size_t match_pos = 0;

    while (url_pos < url.size()) {
        if (pattern[pat_pos] == url[url_pos] || pattern[pat_pos] == '_') {
            url_pos++; pat_pos++;
        } else if (pattern[pat_pos] == '%') {
            star_pos = pat_pos;
            match_pos = url_pos;
            pat_pos++;
        } else if (star_pos != std::string::npos) {
            pat_pos = star_pos + 1;
            url_pos = ++match_pos;
        } else {
            return false;
        }
    }
    while (pattern[pat_pos] == '%') pat_pos++;
    return pat_pos == pattern.size();
}

// Apply filter early in processing
if (!url_filter.empty() && !MatchesLikePattern(url, url_filter)) {
    continue;  // Skip this URL
}
```

### Content-Type Filtering

```cpp
static bool ContentTypeMatches(const std::string &content_type, const std::string &pattern) {
    // Handle wildcards: text/* matches text/html
    if (pattern.back() == '*') {
        string prefix = pattern.substr(0, pattern.size() - 1);
        return content_type.find(prefix) == 0;
    }
    return content_type.find(pattern) != string::npos;
}

static bool IsContentTypeAcceptable(const std::string &content_type,
                                    const std::string &accept_types,
                                    const std::string &reject_types) {
    // Check accept list
    if (!accept_types.empty()) {
        // Parse comma-separated patterns, return false if none match
    }
    // Check reject list
    if (!reject_types.empty()) {
        // Parse comma-separated patterns, return false if any match
    }
    return true;
}
```

### Size Limit Filtering

```cpp
if (response.body.size() > max_response_bytes) {
    response.success = false;
    response.error = "Response too large";
    response.body.clear();  // Free memory immediately
}
```

## Key Files

| File | Purpose |
|------|---------|
| `src/crawler_extension.cpp` | Extension entry, registers parser & functions |
| `src/crawl_table_function.cpp` | crawl() in-out function (bare + LATERAL, link following, cache, state table) |
| `src/crawl_parser.cpp` | CRAWLING MERGE INTO syntax parsing |
| `src/stream_merge_function.cpp` | Merge execution for CRAWLING MERGE |
| `src/css_extract_function.cpp` | htmlpath()/jq()/page_info() scalar functions |
| `src/sitemap_function.cpp` | sitemap() table function |
| `src/importhtml_function.cpp` | read_html() table function |
| `src/crawler_utils.cpp` | Shared helpers |
| `src/pipeline_state.cpp` | LIMIT-pushdown state shared across LATERAL calls |
| `src/rust_ffi.cpp` | FFI into rust_parser (HTTP, parsing, robots, sitemaps) |
| `rust_parser/` | Rust implementation: reqwest HTTP, extraction, robots.txt |
| `CMakeLists.txt` | Build config, link libraries |
| `vcpkg.json` | C++ dependencies |
| `extension_config.cmake` | DuckDB extension loader config |

## Compile-Time Feature Detection

In `CMakeLists.txt`:
```cmake
find_package(SomeLib CONFIG QUIET)
if(SomeLib_FOUND)
    set(MY_FEATURE_SUPPORT ON)
    message(STATUS "Feature: ENABLED")
else()
    set(MY_FEATURE_SUPPORT OFF)
    message(STATUS "Feature: DISABLED")
endif()

if(MY_FEATURE_SUPPORT)
    target_compile_definitions(${EXTENSION_NAME} PRIVATE MY_FEATURE_SUPPORT=1)
endif()
```

In C++ code:
```cpp
#if defined(MY_FEATURE_SUPPORT) && MY_FEATURE_SUPPORT
// Feature-specific code
#else
// Fallback code
#endif
```

## Testing

Add test in `test/sql/crawl_into.test`:
```sql
# name: test/sql/crawl_into.test
# description: Test CRAWL INTO functionality
# group: [crawler]

require crawler

statement ok
CRAWL (SELECT 'https://example.com/') INTO test_pages WITH (max_crawl_pages 1);

query I
SELECT count(*) > 0 FROM test_pages;
----
true
```

Run specific test:
```bash
./build/release/test/unittest --test-dir test/sql 'test/sql/crawl_into.test'
```
