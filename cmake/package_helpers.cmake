set(PACKAGE_DOWNLOADER_SCRIPT
    "${CMAKE_CURRENT_LIST_DIR}/DownloadCMakeLists.txt.in")

set(NON_CMAKE_PACKAGE_DOWNLOADER_SCRIPT
    "${CMAKE_CURRENT_LIST_DIR}/DownloadNonCMakeCMakeLists.txt.in")


#   Load a package from the url provided and run configure (Non-CMake projects)
#
#   \param package_name     Name of the package
#   \param package_url      Url of the package
#   \param package_tag      Tag or version of the package to be downloaded.
#   \param config_command   The command for the configuration step.
#
function(ginkgo_load_and_configure_package package_name package_url package_hash config_command)
    set(GINKGO_THIRD_PARTY_BUILD_TYPE "Debug")
    if (CMAKE_BUILD_TYPE MATCHES "[Rr][Ee][Ll][Ee][Aa][Ss][Ee]")
        set(GINKGO_THIRD_PARTY_BUILD_TYPE "Release")
    endif()
    configure_file(${NON_CMAKE_PACKAGE_DOWNLOADER_SCRIPT}
        download/CMakeLists.txt)
    set(TOOLSET "")
    if (NOT "${CMAKE_GENERATOR_TOOLSET}" STREQUAL "")
        set(TOOLSET "-T${CMAKE_GENERATOR_TOOLSET}")
    endif()
    execute_process(COMMAND ${CMAKE_COMMAND} -G "${CMAKE_GENERATOR}" "${TOOLSET}" .
        RESULT_VARIABLE result
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/download)
    if(result)
        message(FATAL_ERROR
            "CMake step for ${package_name}/download failed: ${result}")
        return()
    endif()
    execute_process(COMMAND ${CMAKE_COMMAND} --build .
        RESULT_VARIABLE result
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/download)
    if(result)
        message(FATAL_ERROR
            "Build step for ${package_name}/download failed: ${result}")
        return()
    endif()
endfunction()


#   Add external target to external project.
#   Create a new target and declare it as `IMPORTED` for libraries or `INTERFACE`
#       for header only projects.
#
#   \param new_target       New target for the external project
#   \param external_name    Name of the external project
#   \param includedir       Path to include directory
#   \param libdir           Path to library directory
#   \param header_only      Boolean indicating if this should be a header only target
#
macro(ginkgo_add_tpl_target new_target external_name includedir libdir header_only)
    # Declare include directories and library files
    set(${external_name}_INCLUDE_DIR "${includedir}")
    set(${external_name}_LIBRARY "${libdir}")

    # Create an IMPORTED external library available in the GLOBAL scope
    if (${header_only})
        add_library(${new_target} INTERFACE)
    else()
        add_library(${new_target} UNKNOWN IMPORTED GLOBAL)
    endif()

    # Set the target's properties, namely library file and include directory
    if (NOT ${header_only})
        foreach (lib in LISTS ${${external_name}_LIBRARY})
            set_target_properties(${new_target} PROPERTIES IMPORTED_LOCATION ${lib})
        endforeach()
    endif()
    foreach (inc in LISTS ${${external_name}_INCLUDE_DIR})
        set_target_properties(${new_target} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES ${inc})
    endforeach()
endmacro(ginkgo_add_tpl_target)


#   Ginkgo specific add_subdirectory helper macro.
#   If the package was not found or if requested by the user, use the
#       internal version of the package.
#
#   \param package_name     Name of package to be found
#   \param dir_name         Name of the subdirectory for the package
#
macro(ginkgo_add_subdirectory package_name dir_name)
    if (NOT ${package_name}_FOUND)
        add_subdirectory(${dir_name})
    endif()
endmacro(ginkgo_add_subdirectory)


#   Ginkgo specific find_package helper macro. Use this macro for third
#       party libraries.
#   If the user does not specify otherwise, try to find the package.
#
#   \param package_name     Name of package to be found
#   \param target_list      For TPL packages, declare a new target for each library
#   \param header_only      For TPL packages, declare the tpl package as header only
#   \param ARGN             Extra specifications for the package finder
#
macro(ginkgo_find_package package_name target_list header_only)
    string(TOUPPER ${package_name} _UPACKAGE_NAME)
    if (GINKGO_USE_EXTERNAL_${_UPACKAGE_NAME} OR TPL_ENABLE_${_UPACKAGE_NAME})
        if (TPL_${_UPACKAGE_NAME}_LIBRARIES AND TPL_${_UPACKAGE_NAME}_INCLUDE_DIRS)
            set(${package_name}_FOUND "${TPL_${_UPACKAGE_NAME}_LIBRARIES};${TPL_${_UPACKAGE_NAME}_INCLUDE_DIRS}")
            set(_target_list ${target_list}) # CMake weirdness: target_list is not a list anymore
            # Count the number of elements in the list. Substract by one to iterate from 0 to the end.
            list(LENGTH _target_list _GKO_len1)
            math(EXPR _GKO_len2 "${_GKO_len1} - 1")
            foreach(val RANGE ${_GKO_len2})
                list(GET _target_list ${val} target) # access element number "val" in _target_list
                list(GET TPL_${_UPACKAGE_NAME}_LIBRARIES ${val} lib)
                ginkgo_add_tpl_target("${target}" "${_UPACKAGE_NAME}" "${TPL_${_UPACKAGE_NAME}_INCLUDE_DIRS}"
                    "${lib}" ${header_only})
            endforeach()
        else()
            find_package(${package_name} ${ARGN})
            if (${package_name}_FOUND)
                message(STATUS "Using external version of package ${package_name}. In case of problems, consider setting -DGINKGO_USE_EXTERNAL_${_UPACKAGE_NAME}=OFF.")
            else()
                message(STATUS "Ginkgo could not find ${package_name}. The internal version will be used. Consider setting `-DCMAKE_PREFIX_PATH` if the package was not system-installed.")
            endif()
        endif()
    endif()
endmacro(ginkgo_find_package)


#   Download a file and verify the download
#
#   \param url          The url of file to be downloaded
#   \param filename     The name of the file
#   \param hash_type    The type of hash, See CMake file() documentation for more details.
#   \param hash         The hash itself, See CMake file() documentation for more details.
#
function(ginkgo_download_file url filename hash_type hash)
    file(DOWNLOAD ${url} ${filename}
        TIMEOUT 60  # seconds
        EXPECTED_HASH "${hash_type}=${hash}"
        TLS_VERIFY ON)
    if(EXISTS ${filename})
        message(STATUS "${filename} downloaded from ${url}")
    else()
        message(FATAL_ERROR "Download of ${filename} failed.")
    endif()
endfunction(ginkgo_download_file)
