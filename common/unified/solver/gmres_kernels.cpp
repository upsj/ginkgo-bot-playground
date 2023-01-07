/*******************************<GINKGO LICENSE>******************************
Copyright (c) 2017-2023, the Ginkgo authors
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

#include "core/solver/gmres_kernels.hpp"


#include <ginkgo/core/base/math.hpp>
#include <ginkgo/core/stop/stopping_status.hpp>


#include "common/unified/base/kernel_launch.hpp"


namespace gko {
namespace kernels {
namespace GKO_DEVICE_NAMESPACE {
/**
 * @brief The GMRES solver namespace.
 *
 * @ingroup gmres
 */
namespace gmres {


template <typename ValueType>
void restart(std::shared_ptr<const DefaultExecutor> exec,
             const matrix::Dense<ValueType>* residual,
             const matrix::Dense<remove_complex<ValueType>>* residual_norm,
             matrix::Dense<ValueType>* residual_norm_collection,
             matrix::Dense<ValueType>* krylov_bases, size_type* final_iter_nums)
{
    if (residual->get_size()[0] == 0) {
        run_kernel(
            exec,
            [] GKO_KERNEL(auto j, auto residual_norm,
                          auto residual_norm_collection, auto final_iter_nums) {
                residual_norm_collection(0, j) = residual_norm(0, j);
                final_iter_nums[j] = 0;
            },
            residual->get_size()[1], residual_norm, residual_norm_collection,
            final_iter_nums);
    } else {
        run_kernel(
            exec,
            [] GKO_KERNEL(auto i, auto j, auto residual, auto residual_norm,
                          auto residual_norm_collection, auto krylov_bases,
                          auto final_iter_nums) {
                if (i == 0) {
                    residual_norm_collection(0, j) = residual_norm(0, j);
                    final_iter_nums[j] = 0;
                }
                krylov_bases(i, j) = residual(i, j) / residual_norm(0, j);
            },
            residual->get_size(), residual, residual_norm,
            residual_norm_collection, krylov_bases, final_iter_nums);
    }
}

GKO_INSTANTIATE_FOR_EACH_VALUE_TYPE(GKO_DECLARE_GMRES_RESTART_KERNEL);


template <typename ValueType>
void multi_axpy(std::shared_ptr<const DefaultExecutor> exec,
                const matrix::Dense<ValueType>* krylov_bases,
                const matrix::Dense<ValueType>* y,
                matrix::Dense<ValueType>* before_preconditioner,
                const size_type* final_iter_nums, stopping_status* stop_status)
{
    run_kernel(
        exec,
        [] GKO_KERNEL(auto row, auto col, auto bases, auto y, auto out,
                      auto sizes, auto stop, auto num_rows) {
            if (stop[col].is_finalized()) {
                return;
            }
            auto value = zero(out(row, col));
            for (int i = 0; i < sizes[col]; i++) {
                value += bases(row + i * num_rows, col) * y(i, col);
            }
            out(row, col) = value;
        },
        before_preconditioner->get_size(), krylov_bases, y,
        before_preconditioner, final_iter_nums, stop_status,
        before_preconditioner->get_size()[0]);
    run_kernel(
        exec,
        [] GKO_KERNEL(auto col, auto stop) {
            if (!stop[col].is_finalized()) {
                stop[col].finalize();
            }
        },
        before_preconditioner->get_size()[1], stop_status);
}

GKO_INSTANTIATE_FOR_EACH_VALUE_TYPE(GKO_DECLARE_GMRES_MULTI_AXPY_KERNEL);


}  // namespace gmres
}  // namespace GKO_DEVICE_NAMESPACE
}  // namespace kernels
}  // namespace gko