//
//  EmbeddingSimilarity.metal
//  PhotoVault
//
//  Exact dot-product scan over the embedding matrix.
//
//  Why exact, and why no approximate index
//  ---------------------------------------
//  The plan is explicit that V1 does no ANN/HNSW. That is the right call here
//  and not merely a simplification: a 100k x 768 Float16 matrix is 147 MiB, the
//  scan is memory-bandwidth bound, and an approximate index would trade a real
//  recall loss for a speedup we do not need. Recall failures in photo search are
//  invisible -- the photo the user wanted simply is not there, with no error to
//  explain why -- so paying that cost for latency headroom we already have would
//  be a bad trade.
//
//  Rows are unit length and the query is normalised before it reaches the GPU,
//  so the dot product *is* the cosine similarity and there is no per-row
//  division.
//

#include <metal_stdlib>
using namespace metal;

// One thread per row.
//
// The kernel is memory bound: 768 halves is 1536 bytes per row, so the only
// things that matter are issuing wide loads and keeping enough threads in flight
// to saturate bandwidth. Accumulating in `float4` gives 8-byte loads instead of
// 2-byte ones; the horizontal add is deferred to the end so the inner loop stays
// a single FMA per component.
//
// A scalar tail handles dimensions that are not a multiple of four, so there is
// one kernel for every shape rather than a dispatch-time branch that could be
// wrong for some model. The embedding dimension is read from the model manifest
// and never assumed to be 768, so this path is reachable in principle and must
// be correct when it is.
kernel void embedding_dot_fp16(
    device const half  *rows      [[buffer(0)]],
    device const float *query     [[buffer(1)]],
    device       float *scores    [[buffer(2)]],
    constant     uint  &dimension [[buffer(3)]],
    constant     uint  &rowCount  [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= rowCount) {
        return;
    }

    const uint vectors = dimension >> 2;
    const uint tail = dimension & 3u;

    device const half4  *row = (device const half4 *)(rows + (ulong)gid * (ulong)dimension);
    device const float4 *q   = (device const float4 *)query;

    float4 accumulator = float4(0.0f);
    for (uint i = 0; i < vectors; ++i) {
        accumulator += float4(row[i]) * q[i];
    }

    float total = accumulator.x + accumulator.y + accumulator.z + accumulator.w;
    if (tail > 0) {
        device const half  *rowTail = rows + (ulong)gid * (ulong)dimension + (ulong)(vectors << 2);
        device const float *qTail   = query + (vectors << 2);
        for (uint i = 0; i < tail; ++i) {
            total += float(rowTail[i]) * qTail[i];
        }
    }
    scores[gid] = total;
}
