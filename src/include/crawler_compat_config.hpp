#pragma once

// Identifier was introduced alongside the DuckDB 2.0 parser/catalog API changes.
// Feature detection is used because extension builds do not expose DuckDB's
// internal CMake version variables to extension CMakeLists files.
#if __has_include("duckdb/common/identifier.hpp")
#define CRAWLER_DUCKDB_V2 1
#else
#define CRAWLER_DUCKDB_V2 0
#endif
