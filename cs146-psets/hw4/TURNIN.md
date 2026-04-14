### Inclusion Property 

###### Explain the concept of cache inclusion property

We describe a cache as inclusive, if everything it contains also exists in its underlying larger cache. For example, if $L_1$ is an inclusive cache, then $L_1 \subseteq L_2$.Or in other words, if a block is in $L_1$, it must also be in $L_2$, so $L_2$ acts as a superset or backup of $L_1$.

###### The paper also mentions that the line size of the second-level cache is 8 to 10 times larger than the first-level cache line size, which also violates the inclusion property. Explain why this is true with a simple example.

An $L_1$ cache with a smaller line size than $L_2$ violates the inclusion property (where $L_2$ must contain everything in $L_1$) because a single $L_2$ line might map to multiple, independent L1 lines, making it impossible to accurately manage evictions. If an L2 line containing a shared cache block is evicted, back-invalidation cannot properly remove the data from the smaller L1 line. Here is a simple example.

$L_2$ Line Size: 128 bytes (One large block)
$L_1$ Line Size: 64 bytes (Two small blocks fit in one $L_2$ block)

Read Operation: The CPU requests 64 bytes of data from address $0x100$. This data is not in $L_1$ or $L_2$. The system fetches the full 128-byte block (containing $A_1$ and $A_2$ where $A_2$ is at $0x140$) from main memory and stores it in $L_2$.

$L_1$ Cache Miss: The 64-byte block $A_1$ is copied to $L_1$. Currently, $L_2$ has 128-byte block ($A_1 + A_2$). $L_1$ has 64-byte block ($A_1$). (Inclusion holds).

$L_1$ Cache Access: The CPU requests the next 64 bytes ($A_2$) from address $0x140$.

$L_1$ Cache Hit: The 64-byte block $A_2$ is copied to $L_1$. Now, $L_2$ has 128-byte block ($A_1 + A_2$). $L_1$ has 64-byte blocks ($A_1$ and $A_2$). (Inclusion holds).

$L_2$ Eviction (The Violation): At some other point in the future, the $L_2$ cache needs to make room and evicts the 128-byte block ($A_1 + A_2$). Inclusion Violation: Because of the eviction, $A_1$ and $A_2$ are gone from $L_2$, but $A_1$ and $A_2$ still exist in the $L_1$ cache.

### Stream Buffers

###### Explain how a stream buffer works with a reference stream that skips to every third word

A stream buffer is designed to prefetch sequential memory addresses assuming a unit-stride access pattern (i.e., consecutive addresses). When the program instead accesses memory with stride 3 (e.g., $A$, $A+3$, $A+6$, $A+9$, $\dots$), the stream buffer still behaves as if the access pattern were sequential.

On the first miss at address A, the stream buffer begins prefetching the next consecutive blocks: $A+1$, $A+2$, $A+3$, $A+4$, $\dots$. When the processor later accesses A+3, that block has already been prefetched and can be supplied without a cache miss. The same continues for future accesses (e.g., $A+6$, $A+9$), since they will eventually appear in the prefetched stream.

However, this approach is inefficient because many prefetched blocks (e.g., $A+1$, $A+2$, $A+4$, $A+5$) are never used. Thus, while the stream buffer can still reduce misses for small strides like 2 or 3, it wastes memory bandwidth and buffer space.

###### How would you design stream buffers differently to handle non-unit stride?

To better handle non-unit-stride access patterns, stream buffers can be enhanced to detect and prefetch based on the actual stride of the program.

One approach is to use a stride-detecting prefetcher, which tracks the difference between consecutive memory accesses (e.g., detects that accesses increase by $+3$ each time). Once a consistent stride is identified, the stream buffer can prefetch future addresses using that stride (e.g., $A+3$, $A+6$, $A+9$, $\dots$) instead of sequentially.

Another approach is to use multiple or adaptive stream buffers, where each buffer tracks a different access stream and dynamically adjusts its prefetch pattern based on observed behavior. More advanced designs may use correlation-based or history-based predictors to recognize more complex access patterns.

These modifications allow the system to prefetch only useful data, improving both bandwidth efficiency and cache performance for non-unit-stride workloads.
