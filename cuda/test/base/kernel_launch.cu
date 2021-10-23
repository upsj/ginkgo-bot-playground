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

#include "common/unified/base/kernel_launch.hpp"


#include <memory>
#include <type_traits>


#include <gtest/gtest.h>


#include <ginkgo/core/base/array.hpp>
#include <ginkgo/core/base/dim.hpp>
#include <ginkgo/core/base/types.hpp>
#include <ginkgo/core/matrix/dense.hpp>


#include "common/unified/base/kernel_launch_reduction.hpp"
#include "common/unified/base/kernel_launch_solver.hpp"
#include "core/test/utils.hpp"


namespace {


using gko::dim;
using gko::int64;
using gko::size_type;
using std::is_same;


class KernelLaunch : public ::testing::Test {
protected:
    KernelLaunch()
        : exec(gko::CudaExecutor::create(0, gko::ReferenceExecutor::create(),
                                         false, gko::allocation_mode::device)),
          zero_array(exec->get_master(), 16),
          iota_array(exec->get_master(), 16),
          iota_transp_array(exec->get_master(), 16),
          iota_dense(gko::matrix::Dense<>::create(exec, dim<2>{4, 4})),
          zero_dense(gko::matrix::Dense<>::create(exec, dim<2>{4, 4}, 6)),
          zero_dense2(gko::matrix::Dense<>::create(exec, dim<2>{4, 4}, 5)),
          vec_dense(gko::matrix::Dense<>::create(exec, dim<2>{1, 4}))
    {
        auto ref_iota_dense =
            gko::matrix::Dense<>::create(exec->get_master(), dim<2>{4, 4});
        for (int i = 0; i < 16; i++) {
            zero_array.get_data()[i] = 0;
            iota_array.get_data()[i] = i;
            iota_transp_array.get_data()[i] = (i % 4 * 4) + i / 4;
            ref_iota_dense->at(i / 4, i % 4) = i;
        }
        zero_dense->fill(0.0);
        zero_dense2->fill(0.0);
        iota_dense->copy_from(ref_iota_dense.get());
        zero_array.set_executor(exec);
        iota_array.set_executor(exec);
        iota_transp_array.set_executor(exec);
    }

    std::shared_ptr<gko::CudaExecutor> exec;
    gko::Array<int> zero_array;
    gko::Array<int> iota_array;
    gko::Array<int> iota_transp_array;
    std::unique_ptr<gko::matrix::Dense<>> iota_dense;
    std::unique_ptr<gko::matrix::Dense<>> zero_dense;
    std::unique_ptr<gko::matrix::Dense<>> zero_dense2;
    std::unique_ptr<gko::matrix::Dense<>> vec_dense;
};


// nvcc doesn't like device lambdas declared in complex classes, move it out
void run1d(std::shared_ptr<gko::CudaExecutor> exec, size_type dim, int* data)
{
    gko::kernels::cuda::run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto d) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(d), int*>::value, "type");
            d[i] = i;
        },
        dim, data);
}

TEST_F(KernelLaunch, Runs1D)
{
    run1d(exec, zero_array.get_num_elems(), zero_array.get_data());

    GKO_ASSERT_ARRAY_EQ(zero_array, iota_array);
}


void run1d(std::shared_ptr<gko::CudaExecutor> exec, gko::Array<int>& data)
{
    gko::kernels::cuda::run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto d, auto d_ptr) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(d), int*>::value, "type");
            static_assert(is_same<decltype(d_ptr), const int*>::value, "type");
            if (d == d_ptr) {
                d[i] = i;
            } else {
                d[i] = 0;
            }
        },
        data.get_num_elems(), data, data.get_const_data());
}

TEST_F(KernelLaunch, Runs1DArray)
{
    run1d(exec, zero_array);

    GKO_ASSERT_ARRAY_EQ(zero_array, iota_array);
}


void run1d(std::shared_ptr<gko::CudaExecutor> exec, gko::matrix::Dense<>* m)
{
    gko::kernels::cuda::run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto d, auto d2, auto d_ptr) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(d(0, 0)), double&>::value, "type");
            static_assert(is_same<decltype(d2(0, 0)), const double&>::value,
                          "type");
            static_assert(is_same<decltype(d_ptr), const double*>::value,
                          "type");
            bool pointers_correct = d.data == d_ptr && d2.data == d_ptr;
            bool strides_correct = d.stride == 5 && d2.stride == 5;
            bool accessors_2d_correct =
                &d(0, 0) == d_ptr && &d(1, 0) == d_ptr + d.stride &&
                &d2(0, 0) == d_ptr && &d2(1, 0) == d_ptr + d.stride;
            bool accessors_1d_correct = &d[0] == d_ptr && &d2[0] == d_ptr;
            if (pointers_correct && strides_correct && accessors_2d_correct &&
                accessors_1d_correct) {
                d(i / 4, i % 4) = i;
            } else {
                d(i / 4, i % 4) = 0;
            }
        },
        16, m, static_cast<const gko::matrix::Dense<>*>(m),
        m->get_const_values());
}

TEST_F(KernelLaunch, Runs1DDense)
{
    run1d(exec, zero_dense2.get());

    GKO_ASSERT_MTX_NEAR(zero_dense2, iota_dense, 0.0);
}


void run2d(std::shared_ptr<gko::CudaExecutor> exec, int* data)
{
    gko::kernels::cuda::run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto j, auto d) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(j), int64>::value, "index");
            static_assert(is_same<decltype(d), int*>::value, "type");
            d[i + 4 * j] = 4 * i + j;
        },
        dim<2>{4, 4}, data);
}

TEST_F(KernelLaunch, Runs2D)
{
    run2d(exec, zero_array.get_data());

    GKO_ASSERT_ARRAY_EQ(zero_array, iota_transp_array);
}


void run2d(std::shared_ptr<gko::CudaExecutor> exec, gko::Array<int>& data)
{
    gko::kernels::cuda::run_kernel(
        exec,
        [] GKO_KERNEL(auto i, auto j, auto d, auto d_ptr) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(j), int64>::value, "index");
            static_assert(is_same<decltype(d), int*>::value, "type");
            static_assert(is_same<decltype(d_ptr), const int*>::value, "type");
            if (d == d_ptr) {
                d[i + 4 * j] = 4 * i + j;
            } else {
                d[i + 4 * j] = 0;
            }
        },
        dim<2>{4, 4}, data, data.get_const_data());
}

TEST_F(KernelLaunch, Runs2DArray)
{
    run2d(exec, zero_array);

    GKO_ASSERT_ARRAY_EQ(zero_array, iota_transp_array);
}


void run2d(std::shared_ptr<gko::CudaExecutor> exec, gko::matrix::Dense<>* m1,
           gko::matrix::Dense<>* m2, gko::matrix::Dense<>* m3)
{
    gko::kernels::cuda::run_kernel_solver(
        exec,
        [] GKO_KERNEL(auto i, auto j, auto d, auto d2, auto d_ptr, auto d3,
                      auto d4, auto d2_ptr, auto d3_ptr) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(d(0, 0)), double&>::value, "type");
            static_assert(is_same<decltype(d2(0, 0)), const double&>::value,
                          "type");
            static_assert(is_same<decltype(d_ptr), const double*>::value,
                          "type");
            static_assert(is_same<decltype(d3(0, 0)), double&>::value, "type");
            static_assert(is_same<decltype(d4), double*>::value, "type");
            static_assert(is_same<decltype(d2_ptr), double*>::value, "type");
            static_assert(is_same<decltype(d3_ptr), double*>::value, "type");
            bool pointers_correct = d.data == d_ptr && d2.data == d_ptr &&
                                    d3.data == d2_ptr && d4 == d3_ptr;
            bool strides_correct =
                d.stride == 5 && d2.stride == 5 && d3.stride == 6;
            bool accessors_2d_correct =
                &d(0, 0) == d_ptr && &d(1, 0) == d_ptr + d.stride &&
                &d2(0, 0) == d_ptr && &d2(1, 0) == d_ptr + d2.stride &&
                &d3(0, 0) == d2_ptr && &d3(1, 0) == d2_ptr + d3.stride;
            bool accessors_1d_correct =
                &d[0] == d_ptr && &d2[0] == d_ptr && &d3[0] == d2_ptr;
            if (pointers_correct && strides_correct && accessors_2d_correct &&
                accessors_1d_correct) {
                d(i, j) = 4 * i + j;
            } else {
                d(i, j) = 0;
            }
        },
        dim<2>{4, 4}, m2->get_stride(), m1,
        static_cast<const gko::matrix::Dense<>*>(m1), m1->get_const_values(),
        gko::kernels::cuda::default_stride(m2),
        gko::kernels::cuda::row_vector(m3), m2->get_values(), m3->get_values());
}

TEST_F(KernelLaunch, Runs2DDense)
{
    run2d(exec, zero_dense2.get(), zero_dense.get(), vec_dense.get());

    GKO_ASSERT_MTX_NEAR(zero_dense2, iota_dense, 0.0);
}


void run1d_reduction(std::shared_ptr<gko::CudaExecutor> exec)
{
    gko::Array<int64> output{exec, 1};

    gko::kernels::cuda::run_kernel_reduction(
        exec,
        [] GKO_KERNEL(auto i, auto a) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(a), int64*>::value, "value");
            return i + 1;
        },
        [] GKO_KERNEL(auto i, auto j) { return i + j; },
        [] GKO_KERNEL(auto j) { return j * 2; }, int64{}, output.get_data(),
        size_type{100000}, output);

    // 2 * sum i=0...99999 (i+1)
    ASSERT_EQ(exec->copy_val_to_host(output.get_const_data()), 10000100000LL);

    gko::kernels::cuda::run_kernel_reduction(
        exec,
        [] GKO_KERNEL(auto i, auto a) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(a), int64*>::value, "value");
            return i + 1;
        },
        [] GKO_KERNEL(auto i, auto j) {
            static_assert(is_same<decltype(i), int64>::value, "a");
            static_assert(is_same<decltype(i), int64>::value, "b");
            return i + j;
        },
        [] GKO_KERNEL(auto j) {
            static_assert(is_same<decltype(j), int64>::value, "value");
            return j * 2;
        },
        int64{}, output.get_data(), size_type{100}, output);

    // 2 * sum i=0...99 (i+1)
    ASSERT_EQ(exec->copy_val_to_host(output.get_const_data()), 10100LL);
}

TEST_F(KernelLaunch, Reduction1D) { run1d_reduction(exec); }


void run2d_reduction(std::shared_ptr<gko::CudaExecutor> exec)
{
    gko::Array<int64> output{exec, 1};

    gko::kernels::cuda::run_kernel_reduction(
        exec,
        [] GKO_KERNEL(auto i, auto j, auto a) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(j), int64>::value, "index");
            static_assert(is_same<decltype(a), int64*>::value, "value");
            return (i + 1) * (j + 1);
        },
        [] GKO_KERNEL(auto i, auto j) {
            static_assert(is_same<decltype(i), int64>::value, "a");
            static_assert(is_same<decltype(i), int64>::value, "b");
            return i + j;
        },
        [] GKO_KERNEL(auto j) {
            static_assert(is_same<decltype(j), int64>::value, "value");
            return j * 4;
        },
        int64{}, output.get_data(), gko::dim<2>{1000, 100}, output);

    // 4 * sum i=0...999 sum j=0...99 of (i+1)*(j+1)
    ASSERT_EQ(exec->copy_val_to_host(output.get_const_data()), 10110100000LL);

    gko::kernels::cuda::run_kernel_reduction(
        exec,
        [] GKO_KERNEL(auto i, auto j, auto a) {
            static_assert(is_same<decltype(i), int64>::value, "index");
            static_assert(is_same<decltype(j), int64>::value, "index");
            static_assert(is_same<decltype(a), int64*>::value, "value");
            return (i + 1) * (j + 1);
        },
        [] GKO_KERNEL(auto i, auto j) {
            static_assert(is_same<decltype(i), int64>::value, "a");
            static_assert(is_same<decltype(i), int64>::value, "b");
            return i + j;
        },
        [] GKO_KERNEL(auto j) {
            static_assert(is_same<decltype(j), int64>::value, "value");
            return j * 4;
        },
        int64{}, output.get_data(), gko::dim<2>{10, 10}, output);

    // 4 * sum i=0...9 sum j=0...9 of (i+1)*(j+1)
    ASSERT_EQ(exec->copy_val_to_host(output.get_const_data()), 12100LL);
}

TEST_F(KernelLaunch, Reduction2D) { run2d_reduction(exec); }


void run2d_row_reduction(std::shared_ptr<gko::CudaExecutor> exec)
{
    for (auto num_rows : {0, 100, 1000, 10000}) {
        for (auto num_cols : {0, 10, 100, 1000, 10000}) {
            SCOPED_TRACE(std::to_string(num_rows) + " rows, " +
                         std::to_string(num_cols) + " cols");
            gko::Array<int64> host_ref{exec->get_master(),
                                       static_cast<size_type>(2 * num_rows)};
            std::fill_n(host_ref.get_data(), 2 * num_rows, 1234);
            gko::Array<int64> output{exec, host_ref};
            for (int64 i = 0; i < num_rows; i++) {
                // we are computing 2 * sum {j=0, j<cols} (i+1)*(j+1) for each
                // row i and storing it with stride 2
                host_ref.get_data()[2 * i] =
                    static_cast<int64>(num_cols) * (num_cols + 1) * (i + 1);
            }

            gko::kernels::cuda::run_kernel_row_reduction(
                exec,
                [] GKO_KERNEL(auto i, auto j, auto a) {
                    static_assert(is_same<decltype(i), int64>::value, "index");
                    static_assert(is_same<decltype(j), int64>::value, "index");
                    static_assert(is_same<decltype(a), int64*>::value, "value");
                    return (i + 1) * (j + 1);
                },
                [] GKO_KERNEL(auto i, auto j) {
                    static_assert(is_same<decltype(i), int64>::value, "a");
                    static_assert(is_same<decltype(i), int64>::value, "b");
                    return i + j;
                },
                [] GKO_KERNEL(auto j) {
                    static_assert(is_same<decltype(j), int64>::value, "value");
                    return j * 2;
                },
                int64{}, output.get_data(), 2,
                gko::dim<2>{static_cast<size_type>(num_rows),
                            static_cast<size_type>(num_cols)},
                output);

            GKO_ASSERT_ARRAY_EQ(host_ref, output);
        }
    }
}

TEST_F(KernelLaunch, ReductionRow2D) { run2d_row_reduction(exec); }


void run2d_col_reduction(std::shared_ptr<gko::CudaExecutor> exec)
{
    // empty, most threads idle, most threads busy, multiple blocks
    for (auto num_rows : {0, 10, 100, 1000, 10000}) {
        // check different edge cases: subwarp sizes, blocked mode
        for (auto num_cols :
             {0, 1, 2, 3, 4, 5, 7, 8, 9, 16, 31, 32, 63, 127, 128, 129}) {
            SCOPED_TRACE(std::to_string(num_rows) + " rows, " +
                         std::to_string(num_cols) + " cols");
            gko::Array<int64> host_ref{exec->get_master(),
                                       static_cast<size_type>(num_cols)};
            gko::Array<int64> output{exec, static_cast<size_type>(num_cols)};
            for (int64 i = 0; i < num_cols; i++) {
                // we are computing 2 * sum {j=0, j<row} (i+1)*(j+1) for each
                // column i
                host_ref.get_data()[i] =
                    static_cast<int64>(num_rows) * (num_rows + 1) * (i + 1);
            }

            gko::kernels::cuda::run_kernel_col_reduction(
                exec,
                [] GKO_KERNEL(auto i, auto j, auto a) {
                    static_assert(is_same<decltype(i), int64>::value, "index");
                    static_assert(is_same<decltype(j), int64>::value, "index");
                    static_assert(is_same<decltype(a), int64*>::value, "value");
                    return (i + 1) * (j + 1);
                },
                [] GKO_KERNEL(auto i, auto j) {
                    static_assert(is_same<decltype(i), int64>::value, "a");
                    static_assert(is_same<decltype(i), int64>::value, "b");
                    return i + j;
                },
                [] GKO_KERNEL(auto j) {
                    static_assert(is_same<decltype(j), int64>::value, "value");
                    return j * 2;
                },
                int64{}, output.get_data(),
                gko::dim<2>{static_cast<size_type>(num_rows),
                            static_cast<size_type>(num_cols)},
                output);

            GKO_ASSERT_ARRAY_EQ(host_ref, output);
        }
    }
}

TEST_F(KernelLaunch, ReductionCol2D) { run2d_col_reduction(exec); }


}  // namespace