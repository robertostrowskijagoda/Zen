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
  "zen_media_codecs.cc"
  "zen_media_transfer.cc"
  "zen_film_codec.cc"
  "zen_video_bridge.cc"
  "zen_call_recorder.cc"
  "zen_portrait_window.cc"
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

# Call recording (zen_call_recorder.cc): PulseAudio's client library, which
# PipeWire serves too. Only its headers are needed to build (libpulse-dev);
# the library is loaded at run time (dlopen), so Zen starts without it.
# Without the headers the app builds anyway and cannot record calls.
pkg_check_modules(PULSE IMPORTED_TARGET libpulse)
if(PULSE_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE ZEN_HAVE_PULSE=1)
  target_include_directories(${BINARY_NAME} SYSTEM PRIVATE ${PULSE_INCLUDE_DIRS})
  target_link_libraries(${BINARY_NAME} PRIVATE ${CMAKE_DL_LIBS})
else()
  message(WARNING "PulseAudio development files not found: Zen will build "
    "without call recording (install libpulse-dev).")
endif()

# Films (zen_video_bridge.cc, zen_film_codec.cc): Zen's own H.264 encoder,
# OpenH264 (BSD-2-Clause), built from source with the app so compressing
# works on every Linux; no system package is needed. Plain C/C++ (no NASM,
# USE_ASM=No), a static library linked into the app. Pinned to a release
# tag; its tarball's SHA-256 is pinned below (ZEN_OPENH264_SHA256): a new
# version needs a new sum (docs/DEPENDENCIES.md).
include(ExternalProject)
find_package(Threads REQUIRED)
set(ZEN_OPENH264_VERSION "2.4.1" CACHE STRING "OpenH264 release built into Zen")
set(ZEN_OPENH264_SHA256 "8ffbe944e74043d0d3fb53d4a2a14c94de71f58dbea6a06d0dc92369542958ea" CACHE STRING
  "SHA-256 of the OpenH264 release tarball (checked when set)")
set(ZEN_OPENH264_URL
  "https://github.com/cisco/openh264/archive/refs/tags/v${ZEN_OPENH264_VERSION}.tar.gz")
if(ZEN_OPENH264_SHA256)
  set(ZEN_OPENH264_HASH URL_HASH "SHA256=${ZEN_OPENH264_SHA256}")
else()
  set(ZEN_OPENH264_HASH "")
  message(WARNING "ZEN_OPENH264_SHA256 is not set: OpenH264 "
    "${ZEN_OPENH264_VERSION} is downloaded without checking its hash.")
endif()
find_program(ZEN_MAKE NAMES gmake make REQUIRED)
ExternalProject_Add(zen_openh264
  URL "${ZEN_OPENH264_URL}"
  ${ZEN_OPENH264_HASH}
  CONFIGURE_COMMAND ""
  BUILD_IN_SOURCE TRUE
  BUILD_COMMAND ${ZEN_MAKE} -j4 USE_ASM=No BUILDTYPE=Release libopenh264.a
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "<SOURCE_DIR>/libopenh264.a"
  LOG_BUILD TRUE
)
ExternalProject_Get_Property(zen_openh264 SOURCE_DIR)
add_dependencies(${BINARY_NAME} zen_openh264)
target_include_directories(${BINARY_NAME} SYSTEM PRIVATE "${SOURCE_DIR}/codec/api")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${SOURCE_DIR}/libopenh264.a" Threads::Threads m)

# Zen's own AAC encoder for films' sound (zen_film_codec.cc): VisualOn's
# vo-aacenc (Apache-2.0), built from its release tarball the same way
# (static, position-independent), so a film's sound and the recorder's
# microphone never depend on the system having an AAC encoder. Its SHA-256
# is pinned below (ZEN_VOAAC_SHA256).
set(ZEN_VOAAC_VERSION "0.1.3" CACHE STRING "vo-aacenc release built into Zen")
set(ZEN_VOAAC_SHA256 "e51a7477a359f18df7c4f82d195dab4e14e7414cbd48cf79cc195fc446850f36" CACHE STRING
  "SHA-256 of the vo-aacenc release tarball (checked when set)")
if(ZEN_VOAAC_SHA256)
  set(ZEN_VOAAC_HASH URL_HASH "SHA256=${ZEN_VOAAC_SHA256}")
else()
  set(ZEN_VOAAC_HASH "")
  message(WARNING "ZEN_VOAAC_SHA256 is not set: vo-aacenc "
    "${ZEN_VOAAC_VERSION} is downloaded without checking its hash.")
endif()
ExternalProject_Add(zen_voaacenc
  URL "https://downloads.sourceforge.net/project/opencore-amr/vo-aacenc/vo-aacenc-${ZEN_VOAAC_VERSION}.tar.gz"
  ${ZEN_VOAAC_HASH}
  CONFIGURE_COMMAND <SOURCE_DIR>/configure --prefix=<INSTALL_DIR>
    --libdir=<INSTALL_DIR>/lib --disable-shared --enable-static --with-pic
  BUILD_COMMAND ${ZEN_MAKE} -j4
  INSTALL_COMMAND ${ZEN_MAKE} install
  BUILD_BYPRODUCTS "<INSTALL_DIR>/lib/libvo-aacenc.a"
  LOG_CONFIGURE TRUE
  LOG_BUILD TRUE
)
ExternalProject_Get_Property(zen_voaacenc INSTALL_DIR)
add_dependencies(${BINARY_NAME} zen_voaacenc)
target_compile_definitions(${BINARY_NAME} PRIVATE ZEN_HAVE_VOAAC=1)
target_include_directories(${BINARY_NAME} SYSTEM PRIVATE "${INSTALL_DIR}/include")
target_link_libraries(${BINARY_NAME} PRIVATE "${INSTALL_DIR}/lib/libvo-aacenc.a")
