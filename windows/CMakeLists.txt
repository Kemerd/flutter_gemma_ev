# Flutter Gemma Windows Plugin
#
# This CMakeLists.txt sets up the Windows plugin and runs a PowerShell script
# to download prebuilt LiteRT-LM native libraries during build.
# No Java, no JRE, no JAR — pure native FFI.

cmake_minimum_required(VERSION 3.14)

# Project name
set(PROJECT_NAME "flutter_gemma")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_gemma_plugin")

# Define the plugin library target
add_library(${PLUGIN_NAME} SHARED
  "flutter_gemma_plugin.cpp"
)

# Apply standard settings for Windows plugins
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Link against Flutter library
target_include_directories(${PLUGIN_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_gemma_bundled_libraries
  ""
  PARENT_SCOPE
)

# === LiteRT-LM Native Setup ===
# Run PowerShell script to download prebuilt accelerator libraries + DXC

# Get paths
set(PLUGIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(SETUP_SCRIPT "${PLUGIN_DIR}/scripts/setup_desktop.ps1")
set(SETUP_OUTPUT_DIR "${CMAKE_BINARY_DIR}/flutter_gemma_resources")

# Custom target to run setup script
add_custom_target(flutter_gemma_setup ALL
  COMMAND powershell -NoProfile -ExecutionPolicy Bypass -File "${SETUP_SCRIPT}" -PluginDir "${PLUGIN_DIR}" -OutputDir "${SETUP_OUTPUT_DIR}"
  WORKING_DIRECTORY "${PLUGIN_DIR}"
  COMMENT "Setting up LiteRT-LM native libraries..."
  VERBATIM
)

# Ensure setup runs before plugin builds
add_dependencies(${PLUGIN_NAME} flutter_gemma_setup)

# === POST_BUILD: Copy native libraries to runner directory ===
# On Windows with Visual Studio (multi-config generator),
# CMAKE_BUILD_TYPE is EMPTY at configure time. The actual config
# (Debug/Release) is determined at build time via $<CONFIG>.

set(RUNNER_BASE_DIR "${CMAKE_BINARY_DIR}/runner")

message(STATUS "flutter_gemma: Runner base directory: ${RUNNER_BASE_DIR}")
message(STATUS "flutter_gemma: Setup output: ${SETUP_OUTPUT_DIR}")

# POST_BUILD: Copy LiteRT-LM native libraries (DLLs + DXC)
add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
  COMMAND powershell -NoProfile -ExecutionPolicy Bypass -Command
    "New-Item -ItemType Directory -Path '${RUNNER_BASE_DIR}/$<CONFIG>/litertlm' -Force | Out-Null; Copy-Item -Path '${SETUP_OUTPUT_DIR}/litertlm/*' -Destination '${RUNNER_BASE_DIR}/$<CONFIG>/litertlm' -Recurse -Force; Write-Host 'LiteRT-LM native libraries copied to runner/$<CONFIG>/litertlm/'"
  COMMENT "Copying LiteRT-LM native libraries to runner/$<CONFIG>/litertlm/..."
  VERBATIM
)

# === Install rules for Release builds ===
# Copy native libraries to the install bundle
if(DEFINED CMAKE_INSTALL_PREFIX AND NOT "${CMAKE_INSTALL_PREFIX}" STREQUAL "")
  install(CODE "
    if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"\")
      set(CONFIG \"Release\")
    else()
      set(CONFIG \"\${CMAKE_INSTALL_CONFIG_NAME}\")
    endif()

    set(SRC_DIR \"${SETUP_OUTPUT_DIR}/litertlm\")
    set(DST_DIR \"${RUNNER_BASE_DIR}/\${CONFIG}/litertlm\")
    if(EXISTS \"\${SRC_DIR}\")
      message(STATUS \"Installing LiteRT-LM native libraries to \${DST_DIR}\")
      file(MAKE_DIRECTORY \"\${DST_DIR}\")
      file(COPY \"\${SRC_DIR}/\" DESTINATION \"\${DST_DIR}\")
    endif()
  ")
endif()
