cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "zen_media_player.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Audio and video playback (zen_media_player.cc): GStreamer, which every
# common desktop already has. Without its development files (libgstreamer1.0-dev,
# libgstreamer-plugins-base1.0-dev) the app builds anyway and plays nothing.
pkg_check_modules(GSTREAMER IMPORTED_TARGET
  gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)
if(GSTREAMER_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE ZEN_HAVE_GSTREAMER=1)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GSTREAMER)
else()
  message(WARNING "GStreamer development files not found: Zen will build "
    "without audio and video playback (install libgstreamer1.0-dev and "
    "libgstreamer-plugins-base1.0-dev).")
endif()
