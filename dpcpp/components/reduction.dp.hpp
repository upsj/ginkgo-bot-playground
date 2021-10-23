/*******************************<GINKGO LICENSE>******************************
Copyright (c) 2017-2021, the Ginkgo authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
******************************<GINKGO LICENSE>*******************************/

#ifndef GKO_DPCPP_COMPONENTS_REDUCTION_DP_HPP_
#define GKO_DPCPP_COMPONENTS_REDUCTION_DP_HPP_


#include <type_traits>


#include <CL/sycl.hpp>


#include <ginkgo/core/base/array.hpp>
#include <ginkgo/core/base/executor.hpp>
#include <ginkgo/core/synthesizer/containers.hpp>


#include "core/base/types.hpp"
#include "core/synthesizer/implementation_selection.hpp"
#include "dpcpp/base/config.hpp"
#include "dpcpp/base/dim3.dp.hpp"
#include "dpcpp/base/dpct.hpp"
#include "dpcpp/base/helper.hpp"
#include "dpcpp/components/cooperative_groups.dp.hpp"
#include "dpcpp/components/thread_ids.dp.hpp"
#include "dpcpp/components/uninitialized_array.hpp"


namespace gko {
namespace kernels {
namespace dpcpp {


constexpr int default_block_size = 256;
using KCFG_1D = ConfigSet<11, 7>;
constexpr auto kcfg_1d_list =
    syn::value_list<std::uint32_t, KCFG_1D::encode(512, 64),
                    KCFG_1D::encode(512, 32), KCFG_1D::encode(512, 16),
                    KCFG_1D::encode(256, 32), KCFG_1D::encode(256, 16),
                    KCFG_1D::encode(256, 8)>();
constexpr auto kcfg_1d_array = as_array(kcfg_1d_list);

/**
 * @internal
 *
 * Computes a reduction using the binary operation `reduce_op` on a group
 * `group`. Each thread contributes with one element `local_data`. The local
 * thread element is always passed as the first parameter to the `reduce_op`.
 * The function returns the result of the reduction on all threads.
 *
 * @note The function is guaranteed to return the correct value on all threads
 *       only if `reduce_op` is commutative (in addition to being associative).
 *       Otherwise, the correct value is returned only to the thread with
 *       subgroup index 0.
 */
template <
    typename Group, typename ValueType, typename Operator,
    typename = std::enable_if_t<group::is_communicator_group<Group>::value>>
__dpct_inline__ ValueType reduce(const Group& group, ValueType local_data,
                                 Operator reduce_op = Operator{})
{
#pragma unroll
    for (int32 bitmask = 1; bitmask < group.size(); bitmask <<= 1) {
        const auto remote_data = group.shfl_xor(local_data, bitmask);
        local_data = reduce_op(local_data, remote_data);
    }
    return local_data;
}


/**
 * @internal
 *
 * Returns the index of the thread that has the element with the largest
 * magnitude among all the threads in the group.
 * Only the values from threads which set `is_pivoted` to `false` will be
 * considered.
 */
template <
    typename Group, typename ValueType,
    typename = std::enable_if_t<group::is_communicator_group<Group>::value>>
__dpct_inline__ int choose_pivot(const Group& group, ValueType local_data,
                                 bool is_pivoted)
{
    using real = remove_complex<ValueType>;
    real lmag = is_pivoted ? -one<real>() : abs(local_data);
    const auto pivot =
        reduce(group, group.thread_rank(), [&](int lidx, int ridx) {
            const auto rmag = group.shfl(lmag, ridx);
            if (rmag > lmag) {
                lmag = rmag;
                lidx = ridx;
            }
            return lidx;
        });
    // pivot operator not commutative, make sure everyone has the same pivot
    return group.shfl(pivot, 0);
}


/**
 * @internal
 *
 * Computes a reduction using the binary operation `reduce_op` on entire block.
 * The data for the reduction is taken from the `data` array which has to be of
 * size `block_size` and accessible from all threads. The `data` array is also
 * used as work space (so its content will be destroyed in the process), as well
 * as to store the return value - which is stored in the 0-th position of the
 * array.
 */
template <
    unsigned int sg_size = config::warp_size, typename Group,
    typename ValueType, typename Operator,
    typename = std::enable_if_t<group::is_synchronizable_group<Group>::value>>
void reduce(const Group& __restrict__ group, ValueType* __restrict__ data,
            Operator reduce_op = Operator{})
{
    const auto local_id = group.thread_rank();

    for (int k = group.size() / 2; k >= sg_size; k /= 2) {
        group.sync();
        if (local_id < k) {
            data[local_id] = reduce_op(data[local_id], data[local_id + k]);
        }
    }

    const auto warp = group::tiled_partition<sg_size>(group);
    const auto warp_id = group.thread_rank() / warp.size();
    if (warp_id > 0) {
        return;
    }
    auto result = ::gko::kernels::dpcpp::reduce(warp, data[warp.thread_rank()],
                                                reduce_op);
    if (warp.thread_rank() == 0) {
        data[0] = result;
    }
}


/**
 * @internal
 *
 * Computes a reduction using the binary operation `reduce_op` on an array
 * `source` of any size. Has to be called a second time on `result` to reduce
 * an array larger than `block_size`.
 */
template <unsigned int sg_size = config::warp_size, typename Operator,
          typename ValueType>
void reduce_array(size_type size, const ValueType* __restrict__ source,
                  ValueType* __restrict__ result, sycl::nd_item<3> item_ct1,
                  Operator reduce_op = Operator{})
{
    const auto tidx = thread::get_thread_id_flat(item_ct1);
    auto thread_result = zero<ValueType>();
    for (auto i = tidx; i < size;
         i += item_ct1.get_local_range().get(2) * item_ct1.get_group_range(2)) {
        thread_result = reduce_op(thread_result, source[i]);
    }
    result[item_ct1.get_local_id(2)] = thread_result;

    group::this_thread_block(item_ct1).sync();

    // Stores the result of the reduction inside `result[0]`
    reduce<sg_size>(group::this_thread_block(item_ct1), result, reduce_op);
}


/**
 * @internal
 *
 * Computes a reduction using the add operation (+) on an array
 * `source` of any size. Has to be called a second time on `result` to reduce
 * an array larger than `block_size`.
 */
template <std::uint32_t cfg, typename ValueType>
void reduce_add_array(
    size_type size, const ValueType* __restrict__ source,
    ValueType* __restrict__ result, sycl::nd_item<3> item_ct1,
    UninitializedArray<ValueType, KCFG_1D::decode<0>(cfg)>& block_sum)
{
    reduce_array<KCFG_1D::decode<1>(cfg)>(
        size, source, static_cast<ValueType*>(block_sum), item_ct1,
        [](const ValueType& x, const ValueType& y) { return x + y; });

    if (item_ct1.get_local_id(2) == 0) {
        result[item_ct1.get_group(2)] = block_sum[0];
    }
}

template <std::uint32_t cfg = KCFG_1D::encode(256, 16), typename ValueType>
void reduce_add_array(dim3 grid, dim3 block, size_type dynamic_shared_memory,
                      sycl::queue* queue, size_type size,
                      const ValueType* source, ValueType* result)
{
    queue->submit([&](sycl::handler& cgh) {
        sycl::accessor<UninitializedArray<ValueType, KCFG_1D::decode<0>(cfg)>,
                       0, sycl::access::mode::read_write,
                       sycl::access::target::local>
            block_sum_acc_ct1(cgh);

        cgh.parallel_for(
            sycl_nd_range(grid, block), [=](sycl::nd_item<3> item_ct1) {
                reduce_add_array<cfg>(size, source, result, item_ct1,
                                      *block_sum_acc_ct1.get_pointer());
            });
    });
}

GKO_ENABLE_IMPLEMENTATION_CONFIG_SELECTION(reduce_add_array_config,
                                           reduce_add_array);

GKO_ENABLE_DEFAULT_CONFIG_CALL(reduce_add_array_call, reduce_add_array_config,
                               kcfg_1d_list);


/**
 * Compute a reduction using add operation (+).
 *
 * @param exec  Executor associated to the array
 * @param size  size of the array
 * @param source  the pointer of the array
 *
 * @return the reduction result
 */
template <typename ValueType>
ValueType reduce_add_array(std::shared_ptr<const DpcppExecutor> exec,
                           size_type size, const ValueType* source)
{
    auto block_results_val = source;
    size_type grid_dim = size;
    auto block_results = Array<ValueType>(exec);
    ValueType answer = zero<ValueType>();
    auto queue = exec->get_queue();
    constexpr auto kcfg_1d_array = as_array(kcfg_1d_list);
    const std::uint32_t cfg =
        get_first_cfg(kcfg_1d_array, [&queue](std::uint32_t cfg) {
            return validate(queue, KCFG_1D::decode<0>(cfg),
                            KCFG_1D::decode<1>(cfg));
        });
    const auto wg_size = KCFG_1D::decode<0>(cfg);
    const auto sg_size = KCFG_1D::decode<1>(cfg);

    if (size > wg_size) {
        const auto n = ceildiv(size, wg_size);
        grid_dim = (n <= wg_size) ? n : wg_size;

        block_results.resize_and_reset(grid_dim);

        reduce_add_array_call(cfg, grid_dim, wg_size, 0, exec->get_queue(),
                              size, source, block_results.get_data());

        block_results_val = block_results.get_const_data();
    }

    auto d_result = Array<ValueType>(exec, 1);

    reduce_add_array_call(cfg, 1, wg_size, 0, exec->get_queue(), grid_dim,
                          block_results_val, d_result.get_data());
    answer = exec->copy_val_to_host(d_result.get_const_data());
    return answer;
}


}  // namespace dpcpp
}  // namespace kernels
}  // namespace gko


#endif  // GKO_DPCPP_COMPONENTS_REDUCTION_DP_HPP_