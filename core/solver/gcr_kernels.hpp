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

#ifndef GKO_CORE_SOLVER_GCR_KERNELS_HPP_
#define GKO_CORE_SOLVER_GCR_KERNELS_HPP_


#include <ginkgo/core/base/array.hpp>
#include <ginkgo/core/base/math.hpp>
#include <ginkgo/core/base/types.hpp>
#include <ginkgo/core/matrix/dense.hpp>
#include <ginkgo/core/stop/stopping_status.hpp>


#include "core/base/kernel_declaration.hpp"


namespace gko {
namespace kernels {
namespace gcr {


#define GKO_DECLARE_GCR_INITIALIZE_KERNEL(_type)                 \
    void initialize(std::shared_ptr<const DefaultExecutor> exec, \
                    const matrix::Dense<_type>* b,               \
                    matrix::Dense<_type>* residual,              \
                    stopping_status* stop_status)


#define GKO_DECLARE_GCR_RESTART_KERNEL(_type)                 \
    void restart(std::shared_ptr<const DefaultExecutor> exec, \
                 const matrix::Dense<_type>* residual,        \
                 const matrix::Dense<_type>* A_residual,      \
                 matrix::Dense<_type>* p_bases,               \
                 matrix::Dense<_type>* Ap_bases, size_type* final_iter_nums)


#define GKO_DECLARE_GCR_STEP_1_KERNEL(_type)                                   \
    void step_1(std::shared_ptr<const DefaultExecutor> exec,                   \
                matrix::Dense<_type>* x, matrix::Dense<_type>* residual,       \
                const matrix::Dense<_type>* p, const matrix::Dense<_type>* Ap, \
                const matrix::Dense<remove_complex<_type>>* Ap_norm,           \
                const matrix::Dense<_type>* rAp,                               \
                const stopping_status* stop_status)


#define GKO_DECLARE_ALL_AS_TEMPLATES              \
    template <typename ValueType>                 \
    GKO_DECLARE_GCR_INITIALIZE_KERNEL(ValueType); \
    template <typename ValueType>                 \
    GKO_DECLARE_GCR_RESTART_KERNEL(ValueType);    \
    template <typename ValueType>                 \
    GKO_DECLARE_GCR_STEP_1_KERNEL(ValueType)


}  // namespace gcr


GKO_DECLARE_FOR_ALL_EXECUTOR_NAMESPACES(gcr, GKO_DECLARE_ALL_AS_TEMPLATES);


#undef GKO_DECLARE_ALL_AS_TEMPLATES


}  // namespace kernels
}  // namespace gko


#endif  // GKO_CORE_SOLVER_GCR_KERNELS_HPP_