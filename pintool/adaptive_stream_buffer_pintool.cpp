#include "pin.H"

// The Pintool reuses the shared simulator core so the trace-driven CLI and the
// Pin-driven workflow stay behaviorally aligned.
#include "../src/stream_buffer.hpp"
#include "../src/stream_buffer.cpp"

// The final report uses iostreams and formatting helpers.
#include <cstdlib>   // std::exit for the early-cutoff path.
#include <iomanip>   // std::fixed and std::setprecision for percentages.
#include <iostream>  // std::cout and std::cerr for status output.
#include <memory>    // std::unique_ptr for per-thread benchmark ownership.
#include <sstream>   // std::ostringstream for the final summary block.
#include <string>    // std::string for Pin knobs.

using adaptive_stream::AccessKind;
using adaptive_stream::PrefetchPolicy;
using adaptive_stream::StreamBufferBenchmark;
using adaptive_stream::StreamBufferConfig;
using adaptive_stream::StreamBufferStats;
using adaptive_stream::parse_policy;
using adaptive_stream::to_string;

namespace {

// Pin knobs expose the same configuration that the standalone simulator uses.
KNOB<std::string> KnobPolicy(KNOB_MODE_WRITEONCE, "pintool", "policy", "adaptive",
                             "Prefetch policy: off, nextline, or adaptive");
KNOB<UINT64> KnobLineSize(KNOB_MODE_WRITEONCE, "pintool", "line_size", "64",
                          "Cache-line size in bytes");
KNOB<UINT64> KnobL1DSize(KNOB_MODE_WRITEONCE, "pintool", "l1d_size", "4096",
                         "L1 data cache size in bytes");
KNOB<UINT64> KnobL1DAssoc(KNOB_MODE_WRITEONCE, "pintool", "l1d_assoc", "1",
                          "L1 data cache associativity");
KNOB<UINT64> KnobL2Size(KNOB_MODE_WRITEONCE, "pintool", "l2_size", "1048576",
                        "L2 cache size in bytes");
KNOB<UINT64> KnobL2Assoc(KNOB_MODE_WRITEONCE, "pintool", "l2_assoc", "1",
                         "L2 cache associativity");
KNOB<UINT64> KnobPrefetchBufferLines(KNOB_MODE_WRITEONCE, "pintool", "prefetch_buffer_lines", "16",
                                     "Prefetch buffer capacity in lines");
KNOB<UINT64> KnobStreamSlots(KNOB_MODE_WRITEONCE, "pintool", "stream_slots", "8",
                             "Number of tracked streams");
KNOB<UINT64> KnobMaxStreamLength(KNOB_MODE_WRITEONCE, "pintool", "max_stream_length", "16",
                                 "Maximum tracked stream length");
KNOB<UINT64> KnobEpochReads(KNOB_MODE_WRITEONCE, "pintool", "epoch_reads", "2000",
                            "Read misses per histogram epoch");
KNOB<UINT64> KnobStreamLifetime(KNOB_MODE_WRITEONCE, "pintool", "stream_lifetime", "256",
                                "Stream lifetime in reference steps");
KNOB<UINT64> KnobPrefetchLatency(KNOB_MODE_WRITEONCE, "pintool", "prefetch_latency", "8",
                                 "Prefetch arrival latency in reference steps");
KNOB<UINT64> KnobMissLatency(KNOB_MODE_WRITEONCE, "pintool", "miss_latency", "80",
                             "L2-miss (memory) latency in reference steps");
KNOB<UINT64> KnobL2HitLatency(KNOB_MODE_WRITEONCE, "pintool", "l2_hit_latency", "10",
                               "L2-hit latency in reference steps");
KNOB<UINT64> KnobHitLatency(KNOB_MODE_WRITEONCE, "pintool", "hit_latency", "1",
                            "L1 hit latency in reference steps");
KNOB<UINT64> KnobWriteLatency(KNOB_MODE_WRITEONCE, "pintool", "write_latency", "1",
                              "Write hit latency in reference steps");
KNOB<UINT64> KnobBaseCost(KNOB_MODE_WRITEONCE, "pintool", "base_cost", "1",
                          "Base per-access cost in reference steps");
KNOB<UINT64> KnobMaxPrefetchDepth(KNOB_MODE_WRITEONCE, "pintool", "max_prefetch_depth", "8",
                                  "Maximum number of lines issued per stream access");
KNOB<BOOL> KnobBootstrap(KNOB_MODE_WRITEONCE, "pintool", "bootstrap_next_line", "1",
                         "Use next-line bootstrap before the first learned histogram");
KNOB<UINT64> KnobMaxInstructions(KNOB_MODE_WRITEONCE, "pintool", "max_instructions", "0",
                                 "Stop after this many instructions per thread (0 disables)");

// ThreadState bundles the per-thread benchmark harness so each thread can track
// its own stream behavior independently.
struct ThreadState {
    std::unique_ptr<StreamBufferBenchmark> benchmark;  // The owned benchmark instance for this thread.
    UINT64 instructions_seen = 0;                      // Optional cutoff counter used for smoke tests.
};

// Forward declaration so OnInstruction can call Fini directly on early exit.
VOID Fini(INT32 code, VOID *v);

// Pin needs a TLS key so analysis routines can recover the thread-local state.
TLS_KEY g_tls_key;
// The summary lock prevents multiple threads from updating the totals at once.
PIN_LOCK g_summary_lock;
// The aggregate stats for the selected policy.
StreamBufferStats g_selected_total;
// The aggregate stats for the no-prefetch baseline.
StreamBufferStats g_baseline_total;
// The active configuration used by new threads.
StreamBufferConfig g_selected_config;
// The optional instruction cutoff. A value of 0 disables the cutoff.
UINT64 g_max_instructions = 0;

// Read all knob values and build the configuration that the simulator expects.
StreamBufferConfig BuildConfigFromKnobs() {
    StreamBufferConfig config;
    config.policy = parse_policy(KnobPolicy.Value());
    config.line_size_bytes = KnobLineSize.Value();
    config.l1d_size_bytes = static_cast<std::size_t>(KnobL1DSize.Value());
    config.l1d_assoc = static_cast<std::size_t>(KnobL1DAssoc.Value());
    config.l2_size_bytes = static_cast<std::size_t>(KnobL2Size.Value());
    config.l2_assoc = static_cast<std::size_t>(KnobL2Assoc.Value());
    config.prefetch_buffer_lines = static_cast<std::size_t>(KnobPrefetchBufferLines.Value());
    config.stream_slots = static_cast<std::size_t>(KnobStreamSlots.Value());
    config.max_stream_length = static_cast<std::size_t>(KnobMaxStreamLength.Value());
    config.epoch_reads = KnobEpochReads.Value();
    config.stream_lifetime_refs = KnobStreamLifetime.Value();
    config.prefetch_latency_refs = KnobPrefetchLatency.Value();
    config.miss_latency_refs = KnobMissLatency.Value();
    config.l2_hit_latency_refs = KnobL2HitLatency.Value();
    config.hit_latency_refs = KnobHitLatency.Value();
    config.write_latency_refs = KnobWriteLatency.Value();
    config.base_ref_cost = KnobBaseCost.Value();
    config.max_prefetch_depth = static_cast<std::size_t>(KnobMaxPrefetchDepth.Value());
    config.bootstrap_next_line = KnobBootstrap.Value();
    return config;
}

// Recover the thread-local state from Pin's TLS slot.
ThreadState *GetThreadState(THREADID tid) {
    return static_cast<ThreadState *>(PIN_GetThreadData(g_tls_key, tid));
}

// Analysis callback for read accesses.
VOID PIN_FAST_ANALYSIS_CALL OnRead(THREADID tid, ADDRINT addr) {
    ThreadState *state = GetThreadState(tid);
    if (state != nullptr && state->benchmark) {
        state->benchmark->access(AccessKind::Read, static_cast<std::uint64_t>(addr));
    }
}

// Analysis callback for write accesses.
VOID PIN_FAST_ANALYSIS_CALL OnWrite(THREADID tid, ADDRINT addr) {
    ThreadState *state = GetThreadState(tid);
    if (state != nullptr && state->benchmark) {
        state->benchmark->access(AccessKind::Write, static_cast<std::uint64_t>(addr));
    }
}

// Count executed instructions so smoke tests can stop after a fixed budget.
VOID OnInstruction(THREADID tid) {
    if (g_max_instructions == 0) {
        return;
    }

    ThreadState *state = GetThreadState(tid);
    if (state == nullptr) {
        return;
    }

    state->instructions_seen += 1;
    if (state->instructions_seen >= g_max_instructions) {
        // PIN_ExitApplication hangs in Pin 3.x; std::exit skips Fini callbacks in this
        // version. So flush this thread's stats and call Fini directly before exiting.
        state->benchmark->flush();
        g_selected_total.merge(state->benchmark->selected_stats());
        g_baseline_total.merge(state->benchmark->baseline_stats());
        Fini(0, nullptr);
        std::exit(0);
    }
}

// Instrument every instruction and insert callbacks for each memory operand.
VOID Instruction(INS ins, VOID *v) {
    if (g_max_instructions != 0) {
        INS_InsertCall(
            ins, IPOINT_BEFORE, AFUNPTR(OnInstruction),
            IARG_THREAD_ID, IARG_END);
    }

    const UINT32 mem_ops = INS_MemoryOperandCount(ins);
    for (UINT32 op = 0; op < mem_ops; ++op) {
        if (INS_MemoryOperandIsRead(ins, op)) {
            INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE, AFUNPTR(OnRead),
                IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_MEMORYOP_EA, op, IARG_END);
        }
        if (INS_MemoryOperandIsWritten(ins, op)) {
            INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE, AFUNPTR(OnWrite),
                IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_MEMORYOP_EA, op, IARG_END);
        }
    }
}

// Create a fresh benchmark object when a thread starts.
VOID ThreadStart(THREADID tid, CONTEXT *ctxt, INT32 flags, VOID *v) {
    (void)ctxt;
    (void)flags;
    (void)v;

    ThreadState *state = new ThreadState();
    state->benchmark.reset(new StreamBufferBenchmark(g_selected_config));
    PIN_SetThreadData(g_tls_key, state, tid);
}

// Flush thread-local state, merge its results into the process totals, and
// clean up the heap allocation.
VOID ThreadFini(THREADID tid, const CONTEXT *ctxt, INT32 code, VOID *v) {
    (void)ctxt;
    (void)code;
    (void)v;

    ThreadState *state = GetThreadState(tid);
    if (state == nullptr) {
        return;
    }

    state->benchmark->flush();

    PIN_GetLock(&g_summary_lock, tid + 1);
    g_selected_total.merge(state->benchmark->selected_stats());
    g_baseline_total.merge(state->benchmark->baseline_stats());
    PIN_ReleaseLock(&g_summary_lock);

    delete state;
    PIN_SetThreadData(g_tls_key, nullptr, tid);
}

// Print one consolidated summary at program exit.
VOID Fini(INT32 code, VOID *v) {
    (void)code;
    (void)v;

    // Guard against double-printing if both the early-exit path and Pin's own
    // shutdown sequence end up calling Fini.
    static volatile bool done = false;
    if (done) return;
    done = true;

    std::ostringstream out;
    out << "adaptive stream buffer pintool\n";
    out << "  policy: " << to_string(g_selected_config.policy) << '\n';
    out << "  line size: " << g_selected_config.line_size_bytes << '\n';
    out << "  L1D: " << g_selected_config.l1d_size_bytes << "B " << g_selected_config.l1d_assoc << "-way\n";
    out << "  L2: " << g_selected_config.l2_size_bytes << "B " << g_selected_config.l2_assoc << "-way\n";
    out << "  prefetch buffer lines: " << g_selected_config.prefetch_buffer_lines << '\n';
    out << "  stream slots: " << g_selected_config.stream_slots << '\n';
    out << "  max stream length: " << g_selected_config.max_stream_length << '\n';
    out << "  epoch reads: " << g_selected_config.epoch_reads << "\n\n";
    if (g_max_instructions != 0) {
        out << "  instruction limit per thread: " << g_max_instructions << "\n\n";
    }

    out << "selected\n";
    out << "  refs: " << g_selected_total.total_refs << "  reads: " << g_selected_total.reads
        << "  writes: " << g_selected_total.writes << '\n';
    out << "  read L1 hits: " << g_selected_total.read_hits << "  read L2 hits: " << g_selected_total.read_l2_hits
        << "  read misses: " << g_selected_total.read_misses
        << "  write L1 hits: " << g_selected_total.write_hits << "  write L2 hits: " << g_selected_total.write_l2_hits
        << "  write misses: " << g_selected_total.write_misses << '\n';
    out << "  prefetches issued: " << g_selected_total.prefetches_issued
        << "  useful: " << g_selected_total.prefetch_useful
        << "  ready hits: " << g_selected_total.prefetch_ready_hits
        << "  late hits: " << g_selected_total.prefetch_late_hits << '\n';
    out << "  accuracy: " << std::fixed << std::setprecision(2)
        << (g_selected_total.prefetch_accuracy() * 100.0) << "%"
        << "  coverage: " << (g_selected_total.prefetch_coverage() * 100.0) << "%\n";
    out << "  modeled cycles: " << g_selected_total.modeled_cycles << '\n';

    out << "baseline\n";
    out << "  refs: " << g_baseline_total.total_refs << "  reads: " << g_baseline_total.reads
        << "  writes: " << g_baseline_total.writes << '\n';
    out << "  read L1 hits: " << g_baseline_total.read_hits << "  read L2 hits: " << g_baseline_total.read_l2_hits
        << "  read misses: " << g_baseline_total.read_misses
        << "  write L1 hits: " << g_baseline_total.write_hits << "  write L2 hits: " << g_baseline_total.write_l2_hits
        << "  write misses: " << g_baseline_total.write_misses << '\n';
    out << "  modeled cycles: " << g_baseline_total.modeled_cycles << '\n';

    const double speedup = (g_selected_total.modeled_cycles == 0)
                               ? 0.0
                               : static_cast<double>(g_baseline_total.modeled_cycles) /
                                     static_cast<double>(g_selected_total.modeled_cycles);
    out << "  speedup vs baseline: " << std::fixed << std::setprecision(3) << speedup << "x\n";

    std::cout << out.str();
}

} // namespace

int main(int argc, char *argv[]) {
    // Let Pin parse its own arguments and exit early if initialization fails.
    if (PIN_Init(argc, argv)) {
        std::cerr << "Pin initialization failed.\n";
        return 1;
    }

    // Snapshot the chosen knob values before the first thread starts.
    g_selected_config = BuildConfigFromKnobs();
    g_max_instructions = KnobMaxInstructions.Value();
    PIN_InitLock(&g_summary_lock);
    g_tls_key = PIN_CreateThreadDataKey(nullptr);

    // Register the instrumentation and lifecycle callbacks.
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    PIN_AddThreadFiniFunction(ThreadFini, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    // Hand control to the target program.
    PIN_StartProgram();
    return 0;
}
