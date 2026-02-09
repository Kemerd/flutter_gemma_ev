# Flutter Gemma Linux Plugin
#
# This CMakeLists.txt sets up the Linux plugin and runs a bash script
# to download prebuilt LiteRT-LM native libraries during build.
# No Java, no JRE, no JAR — pure native FFI.

cmake_minimum_required(VERSION 3.14)

project(flutter_gemma LANGUAGES CXX)

# This value is used when generating builds using this plugin
set(PLUGIN_NAME "flutter_gemma_plugin")

# Define the plugin library target
add_library(${PLUGIN_NAME} SHARED
  "flutter_gemma_plugin.cc"
)

# Apply standard settings
apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

# Empty bundled libraries (we copy manually via install step)
set(flutter_gemma_bundled_libraries "" PARENT_SCOPE)

# === LiteRT-LM Native Setup ===
# Run bash script to download prebuilt accelerator libraries
set(PLUGIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(SETUP_SCRIPT "${PLUGIN_DIR}/scripts/setup_desktop.sh")
set(SETUP_OUTPUT_DIR "${CMAKE_BINARY_DIR}/flutter_gemma_resources")

# Custom target to run setup script
add_custom_target(flutter_gemma_setup ALL
  COMMAND bash "${SETUP_SCRIPT}" "${PLUGIN_DIR}" "${SETUP_OUTPUT_DIR}"
  WORKING_DIRECTORY "${PLUGIN_DIR}"
  COMMENT "Setting up LiteRT-LM native libraries..."
  VERBATIM
)

add_dependencies(${PLUGIN_NAME} flutter_gemma_setup)

# === Install: Copy native libraries to bundle ===
# Linux bundle structure: bundle/lib/
install(CODE "
  set(BUNDLE_DIR \"${CMAKE_BINARY_DIR}/bundle\")
  set(SETUP_DIR \"${SETUP_OUTPUT_DIR}\")

  # Copy native libraries (accelerator DLLs, etc.)
  if(EXISTS \"\${SETUP_DIR}/litertlm\")
    file(COPY \"\${SETUP_DIR}/litertlm\" DESTINATION \"\${BUNDLE_DIR}/lib\")
    message(STATUS \"Installed LiteRT-LM native libs to bundle/lib/litertlm/\")
  endif()
")
