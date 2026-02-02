cmake_minimum_required(VERSION 3.22...3.31)
project(vk_raytracing_tutorial VERSION 2.0 LANGUAGES C CXX)

# Here we can set the Slang version to use (uncomment to override the default)
# set(Slang_VERSION "2025.20" CACHE STRING "Version of Slang to use")

# Optional Vulkan 1.3 compatibility mode for systems with older SDK
# Enable with: cmake -DVULKAN13_COMPAT=ON ..
# Requires vulkan-headers-1.4 and vulkan-utility-1.4 directories at ../
option(VULKAN13_COMPAT "Enable Vulkan 1.3 SDK compatibility mode" OFF)

if(VULKAN13_COMPAT)
    message(STATUS "Vulkan 1.3 compatibility mode ENABLED")

    # Use Vulkan 1.4 headers (required by nvpro_core2)
    set(VULKAN14_HEADERS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vulkan-headers-1.4/include")
    set(VULKAN14_UTILITY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vulkan-utility-1.4/include")

    if(NOT EXISTS ${VULKAN14_HEADERS_DIR})
        message(FATAL_ERROR "VULKAN13_COMPAT requires Vulkan 1.4 headers at: ${VULKAN14_HEADERS_DIR}\n"
            "Clone with: git clone --depth 1 --branch vulkan-sdk-1.4.335.0 https://github.com/KhronosGroup/Vulkan-Headers.git ../vulkan-headers-1.4")
    endif()
    if(NOT EXISTS ${VULKAN14_UTILITY_DIR})
        message(FATAL_ERROR "VULKAN13_COMPAT requires Vulkan utility libraries at: ${VULKAN14_UTILITY_DIR}\n"
            "Clone with: git clone --depth 1 --branch vulkan-sdk-1.4.335.0 https://github.com/KhronosGroup/Vulkan-Utility-Libraries.git ../vulkan-utility-1.4")
    endif()

    include_directories(BEFORE SYSTEM ${VULKAN14_UTILITY_DIR})
    include_directories(BEFORE SYSTEM ${VULKAN14_HEADERS_DIR})
    message(STATUS "Using Vulkan 1.4 headers from: ${VULKAN14_HEADERS_DIR}")
    message(STATUS "Using Vulkan 1.4 utilities from: ${VULKAN14_UTILITY_DIR}")

    # Force use of bundled volk (has Vulkan 1.4 functions) instead of system volk
    set(Vulkan_VOLK_DIR "" CACHE PATH "Force bundled volk" FORCE)
endif()

# Add the cmake folder to the module path
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(NvproCore2 REQUIRED)

# Apply Vulkan 1.3 compatibility patch to nvpro_core2 if needed
if(VULKAN13_COMPAT)
    set(NVPRO_PATCH_FILE "${CMAKE_CURRENT_SOURCE_DIR}/cmake/nvpro_core2_vulkan13_compat.patch")
    set(NVPRO_PATCH_MARKER "${NvproCore2_ROOT}/nvpro_core2/.vulkan13_compat_patched")

    if(EXISTS ${NVPRO_PATCH_FILE} AND NOT EXISTS ${NVPRO_PATCH_MARKER})
        message(STATUS "Applying Vulkan 1.3 compatibility patch to nvpro_core2...")
        execute_process(
            COMMAND git apply --check ${NVPRO_PATCH_FILE}
            WORKING_DIRECTORY ${NvproCore2_ROOT}/nvpro_core2
            RESULT_VARIABLE PATCH_CHECK_RESULT
            ERROR_QUIET
        )
        if(PATCH_CHECK_RESULT EQUAL 0)
            execute_process(
                COMMAND git apply ${NVPRO_PATCH_FILE}
                WORKING_DIRECTORY ${NvproCore2_ROOT}/nvpro_core2
                RESULT_VARIABLE PATCH_RESULT
            )
            if(PATCH_RESULT EQUAL 0)
                file(WRITE ${NVPRO_PATCH_MARKER} "Patched for Vulkan 1.3 compatibility")
                message(STATUS "Patch applied successfully")
            else()
                message(WARNING "Failed to apply patch")
            endif()
        else()
            message(STATUS "Patch already applied or not applicable")
            file(WRITE ${NVPRO_PATCH_MARKER} "Patch skipped")
        endif()
    endif()
endif()

# Include the RtTutorial common functions
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/RtTutorial.cmake")

set(ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(COMMON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/common")
set(TUTO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/raytrace_tutorial")



# Add common library first as other samples might depend on it
add_subdirectory(common)

add_subdirectory(raytrace_tutorial/01_foundation)
add_subdirectory(raytrace_tutorial/02_basic)
add_subdirectory(raytrace_tutorial/02_basic_nvvk)
add_subdirectory(raytrace_tutorial/03_any_hit)
add_subdirectory(raytrace_tutorial/04_jitter_camera)
add_subdirectory(raytrace_tutorial/05_shadow_miss)
add_subdirectory(raytrace_tutorial/06_reflection)
add_subdirectory(raytrace_tutorial/07_multi_closest_hit)
add_subdirectory(raytrace_tutorial/08_intersection)
add_subdirectory(raytrace_tutorial/09_motion_blur)
add_subdirectory(raytrace_tutorial/10_position_fetch)
add_subdirectory(raytrace_tutorial/11_shader_execution_reorder)
add_subdirectory(raytrace_tutorial/12_infinite_plane)
add_subdirectory(raytrace_tutorial/13_callable_shader)
add_subdirectory(raytrace_tutorial/14_animation)
add_subdirectory(raytrace_tutorial/15_micro_maps_opacity)
add_subdirectory(raytrace_tutorial/16_ray_query)
add_subdirectory(raytrace_tutorial/17_ray_query_screenspace)
add_subdirectory(raytrace_tutorial/18_swept_spheres)
add_subdirectory(raytrace_tutorial/XX_template)

# Make Visual Studio use this project as the startup project
set_property(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} PROPERTY VS_STARTUP_PROJECT 01_foundation)

# Install the resources and nvshaders folders
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/resources" DESTINATION ${CMAKE_INSTALL_PREFIX})
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/common/shaders" DESTINATION ${CMAKE_INSTALL_PREFIX}/common)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/common/io_gltf.h" DESTINATION ${CMAKE_INSTALL_PREFIX}/common)
install(DIRECTORY "${NVSHADERS_DIR}/nvshaders" DESTINATION ${CMAKE_INSTALL_PREFIX})
install(FILES ${Slang_GLSLANG} DESTINATION ${CMAKE_INSTALL_PREFIX})


