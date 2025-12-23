#!/bin/zsh

# this is a script created for Mythic to bundle its dependencies' dylibs and copy them to the appropriate location.

set -e

# Output directory (can be overridden via environment variable)
ENGINE_DIR="${ENGINE_DIR:-Engine/wine}"
BREW_PREFIX=$(brew --prefix)

# List of GStreamer plugins to bundle, minus the 'libgst' prefix
GSTREAMER_PLUGINS=(
    applemedia
    asf
    audioconvert
    audioparsers
    audioresample
    avi
    coreelements
    debug
    deinterlace
    id3demux
    isomp4
    libav
    opengl
    playback
    typefindfunctions
    videoconvertscale
    videofilter
    videoparsersbad
    wavparse
)

# list of keg-only formulae and their main dylib names
BUNDLE_LIBS=(
    molten-vk:libMoltenVK
    sdl2:libSDL2-2.0.0
    freetype:libfreetype
    gnutls:libgnutls
    libpng:libpng16
    libtiff:libtiff
    libpcap:libpcap
    jpeg:libjpeg
    libffi:libffi
)

typeset -A seen_dylibs
typeset -a all_dylibs

get_lib_path() {
    local formula="$1" libname="$2"
    local prefix=$(brew --prefix "$formula" 2>/dev/null) || return 1
    find "$prefix/lib" -maxdepth 1 -name "${libname}*.dylib" -type f 2>/dev/null | head -1
}

resolve_rpath() {
    local name="${1#@rpath/}"
    
    # Check main lib dir first
    [[ -f "${BREW_PREFIX}/lib/${name}" ]] && { echo "${BREW_PREFIX}/lib/${name}"; return; }
    
    # Search keg-only formula lib dirs
    for entry in "${BUNDLE_LIBS[@]}"; do
        local formula="${entry%%:*}"
        local path="$(brew --prefix "$formula" 2>/dev/null)/lib/${name}"
        [[ -f "$path" ]] && { echo "$path"; return; }
    done
}

normalize_path() {
    python3 -c "import os; print(os.path.realpath('$1'))" 2>/dev/null || echo "$1"
}

find_dependencies() {
    local dylib="$1"
    local norm=$(normalize_path "$dylib")
    
    [[ -n "${seen_dylibs[$norm]}" ]] && return
    seen_dylibs[$norm]=1
    all_dylibs+=("$dylib")
    
    local -a queue=("$dylib")

    while [[ ${#queue[@]} -gt 0 ]]; do
        local current="${queue[1]}"
        queue=("${queue[@]:1}")

        for ref in $(otool -L "$current" 2>/dev/null | tail -n +2 | awk '/^\t/ {print $1}' | grep '\.dylib'); do
            [[ "$ref" == /usr/lib/* || "$ref" == /System/* ]] && continue
            [[ "$ref" == @loader_path/* || "$ref" == @executable_path/* ]] && continue
            
            [[ "$ref" == @rpath/* ]] && { ref=$(resolve_rpath "$ref"); [[ -z "$ref" ]] && continue; }

            norm=$(normalize_path "$ref")
            [[ -z "${seen_dylibs[$norm]}" ]] && {
                seen_dylibs[$norm]=1
                all_dylibs+=("$ref")
                queue+=("$ref")
            }
        done
    done
}

fix_install_names() {
    local file="$1" prefix="$2"
    chmod u+w "$file"
    install_name_tool -id "${prefix}$(basename "$file")" "$file" 2>/dev/null || true
    
    otool -L "$file" | grep -v "$file" | awk '{print $1}' | while read -r path; do
        [[ "$path" != /usr/lib* && "$path" != /System/* ]] && \
            install_name_tool -change "$path" "${prefix}${path##*/}" "$file" 2>/dev/null || true
    done
    codesign -fs- "$file" 2>/dev/null || true
}

copy_dylib() {
    local lib="$1" dest_dir="${ENGINE_DIR}/lib" prefix="@loader_path/"
    
    [[ "$lib" == *"/gstreamer-1.0/"* ]] && { dest_dir="${ENGINE_DIR}/lib/gstreamer-1.0"; prefix="@loader_path/../"; }
    
    local dest="${dest_dir}/$(basename "$lib")"
    mkdir -p "$dest_dir"
    [[ -f "$dest" ]] && return 0
    
    cp -L "$lib" "$dest"
    fix_install_names "$dest" "$prefix"
}

main() {
    local gst_prefix=$(brew --prefix gstreamer)

    echo "=== Processing GStreamer plugins ==="
    for plugin in "${GSTREAMER_PLUGINS[@]}"; do
        local path="${gst_prefix}/lib/gstreamer-1.0/libgst${plugin}.dylib"
        [[ -f "$path" ]] && find_dependencies "$path" || echo "Warning: $plugin not found"
    done

    echo "=== Processing libraries ==="
    for entry in "${BUNDLE_LIBS[@]}"; do
        local formula="${entry%%:*}" libname="${entry#*:}"
        local path=$(get_lib_path "$formula" "$libname")
        [[ -n "$path" ]] && find_dependencies "$path" || echo "Warning: $formula not found"
    done

    echo "=== Copying ${#all_dylibs[@]} dylibs ==="
    for dylib in "${all_dylibs[@]}"; do copy_dylib "$dylib"; done

    [[ -d "${gst_prefix}/lib/gstreamer-1.0/include" ]] && {
        mkdir -p "${ENGINE_DIR}/lib/gstreamer-1.0"
        cp -a "${gst_prefix}/lib/gstreamer-1.0/include" "${ENGINE_DIR}/lib/gstreamer-1.0/"
    }

    echo "=== Fixing Wine .so files ==="
    for so in "${ENGINE_DIR}"/lib/wine/x86_64-unix/*.so(N); do
        otool -L "$so" 2>/dev/null | grep -q "/usr/local\|/opt/homebrew" && fix_install_names "$so" "@rpath/"
    done

    echo "=== Done: ${#all_dylibs[@]} dylibs bundled ==="
}

main "$@"
