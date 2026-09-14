PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=crawler
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# Tests query page_info() JSON output with json extension functions
DEFAULT_TEST_EXTENSION_DEPS=json

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile
