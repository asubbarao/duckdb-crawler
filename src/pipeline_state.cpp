#include "pipeline_state.hpp"

#include <mutex>
#include <unordered_map>

namespace duckdb {

//===--------------------------------------------------------------------===//
// Shared Pipeline State - enables LIMIT pushdown across LATERAL calls
//===--------------------------------------------------------------------===//

// Global registry of pipeline states, keyed by database instance pointer
static std::mutex g_pipeline_mutex;
static std::unordered_map<uintptr_t, std::shared_ptr<PipelineState>> g_pipeline_states;

// Initialize pipeline limit for a database instance (call before running query)
void InitPipelineLimit(DatabaseInstance &db, int64_t limit) {
	uintptr_t key = reinterpret_cast<uintptr_t>(&db);
	std::lock_guard<std::mutex> lock(g_pipeline_mutex);

	auto state = std::make_shared<PipelineState>(limit);
	g_pipeline_states[key] = state;
}

// Get existing pipeline state for a database instance
std::shared_ptr<PipelineState> GetPipelineState(DatabaseInstance &db) {
	uintptr_t key = reinterpret_cast<uintptr_t>(&db);
	std::lock_guard<std::mutex> lock(g_pipeline_mutex);

	auto it = g_pipeline_states.find(key);
	if (it != g_pipeline_states.end()) {
		return it->second;
	}
	return nullptr;
}

// Clear pipeline state for a database instance
void ClearPipelineState(DatabaseInstance &db) {
	uintptr_t key = reinterpret_cast<uintptr_t>(&db);
	std::lock_guard<std::mutex> lock(g_pipeline_mutex);
	g_pipeline_states.erase(key);
}

} // namespace duckdb
