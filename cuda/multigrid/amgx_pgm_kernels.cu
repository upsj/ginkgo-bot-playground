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

#include "core/multigrid/amgx_pgm_kernels.hpp"


#include <memory>


#include <cuda.h>
#include <cusparse.h>
#include <thrust/tuple.h>


#include <ginkgo/core/base/exception_helpers.hpp>
#include <ginkgo/core/base/math.hpp>
#include <ginkgo/core/multigrid/amgx_pgm.hpp>


#include "core/components/fill_array.hpp"
#include "core/components/prefix_sum.hpp"
#include "core/matrix/csr_builder.hpp"
#include "core/matrix/csr_kernels.hpp"
#include "cuda/base/cusparse_bindings.hpp"
#include "cuda/base/math.hpp"
#include "cuda/base/types.hpp"
#include "cuda/components/atomic.cuh"
#include "cuda/components/reduction.cuh"
#include "cuda/components/thread_ids.cuh"


namespace gko {
namespace kernels {
namespace cudaa {
/**
 * @brief The AMGX_PGM solver namespace.
 *
 * @ingroup amgx_pgm
 */
namespace amgx_pgm {


constexpr int default_block_size = 512;


#include "common/multigrid/amgx_pgm_kernels.hpp.inc"


template <typename IndexType>
void match_edge(std::shared_ptr<const CudaExecutor> exec,
                const Array<IndexType> &strongest_neighbor,
                Array<IndexType> &agg)
{
    const auto num = agg.get_num_elems();
    const dim3 grid(ceildiv(num, default_block_size));
    kernel::match_edge_kernel<<<grid, default_block_size>>>(
        num, strongest_neighbor.get_const_data(), agg.get_data());
}

GKO_INSTANTIATE_FOR_EACH_INDEX_TYPE(GKO_DECLARE_AMGX_PGM_MATCH_EDGE_KERNEL);


template <typename IndexType>
void count_unagg(std::shared_ptr<const CudaExecutor> exec,
                 const Array<IndexType> &agg, IndexType *num_unagg)
{
    Array<IndexType> active_agg(exec, agg.get_num_elems());
    const dim3 grid(ceildiv(active_agg.get_num_elems(), default_block_size));
    kernel::activate_kernel<<<grid, default_block_size>>>(
        active_agg.get_num_elems(), agg.get_const_data(),
        active_agg.get_data());
    *num_unagg = reduce_add_array(exec, active_agg.get_num_elems(),
                                  active_agg.get_const_data());
}

GKO_INSTANTIATE_FOR_EACH_INDEX_TYPE(GKO_DECLARE_AMGX_PGM_COUNT_UNAGG_KERNEL);


template <typename IndexType>
void renumber(std::shared_ptr<const CudaExecutor> exec, Array<IndexType> &agg,
              IndexType *num_agg)
{
    const auto num = agg.get_num_elems();
    Array<IndexType> agg_map(exec, num + 1);
    const dim3 grid(ceildiv(num, default_block_size));
    kernel::fill_agg_kernel<<<grid, default_block_size>>>(
        num, agg.get_const_data(), agg_map.get_data());
    components::prefix_sum(exec, agg_map.get_data(), agg_map.get_num_elems());
    kernel::renumber_kernel<<<grid, default_block_size>>>(
        num, agg_map.get_const_data(), agg.get_data());
    *num_agg = exec->copy_val_to_host(agg_map.get_const_data() + num);
}

GKO_INSTANTIATE_FOR_EACH_INDEX_TYPE(GKO_DECLARE_AMGX_PGM_RENUMBER_KERNEL);


template <typename ValueType, typename IndexType>
void find_strongest_neighbor(
    std::shared_ptr<const CudaExecutor> exec,
    const matrix::Csr<ValueType, IndexType> *weight_mtx,
    const matrix::Diagonal<ValueType> *diag, Array<IndexType> &agg,
    Array<IndexType> &strongest_neighbor)
{
    const auto num = agg.get_num_elems();
    const dim3 grid(ceildiv(num, default_block_size));
    kernel::find_strongest_neighbor_kernel<<<grid, default_block_size>>>(
        num, weight_mtx->get_const_row_ptrs(), weight_mtx->get_const_col_idxs(),
        weight_mtx->get_const_values(), diag->get_const_values(),
        agg.get_data(), strongest_neighbor.get_data());
}

GKO_INSTANTIATE_FOR_EACH_NON_COMPLEX_VALUE_AND_INDEX_TYPE(
    GKO_DECLARE_AMGX_PGM_FIND_STRONGEST_NEIGHBOR);

template <typename ValueType, typename IndexType>
void assign_to_exist_agg(std::shared_ptr<const CudaExecutor> exec,
                         const matrix::Csr<ValueType, IndexType> *weight_mtx,
                         const matrix::Diagonal<ValueType> *diag,
                         Array<IndexType> &agg,
                         Array<IndexType> &intermediate_agg)
{
    const auto num = agg.get_num_elems();
    const dim3 grid(ceildiv(num, default_block_size));
    if (intermediate_agg.get_num_elems() > 0) {
        // determinstic kernel
        kernel::assign_to_exist_agg_kernel<<<grid, default_block_size>>>(
            num, weight_mtx->get_const_row_ptrs(),
            weight_mtx->get_const_col_idxs(), weight_mtx->get_const_values(),
            diag->get_const_values(), agg.get_const_data(),
            intermediate_agg.get_data());
        // Copy the intermediate_agg to agg
        agg = intermediate_agg;
    } else {
        // undeterminstic kernel
        kernel::assign_to_exist_agg_kernel<<<grid, default_block_size>>>(
            num, weight_mtx->get_const_row_ptrs(),
            weight_mtx->get_const_col_idxs(), weight_mtx->get_const_values(),
            diag->get_const_values(), agg.get_data());
    }
}

GKO_INSTANTIATE_FOR_EACH_NON_COMPLEX_VALUE_AND_INDEX_TYPE(
    GKO_DECLARE_AMGX_PGM_ASSIGN_TO_EXIST_AGG);


}  // namespace amgx_pgm
}  // namespace cudaa
}  // namespace kernels
}  // namespace gko
