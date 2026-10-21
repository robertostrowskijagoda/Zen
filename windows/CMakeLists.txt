# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(zen LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "zen")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Include shims (e.g. lightweight ATL replacements for plugins)
include_directories("${CMAKE_CURRENT_SOURCE_DIR}/shims")

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Go bridge (native/yggdrasil_bridge): checked on every build and rebuilt
# only when its Go sources changed (the hash is kept next to the DLL; see
# build_if_changed.ps1). Without Go an existing DLL is used with a warning.
# One DLL per architecture: x64 in bin/ (as always), arm64 (Windows on ARM,
# built on an ARM64 computer with llvm-mingw) in bin/windows-arm64/.
set(YGGDRASIL_BRIDGE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/yggdrasil_bridge")
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64"
    OR CMAKE_GENERATOR_PLATFORM MATCHES "^[Aa][Rr][Mm]64$")
  set(YGGDRASIL_BRIDGE_ARCH "arm64")
  set(YGGDRASIL_BRIDGE_DLL "${YGGDRASIL_BRIDGE_DIR}/bin/windows-arm64/yggdrasil_bridge.dll")
else()
  set(YGGDRASIL_BRIDGE_ARCH "x64")
  set(YGGDRASIL_BRIDGE_DLL "${YGGDRASIL_BRIDGE_DIR}/bin/yggdrasil_bridge.dll")
endif()
add_custom_target(yggdrasil_bridge ALL
  COMMAND powershell -NoProfile -ExecutionPolicy Bypass
    -File "${YGGDRASIL_BRIDGE_DIR}/build_if_changed.ps1" -Target windows
    -Arch ${YGGDRASIL_BRIDGE_ARCH}
  WORKING_DIRECTORY "${YGGDRASIL_BRIDGE_DIR}"
  COMMENT "Go bridge (yggdrasil_bridge.dll, ${YGGDRASIL_BRIDGE_ARCH})"
  VERBATIM)
add_dependencies(${BINARY_NAME} yggdrasil_bridge)
install(FILES "${YGGDRASIL_BRIDGE_DLL}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime
  OPTIONAL)
# Licenses of the Go modules inside the DLL (tool/go_licenses.dart).
install(FILES "${YGGDRASIL_BRIDGE_DIR}/LICENSES-GO.txt"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime
  OPTIONAL)
# Zen's own licence (GPL-3.0-only), its additional terms and the
# third-party notices.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE"
  "${CMAKE_CURRENT_SOURCE_DIR}/../NOTICE"
  "${CMAKE_CURRENT_SOURCE_DIR}/../THIRD_PARTY_NOTICES.md"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/tray_icon.ico"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Drop stale native libs from previous plugin sets (media_kit's libmpv
# used to ship next to the exe and CMake install does not delete it).
install(CODE "
  file(REMOVE
    \"${CMAKE_INSTALL_PREFIX}/libmpv-2.dll\"
    \"${CMAKE_INSTALL_PREFIX}/media_kit_video_plugin.dll\"
    \"${CMAKE_INSTALL_PREFIX}/media_kit_libs_windows_video_plugin.dll\"
  )
" COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
