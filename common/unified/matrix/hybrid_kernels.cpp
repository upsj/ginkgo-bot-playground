/*******************************<GINKGO LICENSE>******************************
Copyright (c) 2017-2022, the Ginkgo authors
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

#include "core/matrix/hybrid_kernels.hpp"


#include "common/unified/base/kernel_launch.hpp"
#include "core/components/prefix_sum_kernels.hpp"


namespace gko {
namespace kernels {
namespace GKO_DEVICE_NAMESPACE {
/**
 * @brief The Hybrid matrix format namespace.
 *
 * @ingroup hybrid
 */
namespace hybrid {


void compute_coo_row_ptrs(std::shared_ptr<const DefaultExecutor> exec,
                          const Array<size_type>& row_nnz, size_type ell_lim,
                          int64* coo_row_ptrs)
{
    run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto row_nnz, auto ell_lim, auto coo_row_ptrs) {
            coo_row_ptrs[i] = max(int64{}, static_cast<int64>(row_nnz[i]) -
                                               static_cast<int64>(ell_lim));
        },
        row_nnz.get_num_elems(), row_nnz, ell_lim, coo_row_ptrs);
    components::prefix_sum(exec, coo_row_ptrs, row_nnz.get_num_elems() + 1);
}


void compute_row_nnz(std::shared_ptr<const DefaultExecutor> exec,
                     const Array<int64>& row_ptrs, size_type* row_nnzs)
{
    run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto row_ptrs, auto row_nnzs) {
            row_nnzs[i] = row_ptrs[i + 1] - row_ptrs[i];
        },
        row_ptrs.get_num_elems() - 1, row_ptrs, row_nnzs);
}


template <typename ValueType, typename IndexType>
void fill_in_matrix_data(std::shared_ptr<const DefaultExecutor> exec,
                         const device_matrix_data<ValueType, IndexType>& data,
                         const int64* row_ptrs, const int64* coo_row_ptrs,
                         matrix::Hybrid<ValueType, IndexType>* result)
{
    using device_value_type = device_type<ValueType>;
    run_kernel(
        exec,
        [] GKO_KERNEL(auto row, auto row_ptrs, auto vals, auto rows, auto cols,
                      auto ell_stride, auto ell_max_nnz, auto ell_cols,
                      auto ell_vals, auto coo_row_ptrs, auto coo_row_idxs,
                      auto coo_col_idxs, auto coo_vals) {
            const auto row_begin = row_ptrs[row];
            const auto row_size = row_ptrs[row + 1] - row_begin;
            for (int64 i = 0; i < ell_max_nnz; i++) {
                const auto out_idx = row + ell_stride * i;
                const auto in_idx = i + row_begin;
                const bool use = i < row_size;
                ell_cols[out_idx] = use ? cols[in_idx] : 0;
                ell_vals[out_idx] =
                    use ? vals[in_idx] : zero<device_value_type>();
            }
            const auto coo_begin = coo_row_ptrs[row];
            for (int64 i = ell_max_nnz; i < row_size; i++) {
                const auto in_idx = i + row_begin;
                const auto out_idx =
                    coo_begin + i - static_cast<int64>(ell_max_nnz);
                coo_row_idxs[out_idx] = row;
                coo_col_idxs[out_idx] = cols[in_idx];
                coo_vals[out_idx] = vals[in_idx];
            }
        },
        data.get_size()[0], row_ptrs, data.get_const_values(),
        data.get_const_row_idxs(), data.get_const_col_idxs(),
        result->get_ell_stride(), result->get_ell_num_stored_elements_per_row(),
        result->get_ell_col_idxs(), result->get_ell_values(), coo_row_ptrs,
        result->get_coo_row_idxs(), result->get_coo_col_idxs(),
        result->get_coo_values());
}

GKO_INSTANTIATE_FOR_EACH_VALUE_AND_INDEX_TYPE(
    GKO_DECLARE_HYBRID_FILL_IN_MATRIX_DATA_KERNEL);


template <typename ValueType, typename IndexType>
void convert_to_csr(std::shared_ptr<const DefaultExecutor> exec,
                    const matrix::Hybrid<ValueType, IndexType>* source,
                    const IndexType* ell_row_ptrs,
                    const IndexType* coo_row_ptrs,
                    matrix::Csr<ValueType, IndexType>* result)
{
    const auto ell = source->get_ell();
    const auto coo = source->get_coo();
    // ELL is stored in column-major, so we swap row and column parameters
    run_kernel(
        exec,
        [] GKO_KERNEL(auto ell_col, auto row, auto ell_stride, auto in_cols,
                      auto in_vals, auto ell_row_ptrs, auto coo_row_ptrs,
                      auto out_cols, auto out_vals) {
            const auto ell_idx = ell_col * ell_stride + row;
            const auto out_row_begin = ell_row_ptrs[row] + coo_row_ptrs[row];
            const auto ell_row_size = ell_row_ptrs[row + 1] - ell_row_ptrs[row];
            if (ell_col < ell_row_size) {
                const auto out_idx = out_row_begin + ell_col;
                out_cols[out_idx] = in_cols[ell_idx];
                out_vals[out_idx] = in_vals[ell_idx];
            }
        },
        dim<2>{ell->get_num_stored_elements_per_row(), ell->get_size()[0]},
        static_cast<int64>(ell->get_stride()), ell->get_const_col_idxs(),
        ell->get_const_values(), ell_row_ptrs, coo_row_ptrs,
        result->get_col_idxs(), result->get_values());
    run_kernel(
        exec,
        [] GKO_KERNEL(auto idx, auto ell_row_ptrs, auto coo_row_ptrs,
                      auto out_row_ptrs) {
            out_row_ptrs[idx] = ell_row_ptrs[idx] + coo_row_ptrs[idx];
        },
        source->get_size()[0] + 1, ell_row_ptrs, coo_row_ptrs,
        result->get_row_ptrs());
    run_kernel(
        exec,
        [] GKO_KERNEL(auto idx, auto in_rows, auto in_cols, auto in_vals,
                      auto ell_row_ptrs, auto coo_row_ptrs, auto out_cols,
                      auto out_vals) {
            const auto row = in_rows[idx];
            const auto col = in_cols[idx];
            const auto val = in_vals[idx];
            const auto coo_row_begin = coo_row_ptrs[row];
            const auto coo_local_pos = idx - coo_row_begin;
            // compute row_ptrs[row] + ell_row_size[row]
            const auto out_row_begin = ell_row_ptrs[row + 1] + coo_row_begin;
            const auto out_idx = out_row_begin + coo_local_pos;
            out_cols[out_idx] = col;
            out_vals[out_idx] = val;
        },
        coo->get_num_stored_elements(), coo->get_const_row_idxs(),
        coo->get_const_col_idxs(), coo->get_const_values(), ell_row_ptrs,
        coo_row_ptrs, result->get_col_idxs(), result->get_values());
}

GKO_INSTANTIATE_FOR_EACH_VALUE_AND_INDEX_TYPE(
    GKO_DECLARE_HYBRID_CONVERT_TO_CSR_KERNEL);


}  // namespace hybrid
}  // namespace GKO_DEVICE_NAMESPACE
}  // namespace kernels
}  // namespace gko