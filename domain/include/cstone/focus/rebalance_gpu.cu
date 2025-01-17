/*
 * MIT License
 *
 * Copyright (c) 2022 CSCS, ETH Zurich
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/*! @file
 * @brief Focused octree rebalance on GPUs
 *
 * @author Sebastian Keller <sebastian.f.keller@gmail.com>
 */

#include <cub/cub.cuh>

#include "cstone/cuda/errorcheck.cuh"
#include "cstone/focus/rebalance.hpp"
#include "cstone/focus/rebalance_gpu.h"
#include "cstone/util/util.hpp"

namespace cstone
{

template<class KeyType>
__global__ void rebalanceDecisionEssentialKernel(const KeyType* prefixes,
                                                 const TreeNodeIndex* childOffsets,
                                                 const TreeNodeIndex* parents,
                                                 const unsigned* counts,
                                                 const char* macs,
                                                 KeyType focusStart,
                                                 KeyType focusEnd,
                                                 unsigned bucketSize,
                                                 TreeNodeIndex* nodeOps,
                                                 TreeNodeIndex numNodes)
{
    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < numNodes)
    {
        nodeOps[tid] =
            mergeCountAndMacOp(tid, prefixes, childOffsets, parents, counts, macs, focusStart, focusEnd, bucketSize);
    }
}

template<class KeyType>
void rebalanceDecisionEssentialGpu(const KeyType* prefixes,
                                   const TreeNodeIndex* childOffsets,
                                   const TreeNodeIndex* parents,
                                   const unsigned* counts,
                                   const char* macs,
                                   KeyType focusStart,
                                   KeyType focusEnd,
                                   unsigned bucketSize,
                                   TreeNodeIndex* nodeOps,
                                   TreeNodeIndex numNodes)
{
    constexpr unsigned numThreads = 256;
    rebalanceDecisionEssentialKernel<<<iceil(numNodes, numThreads), numThreads>>>(
        prefixes, childOffsets, parents, counts, macs, focusStart, focusEnd, bucketSize, nodeOps, numNodes);
}

template void rebalanceDecisionEssentialGpu(const uint32_t* prefixes,
                                            const TreeNodeIndex* childOffsets,
                                            const TreeNodeIndex* parents,
                                            const unsigned* counts,
                                            const char* macs,
                                            uint32_t focusStart,
                                            uint32_t focusEnd,
                                            unsigned bucketSize,
                                            TreeNodeIndex* nodeOps,
                                            TreeNodeIndex numNodes);

template void rebalanceDecisionEssentialGpu(const uint64_t* prefixes,
                                            const TreeNodeIndex* childOffsets,
                                            const TreeNodeIndex* parents,
                                            const unsigned* counts,
                                            const char* macs,
                                            uint64_t focusStart,
                                            uint64_t focusEnd,
                                            unsigned bucketSize,
                                            TreeNodeIndex* nodeOps,
                                            TreeNodeIndex numNodes);

__device__ int nodeOpSum;
__global__ void resetNodeOpSum() { nodeOpSum = 0; }

template<class KeyType>
__global__ void protectAncestorsKernel(const KeyType* prefixes,
                                       const TreeNodeIndex* parents,
                                       TreeNodeIndex* nodeOps,
                                       TreeNodeIndex numNodes)
{
    int nodeOp = 1;

    unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < numNodes)
    {
        nodeOp = nzAncestorOp(tid, prefixes, parents, nodeOps);
        // technically a race condition since nodeOps[tid] might be read by another thread,
        // but all possible outcomes are identical
        nodeOps[tid] = nodeOp;
    }

    typedef cub::BlockReduce<int, 256> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;

    BlockReduce reduce(temp_storage);
    int blockMin = reduce.Reduce(int(nodeOp != 1), cub::Sum());
    __syncthreads();

    if (threadIdx.x == 0) { atomicAdd(&nodeOpSum, blockMin); }
}

template<class KeyType>
bool protectAncestorsGpu(const KeyType* prefixes,
                         const TreeNodeIndex* parents,
                         TreeNodeIndex* nodeOps,
                         TreeNodeIndex numNodes)
{
    resetNodeOpSum<<<1, 1>>>();

    constexpr unsigned numThreads = 256;
    protectAncestorsKernel<<<iceil(numNodes, numThreads), numThreads>>>(prefixes, parents, nodeOps, numNodes);

    int numNodesModify;
    checkGpuErrors(cudaMemcpyFromSymbol(&numNodesModify, nodeOpSum, sizeof(int)));

    return numNodesModify == 0;
}

template bool protectAncestorsGpu(const uint32_t*, const TreeNodeIndex*, TreeNodeIndex*, TreeNodeIndex);
template bool protectAncestorsGpu(const uint64_t*, const TreeNodeIndex*, TreeNodeIndex*, TreeNodeIndex);

__device__ int enforceKeyStatus_device;
__global__ void resetEnforceKeyStatus() { enforceKeyStatus_device = static_cast<int>(ResolutionStatus::converged); }

template<class KeyType>
__global__ void enforceKeysKernel(const KeyType* forcedKeys,
                                  const KeyType* nodeKeys,
                                  const TreeNodeIndex* childOffsets,
                                  const TreeNodeIndex* parents,
                                  TreeNodeIndex* nodeOps)
{
    unsigned i       = blockIdx.x;
    auto statusBlock = enforceKeySingle(forcedKeys[i], nodeKeys, childOffsets, parents, nodeOps);
    atomicMax(&enforceKeyStatus_device, static_cast<int>(statusBlock));
}

template<class KeyType>
ResolutionStatus enforceKeysGpu(const KeyType* forcedKeys,
                                TreeNodeIndex numForcedKeys,
                                const KeyType* nodeKeys,
                                const TreeNodeIndex* childOffsets,
                                const TreeNodeIndex* parents,
                                TreeNodeIndex* nodeOps)
{
    resetEnforceKeyStatus<<<1, 1>>>();
    enforceKeysKernel<<<numForcedKeys, 1>>>(forcedKeys, nodeKeys, childOffsets, parents, nodeOps);

    int status;
    checkGpuErrors(cudaMemcpyFromSymbol(&status, enforceKeyStatus_device, sizeof(ResolutionStatus)));
    return static_cast<ResolutionStatus>(status);
}

template ResolutionStatus enforceKeysGpu(const uint32_t* forcedKeys,
                                         TreeNodeIndex numForcedKeys,
                                         const uint32_t* nodeKeys,
                                         const TreeNodeIndex* childOffsets,
                                         const TreeNodeIndex* parents,
                                         TreeNodeIndex* nodeOps);

template ResolutionStatus enforceKeysGpu(const uint64_t* forcedKeys,
                                         TreeNodeIndex numForcedKeys,
                                         const uint64_t* nodeKeys,
                                         const TreeNodeIndex* childOffsets,
                                         const TreeNodeIndex* parents,
                                         TreeNodeIndex* nodeOps);

} // namespace cstone