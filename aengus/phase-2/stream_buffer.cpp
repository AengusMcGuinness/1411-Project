#include "stream_buffer.hpp"

// The implementation depends on a few STL containers and helpers for
// bookkeeping, formatting, and cache-like storage.
#include <algorithm>   // std::min, std::max, std::fill.
#include <iomanip>     // std::fixed and std::setprecision for summaries.
#include <iterator>    // std::prev for inserting into linked lists.
#include <list>        // std::list for the LRU-style buffer representations.
#include <sstream>     // std::ostringstream for human-readable summaries.
#include <stdexcept>   // std::runtime_error for input validation.
#include <unordered_map>  // O(1)-ish lookup for cache and buffer entries.

namespace adaptive_stream {

namespace {

// Clamp a stream length into the histogram bucket range so long streams are
// folded into the maximum tracked bucket.
static std::uint64_t bucket_length(std::uint64_t length, std::size_t max_stream_length) {
    if (length == 0) {
        return 0;  // Empty streams do not contribute to the histogram.
    }
    return std::min<std::uint64_t>(length, static_cast<std::uint64_t>(max_stream_length));
}

} // namespace

// Return useful-prefetches divided by issued-prefetches, guarding against
// divide-by-zero when the trace never generated a prefetch.
double StreamBufferStats::prefetch_accuracy() const {
    if (prefetches_issued == 0) {
        return 0.0;
    }
    return static_cast<double>(prefetch_useful) / static_cast<double>(prefetches_issued);
}

// Return useful-prefetches divided by read misses, which approximates how much
// demand latency the prefetcher managed to cover.
double StreamBufferStats::prefetch_coverage() const {
    if (read_misses == 0) {
        return 0.0;
    }
    return static_cast<double>(prefetch_useful) / static_cast<double>(read_misses);
}

// Return the average modeled access cost per reference.
double StreamBufferStats::average_access_latency() const {
    if (total_refs == 0) {
        return 0.0;
    }
    return static_cast<double>(modeled_cycles) / static_cast<double>(total_refs);
}

// Merge another stats object into this one so thread-local results can be
// accumulated into a process-wide total.
void StreamBufferStats::merge(const StreamBufferStats &other) {
    total_refs += other.total_refs;
    reads += other.reads;
    writes += other.writes;
    read_hits += other.read_hits;
    read_l2_hits += other.read_l2_hits;
    read_misses += other.read_misses;
    write_hits += other.write_hits;
    write_l2_hits += other.write_l2_hits;
    write_misses += other.write_misses;
    prefetches_issued += other.prefetches_issued;
    prefetch_duplicate_suppressed += other.prefetch_duplicate_suppressed;
    prefetch_ready_hits += other.prefetch_ready_hits;
    prefetch_late_hits += other.prefetch_late_hits;
    prefetch_useful += other.prefetch_useful;
    prefetch_evictions += other.prefetch_evictions;
    prefetch_write_invalidations += other.prefetch_write_invalidations;
    stream_starts += other.stream_starts;
    stream_extensions += other.stream_extensions;
    stream_expirations += other.stream_expirations;
    stream_epoch_flushes += other.stream_epoch_flushes;
    stream_dropped += other.stream_dropped;
    epochs_completed += other.epochs_completed;
    modeled_cycles += other.modeled_cycles;
}

// Convert a policy enum into a concise printable label for logs and summaries.
std::string to_string(PrefetchPolicy policy) {
    switch (policy) {
    case PrefetchPolicy::Off:
        return "off";
    case PrefetchPolicy::NextLine:
        return "nextline";
    case PrefetchPolicy::Adaptive:
        return "adaptive";
    }
    return "adaptive";
}

// Parse a string knob or command-line argument into the corresponding policy
// enum. Unknown strings default to the adaptive policy.
PrefetchPolicy parse_policy(const std::string &text) {
    if (text == "off" || text == "Off" || text == "OFF") {
        return PrefetchPolicy::Off;
    }
    if (text == "nextline" || text == "next-line" || text == "NextLine" || text == "NEXTLINE") {
        return PrefetchPolicy::NextLine;
    }
    return PrefetchPolicy::Adaptive;
}

// SetAssocCache models a set-associative LRU cache, matching the design from
// the homework 4 cache hierarchy.  Each set tracks its ways using an LRU
// counter (0 = MRU, assoc-1 = LRU).  No victim cache is included.
struct StreamBufferSimulator::SetAssocCache {
    struct Entry {
        bool valid = false;
        std::uint64_t tag = 0;
        int lru_status = 0;
    };

    SetAssocCache(std::size_t total_size_bytes, std::size_t block_size_bytes,
                  std::size_t associativity) {
        if (total_size_bytes == 0 || block_size_bytes == 0 || associativity == 0) {
            assoc_ = 1;
            num_sets_ = 0;
            return;
        }
        assoc_ = associativity;
        std::size_t total_lines = total_size_bytes / block_size_bytes;
        num_sets_ = total_lines / assoc_;
        if (num_sets_ == 0) num_sets_ = 1;

        // Compute bit-field widths.
        block_offset_bits_ = 0;
        for (std::size_t v = block_size_bytes; v > 1; v >>= 1) ++block_offset_bits_;
        set_bits_ = 0;
        for (std::size_t v = num_sets_; v > 1; v >>= 1) ++set_bits_;

        entries_.resize(num_sets_ * assoc_);
        for (std::size_t s = 0; s < num_sets_; ++s) {
            for (std::size_t w = 0; w < assoc_; ++w) {
                entries_[s * assoc_ + w].lru_status = static_cast<int>(w);
            }
        }
    }

    // Access an address (byte-level). Returns true on hit, false on miss.
    // On miss the line is installed, evicting the LRU entry.
    bool access(std::uint64_t address) {
        if (num_sets_ == 0) return false;

        std::uint64_t tag_bits = address >> (block_offset_bits_ + set_bits_);
        std::uint64_t set_index = (address >> block_offset_bits_) & ((1ULL << set_bits_) - 1);
        std::size_t base = static_cast<std::size_t>(set_index) * assoc_;

        // Check for hit.
        for (std::size_t w = 0; w < assoc_; ++w) {
            Entry &e = entries_[base + w];
            if (e.valid && e.tag == tag_bits) {
                update_lru(base, w);
                return true;
            }
        }

        // Miss — find LRU way and replace.
        std::size_t lru_way = 0;
        for (std::size_t w = 0; w < assoc_; ++w) {
            if (entries_[base + w].lru_status == static_cast<int>(assoc_ - 1)) {
                lru_way = w;
                break;
            }
        }
        entries_[base + lru_way].tag = tag_bits;
        entries_[base + lru_way].valid = true;
        update_lru(base, lru_way);
        return false;
    }

private:
    void update_lru(std::size_t base, std::size_t mru_way) {
        int old_status = entries_[base + mru_way].lru_status;
        for (std::size_t w = 0; w < assoc_; ++w) {
            if (entries_[base + w].lru_status < old_status) {
                entries_[base + w].lru_status++;
            }
        }
        entries_[base + mru_way].lru_status = 0;
    }

    std::size_t assoc_ = 1;
    std::size_t num_sets_ = 0;
    unsigned block_offset_bits_ = 0;
    unsigned set_bits_ = 0;
    std::vector<Entry> entries_;
};

// PrefetchBuffer models a small holding area for prefetched lines. It tracks
// when each line becomes ready and whether the prefetch was actually used.
struct StreamBufferSimulator::PrefetchBuffer {
    // A probe can report that a line is absent, pending, or ready.
    enum class ProbeState {
        Absent,
        Pending,
        Ready
    };

    // ProbeResult bundles the state together with the ready time for the line.
    struct ProbeResult {
        ProbeState state = ProbeState::Absent;  // Initial state is "not present."
        std::uint64_t ready_at = 0;              // Logical time when the line becomes available.
    };

    // BufferEntry stores one prefetched line and the metadata needed to manage it.
    struct BufferEntry {
        std::uint64_t line = 0;      // Cache-line number held by this entry.
        std::uint64_t ready_at = 0;   // Time at which the line is usable.
        bool used = false;            // Whether a real read consumed this line.
        bool claimed = false;         // Whether a read has already matched this entry.
    };

    // Store the fixed capacity for the buffer.
    explicit PrefetchBuffer(std::size_t capacity)
        : capacity_(capacity) {}

    // Look up a line and report its state relative to the current time.
    ProbeResult probe(std::uint64_t line, std::uint64_t now) const {
        ProbeResult result;
        auto found = entries_.find(line);
        if (found == entries_.end()) {
            return result;  // The line is not in the prefetch buffer.
        }

        result.ready_at = found->second->ready_at;
        if (found->second->ready_at <= now) {
            result.state = ProbeState::Ready;
        } else {
            result.state = ProbeState::Pending;
        }
        return result;
    }

    // Check whether a line is present at all.
    bool contains(std::uint64_t line) const {
        return entries_.find(line) != entries_.end();
    }

    // Drop entries that were already claimed and are now ready to be retired.
    void cleanup_ready_claimed(std::uint64_t now) {
        for (auto it = lru_.begin(); it != lru_.end();) {
            if (it->claimed && it->ready_at <= now) {
                entries_.erase(it->line);
                it = lru_.erase(it);
                continue;
            }
            ++it;
        }
    }

    // Claim a buffer line for a read. This marks the line as useful and records
    // whether it was ready in time for the access.
    bool claim(std::uint64_t line, std::uint64_t now, bool *ready, std::uint64_t *ready_at, StreamBufferStats &stats) {
        auto found = entries_.find(line);
        if (found == entries_.end()) {
            return false;  // Nothing to claim because the line is absent.
        }

        BufferEntry &entry = *found->second;
        if (ready_at != nullptr) {
            *ready_at = entry.ready_at;
        }
        const bool is_ready = entry.ready_at <= now;
        if (ready != nullptr) {
            *ready = is_ready;
        }

        if (!entry.used) {
            entry.used = true;
            stats.prefetch_useful += 1;
        }

        entry.claimed = true;
        if (is_ready) {
            erase_iterator(found->second);  // Ready entries can be removed immediately.
        }
        return true;
    }

    // Insert a new prefetched line if the line is not already present.
    bool register_prefetch(std::uint64_t line, std::uint64_t ready_at, StreamBufferStats &stats) {
        if (capacity_ == 0) {
            return false;  // A zero-sized buffer cannot hold any prefetches.
        }

        auto found = entries_.find(line);
        if (found != entries_.end()) {
            stats.prefetch_duplicate_suppressed += 1;  // Do not issue the same prefetch twice.
            return false;
        }

        // Evict the oldest entry when the buffer is full.
        if (lru_.size() >= capacity_) {
            auto victim = lru_.begin();
            if (victim != lru_.end()) {
                if (!victim->used) {
                    stats.prefetch_evictions += 1;  // Count unused evictions separately.
                }
                entries_.erase(victim->line);
                lru_.erase(victim);
            }
        }

        // Push the new entry onto the back of the list so it becomes the MRU item.
        lru_.push_back(BufferEntry{line, ready_at, false, false});
        auto list_it = std::prev(lru_.end());
        entries_[line] = list_it;
        stats.prefetches_issued += 1;
        return true;
    }

    // Invalidate a prefetched line when a write touches the same address.
    void invalidate(std::uint64_t line, StreamBufferStats &stats) {
        auto found = entries_.find(line);
        if (found == entries_.end()) {
            return;  // Nothing to invalidate.
        }

        if (!found->second->used) {
            stats.prefetch_evictions += 1;  // Invalidating an unused line still counts as wasted work.
        }
        stats.prefetch_write_invalidations += 1;
        erase_iterator(found->second);
    }

    // Remove all remaining buffer entries during shutdown or trace flush.
    void flush(StreamBufferStats &stats) {
        for (const auto &entry : lru_) {
            if (!entry.used) {
                stats.prefetch_evictions += 1;
            }
        }
        entries_.clear();
        lru_.clear();
    }

private:
    // Remove one iterator from both the map and the list.
    void erase_iterator(std::list<BufferEntry>::iterator iter) {
        entries_.erase(iter->line);
        lru_.erase(iter);
    }

    std::size_t capacity_ = 0;  // Maximum number of prefetched lines allowed.
    std::list<BufferEntry> lru_;  // LRU list of prefetched lines.
    std::unordered_map<std::uint64_t, std::list<BufferEntry>::iterator> entries_;  // Fast line lookup into the list.
};

// The destructor is defaulted because the unique_ptr members own all dynamic
// storage and clean themselves up automatically.
StreamBufferSimulator::~StreamBufferSimulator() = default;

// Construct the simulator, validate the configuration, and allocate the helper
// structures that model the cache and prefetch buffer.
StreamBufferSimulator::StreamBufferSimulator(const StreamBufferConfig &config)
    : config_(config),
      l1d_cache_(new SetAssocCache(config.l1d_size_bytes, config.line_size_bytes, config.l1d_assoc)),
      l2_cache_(new SetAssocCache(config.l2_size_bytes, config.line_size_bytes, config.l2_assoc)),
      prefetch_buffer_(new PrefetchBuffer(config.prefetch_buffer_lines)),
      slots_(config.stream_slots),
      history_ready_(false) {
    // history_ready_ stays false until the first real epoch rollover. The
    // !history_ready_ branch in choose_prefetch_depth handles the bootstrap
    // (depth=1 if bootstrap_next_line is set, depth=0 otherwise) for ALL
    // stream lengths during warmup — not just length=1 like the previous
    // seeded-histogram approach did.
    if (config_.line_size_bytes == 0) {
        config_.line_size_bytes = 64;
    }
    if (config_.max_stream_length == 0) {
        config_.max_stream_length = 1;
    }
    lht_curr_.assign(config_.max_stream_length + 2, 0);
    lht_next_.assign(config_.max_stream_length + 2, 0);
}

// Expose the current statistics snapshot.
const StreamBufferStats &StreamBufferSimulator::stats() const {
    return stats_;
}

// Expose the current configuration snapshot.
const StreamBufferConfig &StreamBufferSimulator::config() const {
    return config_;
}

// Return the current learned histogram for inspection or testing.
std::vector<std::uint64_t> StreamBufferSimulator::histogram() const {
    return lht_curr_;
}

// Format a compact summary that can be printed by the CLI or Pintool.
std::string StreamBufferSimulator::summary(const std::string &label) const {
    std::ostringstream out;
    out << label << '\n';
    out << "  policy: " << to_string(config_.policy) << '\n';
    out << "  refs: " << stats_.total_refs << "  reads: " << stats_.reads << "  writes: " << stats_.writes << '\n';
    out << "  L1D: " << config_.l1d_size_bytes << "B " << config_.l1d_assoc << "-way"
        << "  L2: " << config_.l2_size_bytes << "B " << config_.l2_assoc << "-way\n";
    out << "  read L1 hits: " << stats_.read_hits << "  read L2 hits: " << stats_.read_l2_hits
        << "  read misses: " << stats_.read_misses
        << "  write L1 hits: " << stats_.write_hits << "  write L2 hits: " << stats_.write_l2_hits
        << "  write misses: " << stats_.write_misses << '\n';
    out << "  prefetches issued: " << stats_.prefetches_issued
        << "  useful: " << stats_.prefetch_useful
        << "  ready hits: " << stats_.prefetch_ready_hits
        << "  late hits: " << stats_.prefetch_late_hits
        << "  duplicate suppressions: " << stats_.prefetch_duplicate_suppressed << '\n';
    out << "  stream starts: " << stats_.stream_starts
        << "  extensions: " << stats_.stream_extensions
        << "  expirations: " << stats_.stream_expirations
        << "  epoch flushes: " << stats_.stream_epoch_flushes
        << "  dropped: " << stats_.stream_dropped
        << "  epochs: " << stats_.epochs_completed << '\n';
    out << "  modeled cycles: " << stats_.modeled_cycles
        << "  avg latency: " << std::fixed << std::setprecision(2) << stats_.average_access_latency() << '\n';
    out << "  prefetch accuracy: " << std::fixed << std::setprecision(2) << (stats_.prefetch_accuracy() * 100.0) << "%";
    out << "  coverage: " << std::fixed << std::setprecision(2) << (stats_.prefetch_coverage() * 100.0) << "%\n";
    return out.str();
}

// Collapse a byte address into a cache-line number.
std::uint64_t StreamBufferSimulator::address_to_line(std::uint64_t address) const {
    return address / config_.line_size_bytes;
}

// Convert the current slot state into the next line candidate in the stream.
// The current implementation keeps this helper for readability and extension
// even though the direct access logic computes the actual candidate itself.
std::uint64_t StreamBufferSimulator::current_stream_line(std::uint64_t line, const StreamSlot &slot) const {
    if (slot.direction < 0) {
        return slot.last_line - 1;
    }
    return line + 1;
}

// Advance logical time, retire claimed prefetches, and expire old streams.
void StreamBufferSimulator::tick() {
    ++logical_time_;

    if (config_.policy != PrefetchPolicy::Off) {
        prefetch_buffer_->cleanup_ready_claimed(logical_time_);
    }

    if (config_.policy == PrefetchPolicy::Off || slots_.empty()) {
        return;  // With no stream tracking, there is nothing else to age.
    }

    for (std::size_t i = 0; i < slots_.size(); ++i) {
        StreamSlot &slot = slots_[i];
        if (!slot.valid) {
            continue;
        }
        if (slot.remaining_life > 0) {
            --slot.remaining_life;
        }
        if (slot.remaining_life == 0) {
            expire_slot(i);
        }
    }
}

// Expire one slot because its lifetime reached zero.
void StreamBufferSimulator::expire_slot(std::size_t index) {
    if (index >= slots_.size() || !slots_[index].valid) {
        return;
    }
    finish_stream(index, /*epoch_flush=*/false);
    stats_.stream_expirations += 1;
}

// Finalize a live stream and optionally record that the stream was closed
// because the epoch rolled over.
void StreamBufferSimulator::finish_stream(std::size_t index, bool epoch_flush) {
    if (index >= slots_.size() || !slots_[index].valid) {
        return;
    }

    commit_length_to_next_hist(slots_[index].length);
    slots_[index] = StreamSlot{};
    if (epoch_flush) {
        stats_.stream_epoch_flushes += 1;
    }
}

// The paper's histogram is cumulative, so every stream of length N contributes
// to all buckets from 1 through N.
void StreamBufferSimulator::commit_length_to_next_hist(std::uint64_t length) {
    const std::uint64_t bucket = bucket_length(length, config_.max_stream_length);
    if (bucket == 0) {
        return;
    }
    for (std::uint64_t i = 1; i <= bucket; ++i) {
        lht_next_[static_cast<std::size_t>(i)] += length;
    }
}

// Move a completed epoch's data into the current histogram and clear the
// next-epoch table so learning can begin again.
void StreamBufferSimulator::rollover_epoch() {
    if (config_.policy == PrefetchPolicy::Off) {
        read_count_in_epoch_ = 0;
        return;
    }

    for (std::size_t i = 0; i < slots_.size(); ++i) {
        if (slots_[i].valid) {
            finish_stream(i, /*epoch_flush=*/true);
        }
    }

    std::uint64_t next_total = 0;
    for (std::size_t i = 1; i < lht_next_.size(); ++i) {
        next_total += lht_next_[i];
    }
    if (next_total > 0) {
        lht_curr_ = lht_next_;
        history_ready_ = true;
    }

    std::fill(lht_next_.begin(), lht_next_.end(), 0);
    read_count_in_epoch_ = 0;
    stats_.epochs_completed += 1;
}

// Search for the stream slot that best matches the current access.
std::size_t StreamBufferSimulator::find_matching_slot(std::uint64_t line) const {
    std::size_t best_index = slots_.size();  // Default to "no match found."
    std::uint64_t best_length = 0;           // Prefer longer streams when multiple slots match.
    std::uint64_t best_touch = 0;            // Break ties by most recent update time.

    for (std::size_t i = 0; i < slots_.size(); ++i) {
        const StreamSlot &slot = slots_[i];
        if (!slot.valid) {
            continue;  // Skip empty slots.
        }

        bool matches = false;
        if (slot.length == 1 && slot.direction == 0) {
            // A one-line stream can still grow in either direction.
            if ((line == slot.last_line + 1) || (slot.last_line > 0 && line + 1 == slot.last_line)) {
                matches = true;
            }
        } else if (slot.direction > 0) {
            matches = (line == slot.last_line + 1);
        } else if (slot.direction < 0) {
            matches = (slot.last_line > 0 && line + 1 == slot.last_line);
        }

        if (!matches) {
            continue;
        }

        if (slot.length > best_length || (slot.length == best_length && slot.last_touch >= best_touch)) {
            best_index = i;
            best_length = slot.length;
            best_touch = slot.last_touch;
        }
    }

    return best_index;
}

// Return the first unused slot, or slots_.size() when every slot is occupied.
std::size_t StreamBufferSimulator::find_free_slot() const {
    for (std::size_t i = 0; i < slots_.size(); ++i) {
        if (!slots_[i].valid) {
            return i;
        }
    }
    return slots_.size();
}

// Choose how many lines to prefetch using the current histogram.
std::uint32_t StreamBufferSimulator::choose_prefetch_depth(std::uint32_t current_length) const {
    if (config_.policy == PrefetchPolicy::Off) {
        return 0;  // No prefetches when the policy is disabled.
    }
    if (config_.policy == PrefetchPolicy::NextLine) {
        return 1;  // The next-line policy always fetches one extra line.
    }
    if (current_length == 0) {
        return 0;  // A zero-length stream is not meaningful.
    }
    if (!history_ready_) {
        return config_.bootstrap_next_line ? 1 : 0;  // Before learning, use a conservative bootstrap.
    }

    const std::uint32_t capped_length = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(current_length, static_cast<std::uint64_t>(config_.max_stream_length)));
    if (capped_length >= config_.max_stream_length) {
        // The stream has reached the histogram's largest bucket. We have direct
        // evidence the stream is long-lived, so prefetch maximally rather than
        // truncating to zero.
        return static_cast<std::uint32_t>(config_.max_prefetch_depth);
    }

    std::uint32_t depth = 0;
    for (std::uint32_t probe = capped_length;
         probe < config_.max_stream_length && depth < config_.max_prefetch_depth;
         ++probe) {
        const std::uint64_t left = lht_curr_[probe];
        const std::uint64_t right = lht_curr_[probe + 1];
        if (left < (2 * right)) {
            ++depth;  // Keep prefetching while the next-line probability dominates.
        } else {
            break;    // Stop once the histogram suggests the stream is likely ending.
        }
    }
    return depth;
}

// When all slots are full and a miss can't be tracked, we don't actually know
// whether it belongs to a short or long stream. Recording it as a phantom
// length-1 stream would bias the histogram toward "throttle." Instead we
// record nothing — the histogram only learns from streams we actually
// followed end-to-end.
void StreamBufferSimulator::record_singleton_stream() {
    // intentionally empty
}

// Issue one or more prefetches based on the current stream and the active
// policy.
void StreamBufferSimulator::maybe_generate_prefetches(std::uint64_t line, const StreamSlot *slot, std::uint64_t now) {
    if (config_.policy == PrefetchPolicy::Off) {
        return;
    }

    std::uint32_t depth = 0;  // How many lines to fetch ahead.
    std::int64_t step = 1;    // Directional step, positive for ascending streams.
    if (config_.policy == PrefetchPolicy::NextLine) {
        depth = 1;  // Always prefetch one line ahead.
    } else if (slot != nullptr) {
        depth = choose_prefetch_depth(static_cast<std::uint32_t>(std::max<std::uint64_t>(1, slot->length)));
        if (slot->direction < 0) {
            step = -1;  // Reverse direction for descending streams.
        }
    } else {
        depth = choose_prefetch_depth(1);  // Bootstrap a brand-new stream conservatively.
    }

    if (depth == 0) {
        return;  // The histogram said to stop prefetching.
    }

    for (std::uint32_t i = 1; i <= depth; ++i) {
        const std::int64_t candidate_signed = static_cast<std::int64_t>(line) + (step * static_cast<std::int64_t>(i));
        if (candidate_signed < 0) {
            break;  // Avoid wraparound if descending streams hit address 0.
        }
        const std::uint64_t candidate = static_cast<std::uint64_t>(candidate_signed);
        std::uint64_t ready_at = now + (config_.prefetch_latency_refs * i);
        prefetch_buffer_->register_prefetch(candidate, ready_at, stats_);
    }
}

// Process one memory access and update both the demand-cache model and the
// stream prefetch model.
void StreamBufferSimulator::access(AccessKind kind, std::uint64_t address) {
    tick();  // Every access advances logical time.
    ++stats_.total_refs;

    const std::uint64_t line = address_to_line(address);

    // The cache hierarchy uses byte addresses so the set/tag math works
    // correctly with the configured block size.
    const std::uint64_t byte_addr = line * config_.line_size_bytes;

    if (kind == AccessKind::Read) {
        ++stats_.reads;

        // L1D check.
        if (l1d_cache_->access(byte_addr)) {
            ++stats_.read_hits;
            stats_.modeled_cycles += config_.base_ref_cost + config_.hit_latency_refs;
            return;
        }

        // L1D miss — check L2.
        if (l2_cache_->access(byte_addr)) {
            ++stats_.read_l2_hits;
            // Install into L1D on the way back.
            l1d_cache_->access(byte_addr);
            stats_.modeled_cycles += config_.base_ref_cost + config_.l2_hit_latency_refs;
            return;
        }

        // L2 miss — this is a full memory miss. The stream buffer observes
        // L2 misses and may rescue the access from the prefetch buffer.
        ++stats_.read_misses;

        std::uint64_t access_latency = config_.miss_latency_refs;
        if (config_.policy != PrefetchPolicy::Off) {
            const auto probe = prefetch_buffer_->probe(line, logical_time_);
            if (probe.state != PrefetchBuffer::ProbeState::Absent) {
                bool ready = false;
                std::uint64_t ready_at = 0;
                prefetch_buffer_->claim(line, logical_time_, &ready, &ready_at, stats_);
                if (ready) {
                    access_latency = config_.hit_latency_refs;
                    ++stats_.prefetch_ready_hits;
                } else {
                    const std::uint64_t remaining = (ready_at > logical_time_) ? (ready_at - logical_time_) : 0;
                    access_latency = std::min(config_.miss_latency_refs, remaining);
                    ++stats_.prefetch_late_hits;
                }
            }
        }

        // Install the line into both cache levels.
        l2_cache_->access(byte_addr);
        l1d_cache_->access(byte_addr);

        if (config_.policy == PrefetchPolicy::NextLine) {
            maybe_generate_prefetches(line, nullptr, logical_time_);
        } else if (config_.policy == PrefetchPolicy::Adaptive) {
            const std::size_t match = find_matching_slot(line);
            StreamSlot *slot = nullptr;
            if (match != slots_.size()) {
                slot = &slots_[match];
                ++stats_.stream_extensions;
                if (slot->direction == 0 && slot->length == 1) {
                    if (line == slot->last_line + 1) {
                        slot->direction = 1;
                    } else if (slot->last_line > 0 && line + 1 == slot->last_line) {
                        slot->direction = -1;
                    }
                }
                slot->last_line = line;
                ++slot->length;
                slot->remaining_life = config_.stream_lifetime_refs;
                slot->last_touch = logical_time_;
            } else {
                const std::size_t free_slot = find_free_slot();
                if (free_slot != slots_.size()) {
                    slot = &slots_[free_slot];
                    slot->valid = true;
                    slot->last_line = line;
                    slot->direction = 0;
                    slot->length = 1;
                    slot->remaining_life = config_.stream_lifetime_refs;
                    slot->last_touch = logical_time_;
                    ++stats_.stream_starts;
                } else {
                    ++stats_.stream_dropped;
                    record_singleton_stream();
                }
            }

            if (slot != nullptr) {
                maybe_generate_prefetches(line, slot, logical_time_);
            }
        }

        stats_.modeled_cycles += config_.base_ref_cost + access_latency;
        if (config_.epoch_reads != 0) {
            ++read_count_in_epoch_;
            if (read_count_in_epoch_ >= config_.epoch_reads) {
                rollover_epoch();
            }
        }
        return;
    }

    // Writes go through the same L1D → L2 hierarchy.
    ++stats_.writes;
    if (l1d_cache_->access(byte_addr)) {
        ++stats_.write_hits;
        stats_.modeled_cycles += config_.base_ref_cost + config_.write_latency_refs;
    } else if (l2_cache_->access(byte_addr)) {
        ++stats_.write_l2_hits;
        l1d_cache_->access(byte_addr);
        stats_.modeled_cycles += config_.base_ref_cost + config_.l2_hit_latency_refs;
    } else {
        ++stats_.write_misses;
        l2_cache_->access(byte_addr);
        l1d_cache_->access(byte_addr);
        stats_.modeled_cycles += config_.base_ref_cost + config_.miss_latency_refs;
    }

    if (config_.policy != PrefetchPolicy::Off) {
        prefetch_buffer_->invalidate(line, stats_);
    }
}

// Flush any still-live state when the trace or thread ends.
void StreamBufferSimulator::flush() {
    if (config_.policy != PrefetchPolicy::Off) {
        for (std::size_t i = 0; i < slots_.size(); ++i) {
            if (slots_[i].valid) {
                finish_stream(i, /*epoch_flush=*/true);
            }
        }
        std::uint64_t next_total = 0;
        for (std::size_t i = 1; i < lht_next_.size(); ++i) {
            next_total += lht_next_[i];
        }
        if (next_total > 0) {
            lht_curr_ = lht_next_;
            history_ready_ = true;
        }
        std::fill(lht_next_.begin(), lht_next_.end(), 0);
        prefetch_buffer_->flush(stats_);
    }
}

// Create a benchmark harness that runs the selected policy alongside an
// always-off baseline.
StreamBufferBenchmark::StreamBufferBenchmark(const StreamBufferConfig &selected_config)
    : selected_(selected_config),
      baseline_([&selected_config]() {
          StreamBufferConfig baseline_config = selected_config;
          baseline_config.policy = PrefetchPolicy::Off;
          baseline_config.bootstrap_next_line = false;
          return baseline_config;
      }()) {}

// Send a memory reference through both the selected and baseline models.
void StreamBufferBenchmark::access(AccessKind kind, std::uint64_t address) {
    baseline_.access(kind, address);
    selected_.access(kind, address);
}

// Flush both simulators so the results are comparable.
void StreamBufferBenchmark::flush() {
    baseline_.flush();
    selected_.flush();
}

// Expose the selected-policy stats.
const StreamBufferStats &StreamBufferBenchmark::selected_stats() const {
    return selected_.stats();
}

// Expose the baseline stats.
const StreamBufferStats &StreamBufferBenchmark::baseline_stats() const {
    return baseline_.stats();
}

// Print a combined summary that compares the selected policy against the
// baseline no-prefetch model.
std::string StreamBufferBenchmark::summary(const std::string &label) const {
    std::ostringstream out;
    out << label << '\n';
    out << "  policy: " << to_string(selected_.config().policy) << '\n';
    out << "  selected cycles: " << selected_.stats().modeled_cycles << '\n';
    out << "  baseline cycles: " << baseline_.stats().modeled_cycles << '\n';
    const double speedup = (selected_.stats().modeled_cycles == 0)
                               ? 0.0
                               : static_cast<double>(baseline_.stats().modeled_cycles) /
                                     static_cast<double>(selected_.stats().modeled_cycles);
    out << "  speedup vs baseline: " << std::fixed << std::setprecision(3) << speedup << "x\n";
    out << '\n';
    out << selected_.summary("selected");
    out << baseline_.summary("baseline");
    return out.str();
}

} // namespace adaptive_stream
