#include "stream_buffer.hpp"

// The simulator CLI needs standard file, string, and formatting utilities to
// parse traces and print the resulting benchmark summary.
#include <cstdlib>     // Included for completeness with the system C++ runtime.
#include <fstream>     // std::ifstream for reading trace files from disk.
#include <iostream>    // std::cin, std::cout, and std::cerr.
#include <sstream>     // std::istringstream for splitting trace lines.
#include <string>      // std::string for arguments and trace fields.
#include <stdexcept>   // std::runtime_error for invalid numeric input.

using adaptive_stream::AccessKind;
using adaptive_stream::PrefetchPolicy;
using adaptive_stream::StreamBufferBenchmark;
using adaptive_stream::StreamBufferConfig;
using adaptive_stream::parse_policy;

namespace {

// Print a short usage message that lists the supported knobs.
void print_usage(const char *argv0) {
    std::cerr
        << "Usage: " << argv0 << " [options] [trace-file]\n"
        << "Options:\n"
        << "  --policy off|nextline|adaptive\n"
        << "  --line-size N\n"
        << "  --demand-cache-lines N\n"
        << "  --prefetch-buffer-lines N\n"
        << "  --stream-slots N\n"
        << "  --max-stream-length N\n"
        << "  --epoch-reads N\n"
        << "  --stream-lifetime N\n"
        << "  --prefetch-latency N\n"
        << "  --miss-latency N\n"
        << "  --hit-latency N\n"
        << "  --write-latency N\n"
        << "  --base-cost N\n"
        << "  --max-prefetch-depth N\n"
        << "  --no-bootstrap\n";
}

// Parse an unsigned integer while ensuring that the entire string was valid.
std::uint64_t parse_u64(const std::string &text) {
    std::size_t consumed = 0;
    const std::uint64_t value = std::stoull(text, &consumed, 0);
    if (consumed != text.size()) {
        throw std::runtime_error("invalid integer: " + text);
    }
    return value;
}

// Convert a trace marker into the corresponding access kind.
AccessKind parse_kind(char c) {
    if (c == 'R' || c == 'r') {
        return AccessKind::Read;
    }
    return AccessKind::Write;
}

} // namespace

int main(int argc, char **argv) {
    // Start with the default configuration and let command-line options override it.
    StreamBufferConfig config;
    std::string trace_path;

    // Parse each argument in order, treating the last bare argument as the
    // optional trace-file path.
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--policy" && i + 1 < argc) {
            config.policy = parse_policy(argv[++i]);
            continue;
        }
        if (arg == "--line-size" && i + 1 < argc) {
            config.line_size_bytes = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--demand-cache-lines" && i + 1 < argc) {
            config.demand_cache_lines = static_cast<std::size_t>(parse_u64(argv[++i]));
            continue;
        }
        if (arg == "--prefetch-buffer-lines" && i + 1 < argc) {
            config.prefetch_buffer_lines = static_cast<std::size_t>(parse_u64(argv[++i]));
            continue;
        }
        if (arg == "--stream-slots" && i + 1 < argc) {
            config.stream_slots = static_cast<std::size_t>(parse_u64(argv[++i]));
            continue;
        }
        if (arg == "--max-stream-length" && i + 1 < argc) {
            config.max_stream_length = static_cast<std::size_t>(parse_u64(argv[++i]));
            continue;
        }
        if (arg == "--epoch-reads" && i + 1 < argc) {
            config.epoch_reads = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--stream-lifetime" && i + 1 < argc) {
            config.stream_lifetime_refs = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--prefetch-latency" && i + 1 < argc) {
            config.prefetch_latency_refs = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--miss-latency" && i + 1 < argc) {
            config.miss_latency_refs = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--hit-latency" && i + 1 < argc) {
            config.hit_latency_refs = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--write-latency" && i + 1 < argc) {
            config.write_latency_refs = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--base-cost" && i + 1 < argc) {
            config.base_ref_cost = parse_u64(argv[++i]);
            continue;
        }
        if (arg == "--max-prefetch-depth" && i + 1 < argc) {
            config.max_prefetch_depth = static_cast<std::size_t>(parse_u64(argv[++i]));
            continue;
        }
        if (arg == "--no-bootstrap") {
            config.bootstrap_next_line = false;
            continue;
        }
        if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return 0;
        }
        if (!arg.empty() && arg[0] != '-') {
            trace_path = arg;
            continue;
        }

        std::cerr << "Unknown argument: " << arg << "\n";
        print_usage(argv[0]);
        return 1;
    }

    // Run the selected policy and a baseline no-prefetch policy side by side.
    StreamBufferBenchmark benchmark(config);

    // Default to stdin, but switch to a file stream if a path was supplied.
    std::istream *input = &std::cin;
    std::ifstream trace_file;
    if (!trace_path.empty()) {
        trace_file.open(trace_path.c_str());
        if (!trace_file) {
            std::cerr << "Unable to open trace file: " << trace_path << "\n";
            return 1;
        }
        input = &trace_file;
    }

    // Each trace line is expected to look like "R 0x1000" or "W 0x1000".
    std::string line;
    while (std::getline(*input, line)) {
        if (line.empty()) {
            continue;
        }
        std::istringstream iss(line);
        char kind = '\0';
        std::string address_text;
        if (!(iss >> kind >> address_text)) {
            continue;
        }
        const AccessKind access_kind = parse_kind(kind);
        const std::uint64_t address = parse_u64(address_text);
        benchmark.access(access_kind, address);
    }

    // Flush the model so the histogram and buffer state are finalized.
    benchmark.flush();
    std::cout << benchmark.summary("stream-buffer benchmark");
    return 0;
}
