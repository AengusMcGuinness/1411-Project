#ifndef STREAM_BUFFER_HPP
#define STREAM_BUFFER_HPP

// This header defines the shared adaptive stream-buffer model that both the
// standalone simulator and the Intel Pin tool reuse.

#include <cstddef>  // std::size_t for container capacities and slot counts.
#include <cstdint>  // Fixed-width integer types for addresses and counters.
#include <memory>   // std::unique_ptr for owning the cache and buffer helpers.
#include <string>   // std::string for summaries and option parsing.
#include <vector>   // std::vector for stream tables and histograms.

namespace adaptive_stream {

// AccessKind separates reads from writes so the model can treat them
// differently when updating streams and invalidating prefetched lines.
enum class AccessKind {
    Read,  // A demand load that may extend a stream or trigger prefetch use.
    Write  // A store that may invalidate prefetched data for the same line.
};

// PrefetchPolicy controls how aggressive the model should be.
enum class PrefetchPolicy {
    Off,       // Disable all prefetch behavior and model demand-only access.
    NextLine,  // Always fetch the next line after each read miss.
    Adaptive   // Use learned stream-length history to choose aggressiveness.
};

// StreamBufferConfig collects all of the tunable parameters for the model in
// one place so the CLI and Pintool can share the same knobs.
struct StreamBufferConfig {
    std::uint64_t line_size_bytes = 64;        // Cache-line granularity used to bucket addresses.
    std::size_t demand_cache_lines = 4096;     // Capacity of the demand cache model.
    std::size_t prefetch_buffer_lines = 16;    // Capacity of the prefetch buffer model.
    std::size_t stream_slots = 8;              // Number of active streams the tracker can remember.
    std::size_t max_stream_length = 16;        // Largest stream length tracked in the histogram.
    std::uint64_t epoch_reads = 2000;          // Number of read misses per histogram epoch.
    std::uint64_t stream_lifetime_refs = 256;   // Lifetime of a stream slot in logical reference steps.
    std::uint64_t prefetch_latency_refs = 8;    // Delay before a prefetched line becomes ready.
    std::uint64_t miss_latency_refs = 80;       // Cost of a demand miss that goes to memory.
    std::uint64_t hit_latency_refs = 1;         // Cost of a cache or prefetch hit.
    std::uint64_t write_latency_refs = 1;       // Cost of a write that hits in the demand cache.
    std::uint64_t base_ref_cost = 1;            // Per-reference bookkeeping cost in the model.
    std::size_t max_prefetch_depth = 8;         // Maximum number of lines prefetched ahead.
    bool bootstrap_next_line = true;            // Seed the first epoch with a conservative next-line bias.
    PrefetchPolicy policy = PrefetchPolicy::Adaptive;  // Default to the adaptive policy.
};

// StreamBufferStats stores the counters and derived metrics that describe how
// the model behaved over a trace or benchmark run.
struct StreamBufferStats {
    std::uint64_t total_refs = 0;                // All memory references seen by the model.
    std::uint64_t reads = 0;                     // Number of read references.
    std::uint64_t writes = 0;                    // Number of write references.

    std::uint64_t read_hits = 0;                 // Reads satisfied by the demand cache.
    std::uint64_t read_misses = 0;               // Reads that missed the demand cache.
    std::uint64_t write_hits = 0;                // Writes that hit in the demand cache.
    std::uint64_t write_misses = 0;              // Writes that missed the demand cache.

    std::uint64_t prefetches_issued = 0;         // Prefetch requests successfully inserted.
    std::uint64_t prefetch_duplicate_suppressed = 0;  // Prefetches blocked because the line was already present.
    std::uint64_t prefetch_ready_hits = 0;       // Prefetches that were ready when the read arrived.
    std::uint64_t prefetch_late_hits = 0;        // Prefetches that existed but were not yet ready.
    std::uint64_t prefetch_useful = 0;           // Prefetches that were eventually consumed by a read.
    std::uint64_t prefetch_evictions = 0;        // Prefetch buffer lines evicted before being consumed.
    std::uint64_t prefetch_write_invalidations = 0;  // Prefetched lines invalidated by writes.

    std::uint64_t stream_starts = 0;             // New stream slots allocated.
    std::uint64_t stream_extensions = 0;         // Existing streams extended by one line.
    std::uint64_t stream_expirations = 0;        // Streams evicted when their lifetime expired.
    std::uint64_t stream_epoch_flushes = 0;      // Streams closed during epoch rollover.
    std::uint64_t stream_dropped = 0;            // Misses that could not be tracked because all slots were full.
    std::uint64_t epochs_completed = 0;          // Number of completed histogram epochs.

    std::uint64_t modeled_cycles = 0;            // Aggregate cost accumulated by the latency model.

    // Compute the fraction of issued prefetches that were useful.
    double prefetch_accuracy() const;
    // Compute the fraction of read misses that were covered by useful prefetches.
    double prefetch_coverage() const;
    // Compute the average modeled latency per reference.
    double average_access_latency() const;
    // Merge another stats object into this one, used by the Pintool when
    // accumulating per-thread results.
    void merge(const StreamBufferStats &other);
};

// StreamBufferSimulator owns the actual stream-tracking logic, the demand
// cache model, and the prefetch buffer model.
class StreamBufferSimulator {
public:
    explicit StreamBufferSimulator(const StreamBufferConfig &config);
    ~StreamBufferSimulator();

    // Feed one access into the model.
    void access(AccessKind kind, std::uint64_t address);
    // Flush any remaining state at end of trace or thread.
    void flush();

    // Return the current statistics snapshot.
    const StreamBufferStats &stats() const;
    // Return the active configuration.
    const StreamBufferConfig &config() const;
    // Return the current learned histogram.
    std::vector<std::uint64_t> histogram() const;
    // Format a human-readable summary for reports and debugging.
    std::string summary(const std::string &label) const;

private:
    // StreamSlot keeps state for one active stream being tracked by the model.
    struct StreamSlot {
        bool valid = false;              // Whether the slot currently holds a live stream.
        std::uint64_t last_line = 0;     // Most recent line observed in the stream.
        int direction = 0;               // -1 for descending, 0 for unknown, +1 for ascending.
        std::uint64_t length = 0;        // Number of lines observed in the stream so far.
        std::uint64_t remaining_life = 0;  // Logical lifetime countdown before eviction.
        std::uint64_t last_touch = 0;    // Logical time of the most recent update.
    };

    // DemandCache and PrefetchBuffer are defined in the implementation file so
    // the header stays lightweight.
    struct DemandCache;
    struct PrefetchBuffer;

    // Convert a byte address to a cache-line number.
    std::uint64_t address_to_line(std::uint64_t address) const;
    // Helper for stream direction tracking; currently retained for extension
    // points where directional prefetching may need the next candidate line.
    std::uint64_t current_stream_line(std::uint64_t line, const StreamSlot &slot) const;

    // Advance logical time and expire old state.
    void tick();
    // Roll the histogram epoch forward and move next-epoch counts into place.
    void rollover_epoch();
    // Evict a single stream slot because its lifetime expired.
    void expire_slot(std::size_t index);
    // Commit one finished stream length into the next-epoch histogram.
    void commit_length_to_next_hist(std::uint64_t length);
    // Decide how many prefetches to issue and enqueue them into the buffer.
    void maybe_generate_prefetches(std::uint64_t line, const StreamSlot *slot, std::uint64_t now);
    // Find an active slot that matches the current line and direction.
    std::size_t find_matching_slot(std::uint64_t line) const;
    // Find an unused stream slot.
    std::size_t find_free_slot() const;
    // Use the learned histogram to decide prefetch depth.
    std::uint32_t choose_prefetch_depth(std::uint32_t current_length) const;
    // Finalize a stream and update the next-epoch histogram.
    void finish_stream(std::size_t index, bool epoch_flush);
    // Record a singleton stream when we cannot keep tracking it.
    void record_singleton_stream();

    StreamBufferConfig config_;                   // Tunable settings for the model.
    StreamBufferStats stats_;                     // Live counters and metrics.
    std::unique_ptr<DemandCache> demand_cache_;   // Demand-cache backing store.
    std::unique_ptr<PrefetchBuffer> prefetch_buffer_;  // Prefetch-buffer backing store.
    std::vector<StreamSlot> slots_;               // Active stream tracker entries.
    std::vector<std::uint64_t> lht_curr_;         // Current epoch likelihood table.
    std::vector<std::uint64_t> lht_next_;         // Next epoch likelihood table.

    std::uint64_t logical_time_ = 0;              // Global logical time in access steps.
    std::uint64_t read_count_in_epoch_ = 0;       // Read-miss counter for epoch rollover.
    bool history_ready_ = false;                  // True once at least one learning epoch is available.
};

// StreamBufferBenchmark runs two simulators side-by-side: the selected policy
// and a baseline no-prefetch policy.
class StreamBufferBenchmark {
public:
    explicit StreamBufferBenchmark(const StreamBufferConfig &selected_config);

    // Send the same access into both the selected model and the baseline.
    void access(AccessKind kind, std::uint64_t address);
    // Flush both models so final statistics are stable.
    void flush();

    // Access the selected-policy stats.
    const StreamBufferStats &selected_stats() const;
    // Access the baseline stats.
    const StreamBufferStats &baseline_stats() const;
    // Format a combined summary for reporting.
    std::string summary(const std::string &label) const;

private:
    StreamBufferSimulator selected_;  // The policy under test.
    StreamBufferSimulator baseline_;  // The no-prefetch comparator.
};

// Parse a user-visible policy string into an enum value.
PrefetchPolicy parse_policy(const std::string &text);
// Convert a policy enum back into a printable string.
std::string to_string(PrefetchPolicy policy);

} // namespace adaptive_stream

#endif // STREAM_BUFFER_HPP
