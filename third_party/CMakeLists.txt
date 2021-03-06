if(GINKGO_BUILD_CUDA OR (GINKGO_BUILD_HIP AND
        GINKGO_HIP_PLATFORM MATCHES "${HIP_PLATFORM_NVIDIA_REGEX}"))
    enable_language(CUDA)
    if (GINKGO_USE_EXTERNAL_CAS)
        include(CudaArchitectureSelector RESULT_VARIABLE GINKGO_CAS_FILE)
    endif()
    if (NOT GINKGO_CAS_FILE)
        add_subdirectory(CudaArchitectureSelector)
    endif()
endif()

# For each external package, check if they are already available, otherwise use ours
if(GINKGO_BUILD_TESTS)
    add_subdirectory(gtest)
endif()

if(GINKGO_HAVE_HWLOC AND NOT GINKGO_USE_EXTERNAL_HWLOC)
    ginkgo_add_subdirectory(HWLOC hwloc)
endif()

if(GINKGO_DEVEL_TOOLS)
    set(GCF_IGNORE_LIST "third_party" CACHE STRING "Ignore directories for GCF")
    add_subdirectory(git-cmake-format)
else()
    add_subdirectory(dummy-hook)
endif()

if(GINKGO_BUILD_BENCHMARKS)
    add_subdirectory(gflags)
    add_subdirectory(rapidjson)
endif()

set(CMAKE_MODULE_PATH "${CMAKE_MODULE_PATH}" PARENT_SCOPE)
