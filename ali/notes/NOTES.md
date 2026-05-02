SOTA
======================
State-of-the-Art (SOTA) hardware implementations for stream buffer prefetching have evolved from simple FIFO queues into sophisticated, adaptive, and multi-stream tracking engines that often utilize non-blocking, asynchronous mechanisms to hide memory latency. Modern designs often incorporate Adaptive Stream Detection, non-unit stride support, and compact metadata representation (like Streamline) to maximize accuracy while minimizing bandwidth overhead. 
 

Adaptive Stream Detection 
----------------------
Instead of constant prefetching, SOTA implementations dynamically modulate prefetching aggressiveness based on workload behavior. If a stream is detected, the degree (how far ahead) and distance (when to start) are adjusted, reducing wasteful, inaccurate fetches.

Multi-Stream Tracking (Stream Table)
----------------------
Modern processors utilize a stream table (similar to a Reference Prediction Table) to track dozens of simultaneous, independent, and interleaved memory access streams. A "trained" stream triggers prefetching of consecutive cache lines into dedicated FIFO stream buffers.

Non-Unit Stride Support
----------------------
SOTA prefetchers do not just handle sequential (stride-1) streams; they handle strides greater than the cache block size by detecting the delta between misses and allocating streams to fetch those non-adjacent blocks.

Decoupled & Asynchronous Design
----------------------
Stream buffers are implemented as FIFOs alongside the cache, acting as a small buffer to store prefetched data. When a stream is active, the prefetcher independently interacts with DRAM to populate the buffer, decoupling the fetch latency from demand misses. 
