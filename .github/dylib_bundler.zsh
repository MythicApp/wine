#!/bin/zsh

# Bundle dylib dependencies for Wine distribution
# This script finds all dylib dependencies, copies them, and fixes install names

set -e

# Output directory (can be overridden via environment variable)
ENGINE_DIR="${ENGINE_DIR:-Engine/wine}"

# GStreamer plugins to bundle
GSTREAMER_LIBS=(
    "libgstapplemedia"
    "libgstasf"
    "libgstaudioconvert"
    "libgstaudioparsers"
    "libgstaudioresample"
    "libgstavi"
    "libgstcoreelements"
    "libgstdebug"
    "libgstdeinterlace"
    "libgstid3demux"
    "libgstisomp4"
    "libgstlibav"
    "libgstopengl"
    "libgstplayback"
    "libgsttypefindfunctions"
    "libgstvideoconvertscale"
    "libgstvideofilter"
    "libgstvideoparsersbad"
    "libgstwavparse"
)

# Non-GStreamer libraries to bundle
LIBS=(
    "libMoltenVK"
    "libSDL2-2.0.0"
    "libpcap"
    "libfreetype"
    "libgnutls"
    "libpng16"
    "libjpeg"
    "libtiff"
)

# Global array to store all discovered dylibs (unique entries)
typeset -aU all_dylibs
# Queue for iterative processing
typeset -a queue

# Resolve @rpath dependencies by searching in Homebrew's lib directory
resolve_rpath() {
  local ref_dylib="$1"
  local dylib_name="${ref_dylib#@rpath/}"
  local brew_lib_dir="$(brew --prefix)/lib"
  local resolved_path="${brew_lib_dir}/${dylib_name}"
  
  if [[ -f "$resolved_path" ]]; then
    echo "$resolved_path"
  else
    echo ""
  fi
}

# Find all dylib dependencies iteratively
find_dylib_dependencies() {
  local dylib="$1"
  queue+=("$dylib")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local current_dylib="${queue[1]}"
    queue=("${queue[@]:1}")

    local referenced_dylibs=($(otool -L "$current_dylib" 2>/dev/null | awk '/^\t/ {print $1}' | grep '\.dylib'))

    for ref_dylib in $referenced_dylibs; do
      # Skip system libraries
      if [[ "$ref_dylib" == /usr/lib/* ]] || [[ "$ref_dylib" == /System/* ]]; then
        continue
      fi

      # Resolve @rpath references
      if [[ "$ref_dylib" == @rpath/* ]]; then
        ref_dylib=$(resolve_rpath "$ref_dylib")
        if [[ -z "$ref_dylib" ]]; then
          continue
        fi
      fi

      # Skip relative path references
      if [[ "$ref_dylib" == @loader_path/* ]] || [[ "$ref_dylib" == @executable_path/* ]]; then
        continue
      fi

      # Add to array and queue if not already present
      if [[ ! " ${all_dylibs[*]} " =~ " $ref_dylib " ]]; then
        all_dylibs+=("$ref_dylib")
        queue+=("$ref_dylib")
      fi
    done
  done
}

# Fix dylib install names
update_dylib_paths() {
  local dylib_file="$1"
  local path_prefix="$2"
  echo "Fixing install names for $dylib_file..."

  # Update the dylib's own install name
  local basename_dylib=$(basename "$dylib_file")
  install_name_tool -id "${path_prefix}${basename_dylib}" "$dylib_file" 2>/dev/null || true

  otool -L "$dylib_file" | grep -v "$dylib_file" | awk '{print $1}' | while read -r dylib_path; do
    if [[ "$dylib_path" != /usr/lib* ]] && [[ "$dylib_path" != /System/* ]]; then
      local lib_name="${dylib_path##*/}"
      local new_dylib_path="${path_prefix}${lib_name}"
      echo "  $dylib_path -> $new_dylib_path"
      install_name_tool -change "$dylib_path" "$new_dylib_path" "$dylib_file" 2>/dev/null || true
    fi
  done
  
  # Re-sign with ad-hoc signature
  codesign -fs- "$dylib_file" 2>/dev/null || true
}

# Copy libraries to appropriate directories
copy_library() {
  local lib="$1"
  local gstreamer_dir="${ENGINE_DIR}/lib/gstreamer-1.0"
  local lib_dir="${ENGINE_DIR}/lib"

  mkdir -p "$gstreamer_dir" "$lib_dir"

  if [[ "$lib" == *"/gstreamer-1.0/"* ]]; then
    echo "Copying GStreamer plugin: $lib"
    cp -L "$lib" "$gstreamer_dir/"
    update_dylib_paths "$gstreamer_dir/$(basename "$lib")" "@loader_path/../"
  else
    echo "Copying library: $lib"
    cp -L "$lib" "$lib_dir/"
    update_dylib_paths "$lib_dir/$(basename "$lib")" "@loader_path/"
  fi
}

main() {
  # Get Homebrew prefixes
  GSTREAMER_PREFIX=$(brew --prefix gstreamer)
  PREFIX=$(brew --prefix)

  echo "=== Finding GStreamer plugin dependencies ==="
  for lib in "${GSTREAMER_LIBS[@]}"; do
    dylib_path="${GSTREAMER_PREFIX}/lib/gstreamer-1.0/${lib}.dylib"
    if [[ -f "$dylib_path" ]]; then
      echo "Processing: $dylib_path"
      find_dylib_dependencies "$dylib_path"
    else
      echo "Warning: $dylib_path not found"
    fi
  done

  echo "=== Finding library dependencies ==="
  for lib in "${LIBS[@]}"; do
    # Try with .dylib extension first, then without
    dylib_path="${PREFIX}/lib/${lib}.dylib"
    if [[ ! -f "$dylib_path" ]]; then
      # Try finding the actual versioned dylib
      dylib_path=$(find "${PREFIX}/lib" -maxdepth 1 -name "${lib}*.dylib" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -f "$dylib_path" ]]; then
      echo "Processing: $dylib_path"
      find_dylib_dependencies "$dylib_path"
    else
      echo "Warning: $lib not found in ${PREFIX}/lib"
    fi
  done

  echo "=== Copying ${#all_dylibs[@]} dylibs ==="
  for dylib in "${all_dylibs[@]}"; do
    copy_library "$dylib"
  done

  # Copy GStreamer include files if they exist
  if [[ -d "${GSTREAMER_PREFIX}/lib/gstreamer-1.0/include" ]]; then
    echo "=== Copying GStreamer include files ==="
    mkdir -p "${ENGINE_DIR}/lib/gstreamer-1.0"
    cp -a "${GSTREAMER_PREFIX}/lib/gstreamer-1.0/include" "${ENGINE_DIR}/lib/gstreamer-1.0/"
  fi

  echo "=== Fixing Wine .so files ==="
  # Fix winegstreamer.so to find bundled libraries
  if [[ -f "${ENGINE_DIR}/lib/wine/x86_64-unix/winegstreamer.so" ]]; then
    update_dylib_paths "${ENGINE_DIR}/lib/wine/x86_64-unix/winegstreamer.so" "@rpath/"
  fi

  # Fix other Wine .so files that might reference Homebrew libraries
  for so_file in "${ENGINE_DIR}"/lib/wine/x86_64-unix/*.so; do
    if [[ -f "$so_file" ]]; then
      # Check if it has any non-system dependencies
      if otool -L "$so_file" 2>/dev/null | grep -q "/usr/local\|/opt/homebrew"; then
        echo "Fixing: $so_file"
        update_dylib_paths "$so_file" "@rpath/"
      fi
    fi
  done

  echo "=== Dylib bundling complete ==="
}

main "$@"
