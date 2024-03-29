// SPDX-FileCopyrightText: 2017-2023 The Ginkgo authors
//
// SPDX-License-Identifier: BSD-3-Clause

template <typename ValueType, typename IndexType>
inline void simple_apply_kernel(
    const gko::batch::matrix::ell::batch_item<const ValueType, IndexType>& a,
    const gko::batch::multi_vector::batch_item<const ValueType>& b,
    const gko::batch::multi_vector::batch_item<ValueType>& c)
{
    for (int row = 0; row < c.num_rows; ++row) {
        for (int j = 0; j < c.num_rhs; ++j) {
            c.values[row * c.stride + j] = zero<ValueType>();
        }
        for (auto k = 0; k < a.num_stored_elems_per_row; ++k) {
            auto val = a.values[row + k * a.stride];
            auto col = a.col_idxs[row + k * a.stride];
            if (col != invalid_index<IndexType>()) {
                for (int j = 0; j < c.num_rhs; ++j) {
                    c.values[row * c.stride + j] +=
                        val * b.values[col * b.stride + j];
                }
            }
        }
    }
}


template <typename ValueType, typename IndexType>
inline void advanced_apply_kernel(
    const ValueType alpha,
    const gko::batch::matrix::ell::batch_item<const ValueType, IndexType>& a,
    const gko::batch::multi_vector::batch_item<const ValueType>& b,
    const ValueType beta,
    const gko::batch::multi_vector::batch_item<ValueType>& c)
{
    for (int row = 0; row < a.num_rows; ++row) {
        for (int j = 0; j < c.num_rhs; ++j) {
            c.values[row * c.stride + j] *= beta;
        }
        for (auto k = 0; k < a.num_stored_elems_per_row; ++k) {
            auto val = a.values[row + k * a.stride];
            auto col = a.col_idxs[row + k * a.stride];
            if (col != invalid_index<IndexType>()) {
                for (int j = 0; j < b.num_rhs; ++j) {
                    c.values[row * c.stride + j] +=
                        alpha * val * b.values[col * b.stride + j];
                }
            }
        }
    }
}
