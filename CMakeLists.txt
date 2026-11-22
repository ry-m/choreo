cmake_minimum_required(VERSION 3.24)
project(Choreo LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(SDL3 REQUIRED CONFIG)

# Core analysis library: platform-independent, testable offline.
add_library(choreo_analysis STATIC
  src/analysis/FFT.cpp
  src/analysis/Analyzer.cpp
  src/analysis/BarTracker.cpp
  src/analysis/Sections.cpp
  src/analysis/Features.cpp
  src/analysis/BeatNet.cpp
)
target_include_directories(choreo_analysis PUBLIC src)
target_compile_options(choreo_analysis PRIVATE -Wall -Wextra -O3 -ffast-math)

# Audio capture backends.
add_library(choreo_audio STATIC src/audio/Capture.cpp)
target_include_directories(choreo_audio PUBLIC src)
target_link_libraries(choreo_audio PUBLIC SDL3::SDL3)
if(APPLE)
  target_sources(choreo_audio PRIVATE src/audio/CaptureMacOS.mm)
  target_link_libraries(choreo_audio PUBLIC "-framework CoreAudio" "-framework AudioToolbox" "-framework Foundation")
endif()

add_executable(choreo src/app/main.cpp src/render/Renderer.cpp)
target_link_libraries(choreo PRIVATE choreo_analysis choreo_audio SDL3::SDL3)
target_compile_options(choreo PRIVATE -Wall -Wextra)
if(APPLE)
  set_source_files_properties(src/audio/CaptureMacOS.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  # Shaders are compiled at runtime from source (no offline Metal compiler with CLT).
  add_custom_command(TARGET choreo POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/shaders $<TARGET_FILE_DIR:choreo>/shaders)
endif()

add_executable(choreo-analyze tools/choreo_analyze.cpp tools/Wav.cpp tools/AudioFile.cpp)
target_link_libraries(choreo-analyze PRIVATE choreo_analysis)
if(APPLE)
  target_link_libraries(choreo-analyze PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
endif()

if(APPLE)
  # Live evaluation through the Spotify desktop app.
  add_executable(choreo-live-eval tools/choreo_live_eval.cpp)
  target_link_libraries(choreo-live-eval PRIVATE choreo_analysis choreo_audio)
endif()

add_executable(choreo-features tools/choreo_features.cpp tools/Wav.cpp tools/AudioFile.cpp)
target_link_libraries(choreo-features PRIVATE choreo_analysis)
if(APPLE)
  target_link_libraries(choreo-features PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
endif()

enable_testing()
add_executable(test_analysis tests/test_analysis.cpp)
target_link_libraries(test_analysis PRIVATE choreo_analysis)
add_test(NAME analysis COMMAND test_analysis)
add_executable(test_beatnet tests/test_beatnet.cpp)
target_link_libraries(test_beatnet PRIVATE choreo_analysis)
add_test(NAME beatnet COMMAND test_beatnet ${CMAKE_SOURCE_DIR}/models/beatnet.bin ${CMAKE_SOURCE_DIR}/models/beatnet_testvec.bin)
add_executable(test_sections tests/test_sections.cpp)
target_link_libraries(test_sections PRIVATE choreo_analysis)
add_test(NAME sections COMMAND test_sections ${CMAKE_SOURCE_DIR}/models/sections.bin ${CMAKE_SOURCE_DIR}/models/sections_testvec.bin)
