cmake_minimum_required(VERSION 3.21)
project(melo VERSION 0.1.0 LANGUAGES C CXX)   # C: generated wayland protocol code

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The tree already builds clean under both; this keeps it that way. Not
# -Werror: melo is built by strangers on compilers we have never seen, and a
# new compiler's new warning should not be the reason someone can't build it.
if(NOT MSVC)
  add_compile_options(-Wall -Wextra)
endif()

# 6.5 is the minimum: QtQuick.Effects (MultiEffect) and
# QStyleHints::colorSchemeChanged both landed in 6.5 and have no fallback here.
# CI and the release builds use 6.11.2.
find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Quick OpenGL DBus Network)
# QuickPrivate exposes needsChildWindowStackingOrderUpdate, which arms Qt's
# whole-tree walk for QQuickWindowContainers (StackingWalkSuppressor, main.cpp):
# skipping it is 2.8x fewer late frames per pixel scrolled. Optional.
find_package(Qt6 COMPONENTS QuickPrivate QUIET)
if(NOT TARGET Qt6::QuickPrivate)
    message(WARNING "Qt6::QuickPrivate not found -- building without the "
                    "child-window stacking fix; scrolling will be slower. "
                    "Install the Qt Quick private headers to enable it.")
endif()
find_package(ZLIB REQUIRED)
qt_standard_project_setup()

if(UNIX AND NOT APPLE)
    find_package(PkgConfig REQUIRED)

    # Vendored, patched projectM 4 (scripts/setup-vendor.sh). Required — no v3 fallback.
    # A fresh checkout has none, so configure builds it once; CI runs the script
    # itself first (with --static) and this then finds the result and skips.
    set(PM4_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/vendor/projectm4")
    if(NOT EXISTS "${PM4_PREFIX}/lib64/pkgconfig/projectM-4.pc"
       AND NOT EXISTS "${PM4_PREFIX}/lib/pkgconfig/projectM-4.pc")
        message(STATUS "melo: building the vendored projectM 4 (first configure only)")
        execute_process(COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/scripts/setup-vendor.sh"
                        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                        RESULT_VARIABLE MELO_VENDOR_RC)
        if(NOT MELO_VENDOR_RC EQUAL 0)
            message(FATAL_ERROR "scripts/setup-vendor.sh failed (exit ${MELO_VENDOR_RC})")
        endif()
    endif()
    # libdir differs by distro: lib64 (Fedora) vs lib (Debian/Ubuntu CI)
    if(EXISTS "${PM4_PREFIX}/lib64/pkgconfig/projectM-4.pc")
        set(PM4_LIBDIR "${PM4_PREFIX}/lib64")
    elseif(EXISTS "${PM4_PREFIX}/lib/pkgconfig/projectM-4.pc")
        set(PM4_LIBDIR "${PM4_PREFIX}/lib")
    else()
        message(FATAL_ERROR "vendored projectM not found — run scripts/setup-vendor.sh first")
    endif()
    set(ENV{PKG_CONFIG_PATH} "${PM4_LIBDIR}/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    pkg_check_modules(PROJECTM REQUIRED IMPORTED_TARGET projectM-4 projectM-4-playlist)
    list(APPEND CMAKE_BUILD_RPATH "${PM4_LIBDIR}")
    # Build RPATH only: an install RPATH would point an installed melo back
    # into this checkout. install(TARGETS melo) puts the libraries beside the
    # binary, where $ORIGIN finds them. Vendored archives (setup-vendor.sh
    # --static, CI) link the --static closure so dead visualizer code drops out.
    set(MELO_PM_STATIC OFF)
    if(EXISTS "${PM4_LIBDIR}/libprojectM-4.a")
        set(MELO_PM_STATIC ON)
        message(STATUS "melo: projectM STATIC (${PM4_LIBDIR})")
    endif()

    pkg_check_modules(GST REQUIRED IMPORTED_TARGET
        gstreamer-1.0 gstreamer-app-1.0 gstreamer-audio-1.0)
    set(MELO_GST_LIB PkgConfig::GST)

    # KWin blur/contrast spoken natively (protocols/, src/core/WaylandBlur.h).
    # Needs QtGui private headers for the per-window wl_surface; falls back to
    # KF6 WindowSystem without them. The component must be requested: installed
    # headers alone do not create the target.
    find_package(Qt6 COMPONENTS GuiPrivate QUIET)
    # Debian/Ubuntu ship the GuiPrivate config in qt6-base-dev and the headers
    # in qt6-base-private-dev, so the target can point at a missing directory
    # and CMake fails only at generate time. Check the headers directly.
    set(MELO_GUI_PRIVATE_USABLE OFF)
    if(TARGET Qt6::GuiPrivate)
        set(MELO_GUI_PRIVATE_USABLE ON)
        get_target_property(_melo_qtgp_inc Qt6::GuiPrivate INTERFACE_INCLUDE_DIRECTORIES)
        foreach(_melo_d IN LISTS _melo_qtgp_inc)
            # generator expressions are not ours to resolve; only judge plain paths
            if(NOT _melo_d MATCHES "\\$<" AND NOT EXISTS "${_melo_d}")
                set(MELO_GUI_PRIVATE_USABLE OFF)
                message(STATUS "melo: Qt6::GuiPrivate is declared but ${_melo_d} is missing "
                               "— install the Qt 6 private headers (Debian/Ubuntu: "
                               "qt6-base-private-dev, Fedora: qt6-qtbase-private-devel) "
                               "for native blur; falling back to KF6")
            endif()
        endforeach()
    endif()
    if(MELO_GUI_PRIVATE_USABLE)
        set(MELO_NATIVE_BLUR ON)
        pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
        find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
        set(MELO_WL_GEN ${CMAKE_CURRENT_BINARY_DIR}/wl-protocols)
        file(MAKE_DIRECTORY ${MELO_WL_GEN})
        foreach(proto blur contrast)
            add_custom_command(
                OUTPUT ${MELO_WL_GEN}/${proto}-client-protocol.h
                       ${MELO_WL_GEN}/${proto}-protocol.c
                COMMAND ${WAYLAND_SCANNER} client-header
                        ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${proto}.xml
                        ${MELO_WL_GEN}/${proto}-client-protocol.h
                COMMAND ${WAYLAND_SCANNER} private-code
                        ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${proto}.xml
                        ${MELO_WL_GEN}/${proto}-protocol.c
                DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${proto}.xml)
            list(APPEND MELO_WL_SOURCES ${MELO_WL_GEN}/${proto}-protocol.c)
        endforeach()
        message(STATUS "melo: glass blur NATIVE (KWin wayland protocols)")
    else()
        message(STATUS "melo: QtGui private headers missing — trying KF6 blur fallback")
    endif()

    if(MELO_PM_STATIC)
        # imported target for INCLUDE dirs; --static closure appended for
        # the archives' private deps (GL, stdc++ ...)
        set(MELO_PM_LIBS PkgConfig::PROJECTM ${PROJECTM_STATIC_LDFLAGS})
    else()
        set(MELO_PM_LIBS PkgConfig::PROJECTM)
    endif()
    set(MELO_MEDIA_LIBS ${MELO_PM_LIBS} ${MELO_GST_LIB})
endif()

if(WIN32)
    # GStreamer + projectM come from vcpkg (toolchain file passed by CI).
    # projectM's own CMake package (built + installed in CI with the
    # caller-FBO patch applied) exports projectM::projectM / ::playlist.
    find_package(unofficial-gstreamer CONFIG QUIET)      # vcpkg port name
    find_package(PkgConfig)                              # vcpkg also ships .pc for gstreamer
    if(PkgConfig_FOUND)
        pkg_check_modules(GST REQUIRED IMPORTED_TARGET
            gstreamer-1.0 gstreamer-app-1.0 gstreamer-audio-1.0 gstreamer-pbutils-1.0)
        set(MELO_GST_LIB PkgConfig::GST)
    endif()
    # projectM4 + its playlist are SEPARATE CMake packages; targets are
    # namespaced libprojectM:: (verified from the installed projectM4Config)
    find_package(projectM4 CONFIG REQUIRED)
    find_package(projectM4Playlist CONFIG REQUIRED)
    set(MELO_MEDIA_LIBS ${MELO_GST_LIB} libprojectM::projectM libprojectM::playlist)
endif()

if(WIN32)
    set(MELO_WINDOWCTL src/core/WindowController_win.cpp)
else()
    set(MELO_WINDOWCTL src/core/WindowController_kwin.cpp)
endif()

qt_add_executable(melo
    src/main.cpp
    src/audio/AudioEngine.cpp
    src/audio/SourceDeck.cpp
    src/vis/ProjectMWrapper.cpp
    src/vis/VisualizerItem.cpp
    src/vis/SpectrumSource.cpp
    src/vis/BackgroundItem.cpp
    src/vis/ParticlesItem.cpp
    src/ui/BlendItem.cpp
    src/ui/WindowShapeItem.cpp
    src/media/ThumbImageProvider.cpp
    src/media/ThumbImageProvider.h
    src/core/PlaybackCoordinator.cpp
    src/core/SettingsStore.cpp
    src/core/ThemeStore.cpp
    src/core/ThemeFormat.cpp
    src/core/LibraryStore.cpp
    src/core/JsonRowModel.h
    src/core/MprisService.cpp
    src/core/PortalDialog.cpp
    ${MELO_WINDOWCTL}
    src/core/WindowController.h
    src/core/Track.h
    src/core/PlayerState.h
    src/core/QueueModel.h
    src/core/SuggestionsModel.h
    src/rpc/SidecarProcess.cpp
    src/rpc/NodeBootstrap.cpp
    src/rpc/NodeBootstrap.h
    src/rpc/RpcClient.cpp
    src/rpc/SidecarService.cpp
    src/plugins/CommandMap.cpp
    src/plugins/CommandMap.h
    src/plugins/InterceptMap.cpp
    src/plugins/InterceptMap.h
    src/plugins/Occupancy.cpp
    src/plugins/Occupancy.h
    src/plugins/SlotMap.cpp
    src/plugins/SlotMap.h
    src/plugins/BarButtons.cpp
    src/plugins/BarButtons.h
    src/plugins/PluginFills.h
    src/plugins/MeloUi.cpp
    src/plugins/MeloUi.h
    src/plugins/MeloUiArchives.cpp
    src/plugins/MeloUiArchives.h
    src/plugins/MeloUiQueueView.cpp
    src/plugins/MeloUiQueueView.h
    src/plugins/PluginImportDir.h
    src/plugins/PluginUiHost.cpp
    src/plugins/PluginUiHost.h
    src/plugins/PluginUiHub.cpp
    src/plugins/PluginUiHub.h
    src/plugins/PluginWindowHost.cpp
    src/plugins/PluginWindowHost.h
    src/plugins/PluginWindowsHub.cpp
    src/plugins/PluginWindowsHub.h
    src/plugins/ZipReader.cpp
    src/plugins/ZipReader.h
    src/plugins/SkinArchive.cpp
    src/plugins/SkinArchive.h
    src/plugins/SkinImageProvider.cpp
    src/plugins/SkinImageProvider.h
)

target_include_directories(melo PRIVATE src/audio src/vis src/rpc src/core src/plugins src/ui)
if(TARGET Qt6::QuickPrivate)
    target_compile_definitions(melo PRIVATE MELO_HAVE_QUICK_PRIVATE)
endif()
# The visualiser's presets. Fetched once when absent. Without them melo still
# builds and runs, the visualiser has nothing to show, and tst_visualizer skips.
if(UNIX AND NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/presets")
    message(STATUS "melo: fetching visualiser presets (first configure only)")
    execute_process(COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/scripts/fetch-presets.sh"
                    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                    RESULT_VARIABLE MELO_PRESETS_RC)
    if(NOT MELO_PRESETS_RC EQUAL 0)
        message(WARNING "could not fetch presets (exit ${MELO_PRESETS_RC}); "
                        "the visualiser will be empty. Retry: scripts/fetch-presets.sh")
    endif()
endif()

# The silence scan's ffmpeg: a 1.6 MB build of only what the scan uses
# (scripts/build-ffmpeg.sh). Installed beside melo. If it cannot be built,
# melo falls back to an ffmpeg on PATH, and without one skips no silence.
set(MELO_FFMPEG "${CMAKE_CURRENT_SOURCE_DIR}/vendor/ffmpeg/bin/ffmpeg")
if(UNIX AND NOT APPLE AND NOT EXISTS "${MELO_FFMPEG}")
    message(STATUS "melo: building the silence scan's ffmpeg (first configure only)")
    execute_process(COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build-ffmpeg.sh"
                    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                    OUTPUT_QUIET
                    RESULT_VARIABLE MELO_FFMPEG_RC)
    if(NOT MELO_FFMPEG_RC EQUAL 0)
        message(WARNING "could not build ffmpeg (exit ${MELO_FFMPEG_RC}); silence skipping "
                        "will need ffmpeg on PATH. Retry: scripts/build-ffmpeg.sh")
    endif()
endif()

# The Node sidecar is part of the build. pnpm installs its dependencies and
# bundles it into sidecar/dist, which melo runs from there in a dev build and
# installs from. Rebuilt when its sources or lockfile change.
find_program(MELO_PNPM NAMES pnpm pnpm.cmd)
if(NOT MELO_PNPM)
    message(FATAL_ERROR "pnpm not found. Install it: npm install -g pnpm")
endif()
file(GLOB_RECURSE MELO_SIDECAR_SRC CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/sidecar/src/*.ts")
list(FILTER MELO_SIDECAR_SRC EXCLUDE REGEX "\\.test\\.ts$")
set(MELO_SIDECAR_OUT
    "${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs"
    "${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-plugin-host.mjs")
add_custom_command(
    OUTPUT ${MELO_SIDECAR_OUT}
    # confirmModulesPurge=false: when pnpm wants to rebuild node_modules it
    # asks first, and with no terminal it aborts the build instead
    COMMAND "${MELO_PNPM}" install --frozen-lockfile --config.confirmModulesPurge=false
    COMMAND "${MELO_PNPM}" build
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/sidecar"
    DEPENDS ${MELO_SIDECAR_SRC}
            "${CMAKE_CURRENT_SOURCE_DIR}/sidecar/package.json"
            "${CMAKE_CURRENT_SOURCE_DIR}/sidecar/pnpm-lock.yaml"
    COMMENT "Building the sidecar"
    VERBATIM)
add_custom_target(melo_sidecar ALL DEPENDS ${MELO_SIDECAR_OUT})
add_dependencies(melo melo_sidecar)

target_compile_definitions(melo PRIVATE
    USE_PROJECTM4
    MELO_DEV_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src/qml"
    MELO_DEV_PRESET_DIR="${CMAKE_CURRENT_SOURCE_DIR}/vendor/presets"
    MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs"
    MELO_DEV_FFMPEG="${MELO_FFMPEG}"
    MELO_VERSION="${PROJECT_VERSION}"
)

# --- curated QML import directory for plugin engines ---
# Plugin QML resolves imports ONLY from here. See "What containment does not
# stop" in docs/plugins.md.
get_target_property(_melo_qmake Qt6::qmake IMPORTED_LOCATION)
execute_process(COMMAND ${_melo_qmake} -query QT_INSTALL_QML
                OUTPUT_VARIABLE MELO_QT_QML_DIR
                RESULT_VARIABLE _melo_qmake_result
                ERROR_VARIABLE _melo_qmake_stderr
                OUTPUT_STRIP_TRAILING_WHITESPACE)
# Diagnose a failed query HERE. Unchecked it yields an empty QT_QML_DIR, the
# generator makes dangling links, and the build dies on the qmldir assert
# pointing at an entirely wrong cause.
if(NOT _melo_qmake OR _melo_qmake MATCHES "NOTFOUND"
   OR NOT _melo_qmake_result EQUAL 0
   OR MELO_QT_QML_DIR STREQUAL ""
   OR NOT IS_DIRECTORY "${MELO_QT_QML_DIR}")
    message(FATAL_ERROR
        "cannot locate the Qt QML module dir — the curated plugin import dir cannot be built.\n"
        "  qmake:  ${_melo_qmake}\n"
        "  query:  QT_INSTALL_QML -> '${MELO_QT_QML_DIR}' (exit ${_melo_qmake_result})\n"
        "  stderr: ${_melo_qmake_stderr}")
endif()
set(MELO_PLUGIN_IMPORT_DIR "${CMAKE_BINARY_DIR}/plugin-qml-imports")
add_custom_target(melo_plugin_imports ALL
    COMMAND ${CMAKE_COMMAND}
            -DQT_QML_DIR=${MELO_QT_QML_DIR}
            -DOUT_DIR=${MELO_PLUGIN_IMPORT_DIR}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/GeneratePluginImports.cmake
    COMMENT "Generating curated QML import dir for plugin engines")
add_dependencies(melo melo_plugin_imports)
target_compile_definitions(melo PRIVATE
    MELO_DEV_PLUGIN_IMPORT_DIR="${MELO_PLUGIN_IMPORT_DIR}")
target_link_libraries(melo PRIVATE
    Qt6::Core Qt6::Gui Qt6::Quick Qt6::OpenGL Qt6::DBus Qt6::Network
    $<$<TARGET_EXISTS:Qt6::QuickPrivate>:Qt6::QuickPrivate>
    ZLIB::ZLIB
    ${MELO_MEDIA_LIBS}
)
if(MELO_NATIVE_BLUR)
    target_sources(melo PRIVATE src/core/WaylandBlur.cpp ${MELO_WL_SOURCES})
    target_include_directories(melo PRIVATE ${MELO_WL_GEN})
    target_compile_definitions(melo PRIVATE MELO_NATIVE_BLUR)
    target_link_libraries(melo PRIVATE Qt6::GuiPrivate PkgConfig::WAYLAND_CLIENT)
elseif(UNIX AND NOT APPLE)
    find_package(KF6WindowSystem QUIET)
    if(KF6WindowSystem_FOUND)
        target_link_libraries(melo PRIVATE KF6::WindowSystem)
        target_compile_definitions(melo PRIVATE HAVE_KWINDOWSYSTEM)
        message(STATUS "melo: KWin blur-behind via KF6 fallback")
    else()
        message(STATUS "melo: glass blur DISABLED (no QtGui private headers, no KF6)")
    endif()
endif()

# Static Qt: QML loads from the filesystem, so the engine cannot discover QML
# modules at runtime; scan the sources and import their static plugins. Qt's
# finalization auto-imports only the default platform plugin (xcb), so the
# wayland chain is imported here or KWin blur is lost. offscreen: smoke runs.
option(MELO_STATIC_QT "Building against a static Qt" OFF)
if(MELO_STATIC_QT)
    # Plugin engines take their import path from the RESOURCE tree in this
    # build; there is no directory of modules to point at. See PluginImportDir.h.
    target_compile_definitions(melo PRIVATE MELO_QT_STATIC=1)
    qt_import_qml_plugins(melo PATH_TO_SCAN ${CMAKE_CURRENT_SOURCE_DIR}/src/qml)
    find_package(Qt6 COMPONENTS WaylandClient QUIET)
    # QWebpPlugin: finalization does NOT import qtimageformats' plugins —
    # without it YouTube's webp thumbnails render blank in packaged builds
    foreach(p QWaylandIntegrationPlugin QWaylandEglPlatformIntegrationPlugin
              QWaylandEglClientBufferPlugin QWaylandBradientDecorationPlugin
              QOffscreenIntegrationPlugin QWebpPlugin)
        if(TARGET Qt6::${p})
            qt_import_plugins(melo INCLUDE Qt6::${p})
        else()
            message(WARNING "melo: static platform plugin missing: ${p}")
        endif()
    endforeach()
    # formats melo never decodes; tiff alone drags libtiff+libjpeg+libwebp
    # shared libs into the AppDir
    foreach(p QTiffPlugin QTgaPlugin QICNSPlugin QWbmpPlugin)
        if(TARGET Qt6::${p})
            qt_import_plugins(melo EXCLUDE Qt6::${p})
        endif()
    endforeach()
    # Qt's static archives are compiled -ffunction-sections for gc, but that
    # only reaches Qt's INTERNAL targets — melo's own link must opt in
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(melo PRIVATE -ffunction-sections -fdata-sections)
        target_link_options(melo PRIVATE -Wl,--gc-sections)
    endif()
    # Qt built -ltcg emits slim LTO objects: the final link MUST run -flto
    # (and melo's own objects join the whole-program optimisation)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT melo_ipo)
    if(melo_ipo)
        set_property(TARGET melo PROPERTY INTERPROCEDURAL_OPTIMIZATION ON)
    endif()
endif()
if(WIN32)
    target_link_libraries(melo PRIVATE user32 dwmapi)
    # GUI subsystem: no console window flashing up behind the app
    set_property(TARGET melo PROPERTY WIN32_EXECUTABLE ON)
endif()

# Glass blur: native KWin wayland protocols (WaylandBlur.cpp) — always on
# for UNIX; no external framework needed.

# --- fonts ---
# The default family has to BE there. Shipped alongside the binary, and read
# from the source tree when running from the build directory.
target_compile_definitions(melo PRIVATE
    MELO_FONT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts")
# --- install ---
# Exe-relative, matching what the packages already assemble: the binary at
# libexec/melo/, its QML, presets and fonts beside it, and a wrapper on PATH.
install(TARGETS melo RUNTIME DESTINATION libexec/melo)
if(EXISTS "${MELO_FFMPEG}")
    install(PROGRAMS "${MELO_FFMPEG}" DESTINATION libexec/melo)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/vendor/ffmpeg/COPYING.LGPLv2.1"
            DESTINATION share/melo RENAME ffmpeg-COPYING.LGPLv2.1 OPTIONAL)
endif()
if(UNIX AND NOT APPLE AND NOT MELO_PM_STATIC)
    install(DIRECTORY "${PM4_LIBDIR}/" DESTINATION libexec/melo
            FILES_MATCHING PATTERN "libprojectM-4*.so*")
endif()
install(DIRECTORY src/qml/ DESTINATION libexec/melo/melo-qml
        PATTERN "shaders/*.frag.in" EXCLUDE
        PATTERN "shaders/common.glsl" EXCLUDE
        PATTERN "shaders/build-shaders.sh" EXCLUDE)
install(DIRECTORY assets/fonts/ DESTINATION libexec/melo/fonts
        FILES_MATCHING PATTERN "*.otf" PATTERN "*.txt")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/presets")
    install(DIRECTORY vendor/presets/ DESTINATION libexec/melo/presets
            FILES_MATCHING PATTERN "*.milk")
endif()
install(DIRECTORY sidecar/dist/ DESTINATION share/melo/sidecar)
install(FILES resources/melo.desktop DESTINATION share/applications)
install(FILES resources/melo.png DESTINATION share/icons/hicolor/512x512/apps)
install(FILES resources/melo.svg DESTINATION share/icons/hicolor/scalable/apps)
install(FILES resources/melo.metainfo.xml DESTINATION share/metainfo OPTIONAL)
install(FILES LICENSE THIRD-PARTY.md DESTINATION share/doc/melo)
install(DIRECTORY LICENSES/ DESTINATION share/doc/melo/LICENSES)
# melo lives at libexec/melo/melo beside its tree; this wrapper is what the user
# and the .desktop file run. file(GENERATE), because install(CODE) ignores
# DESTDIR. Resolved relative to itself since `cmake --install --prefix` can
# override CMAKE_INSTALL_PREFIX.
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/melo-launcher"
     CONTENT "#!/bin/sh\nhere=$(cd \"$(dirname \"$(readlink -f \"$0\")\")\" && pwd)\nexec \"$here/../libexec/melo/melo\" \"$@\"\n")
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/melo-launcher"
        DESTINATION bin RENAME melo)

# --- shaders ---
# The QML is loaded from the filesystem, not a qrc, so the compiled shader has
# to sit next to the QML that names it. Generated, never edited, gitignored.
find_program(MELO_QSB NAMES qsb qsb-qt6
             HINTS "${QT6_INSTALL_PREFIX}/bin" /usr/lib64/qt6/bin /usr/lib/qt6/bin)
# Required: without qsb the blend and window-shape shaders are never generated
# and melo builds without layer blending or window shapes.
if(NOT MELO_QSB)
    message(FATAL_ERROR "qsb (Qt Shader Tools) not found. Install qt6-qtshadertools-devel "
                        "(Fedora) or qt6-shadertools-dev (Debian, Ubuntu).")
endif()
if(MELO_QSB)
    set(MELO_SHADER_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/nowplaying/vinyl.frag)
    set(MELO_SHADER_QSB ${MELO_SHADER_SRC}.qsb)
    foreach(halo haloblur halocut halodilate styled imagefill edgex edgey stackblend bordermask)
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/${halo}.frag.qsb
            COMMAND ${MELO_QSB} --glsl "300es,120,150" --hlsl 50 --msl 12
                    -o ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/${halo}.frag.qsb
                    ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/${halo}.frag
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/${halo}.frag
            COMMENT "qsb ${halo}.frag")
        list(APPEND MELO_HALO_QSB ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/${halo}.frag.qsb)
    endforeach()
    set(MELO_HUELUM_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/qml/components/huelum.frag)
    add_custom_command(
        OUTPUT ${MELO_HUELUM_SRC}.qsb
        COMMAND ${MELO_QSB} --glsl "300es,120,150" --hlsl 50 --msl 12
                -o ${MELO_HUELUM_SRC}.qsb ${MELO_HUELUM_SRC}
        DEPENDS ${MELO_HUELUM_SRC}
        COMMENT "qsb huelum.frag")
    add_custom_command(
        OUTPUT ${MELO_SHADER_QSB}
        COMMAND ${MELO_QSB} --glsl "300es,120,150" --hlsl 50 --msl 12
                -o ${MELO_SHADER_QSB} ${MELO_SHADER_SRC}
        DEPENDS ${MELO_SHADER_SRC}
        COMMENT "qsb vinyl.frag")
    # BlendItem's material shaders are compiled into the binary rather than
    # dropped beside the QML: a C++ material resolves them by path at render
    # time, and a path into the QML directory would make the scene graph
    # depend on where the QML happens to live.
    set(MELO_BLEND_QSB "")
    foreach(stage vert frag)
        # -b on the vertex stage only: the batch renderer rewrites the vertex
        # shader for z ordering and needs a batchable variant. Without it every
        # BlendRect draws nothing ("No rewriter-inserted attribute found").
        set(_b "")
        if(stage STREQUAL "vert")
            set(_b "-b")
        endif()
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/blend.${stage}.qsb
            COMMAND ${MELO_QSB} ${_b} --glsl "300es,120,150" --hlsl 50 --msl 12
                    -o ${CMAKE_CURRENT_BINARY_DIR}/blend.${stage}.qsb
                    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/blend.${stage}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/blend.${stage}
            COMMENT "qsb blend.${stage}")
        list(APPEND MELO_BLEND_QSB ${CMAKE_CURRENT_BINARY_DIR}/blend.${stage}.qsb)
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/blend_tex.${stage}.qsb
            COMMAND ${MELO_QSB} ${_b} --glsl "300es,120,150" --hlsl 50 --msl 12
                    -o ${CMAKE_CURRENT_BINARY_DIR}/blend_tex.${stage}.qsb
                    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/blend_tex.${stage}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/blend_tex.${stage}
            COMMENT "qsb blend_tex.${stage}")
        list(APPEND MELO_BLEND_QSB ${CMAKE_CURRENT_BINARY_DIR}/blend_tex.${stage}.qsb)
        add_custom_command(
            OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/windowshape.${stage}.qsb
            COMMAND ${MELO_QSB} ${_b} --glsl "300es,120,150" --hlsl 50 --msl 12
                    -o ${CMAKE_CURRENT_BINARY_DIR}/windowshape.${stage}.qsb
                    ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/windowshape.${stage}
            DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/ui/shaders/windowshape.${stage}
            COMMENT "qsb windowshape.${stage}")
        list(APPEND MELO_BLEND_QSB ${CMAKE_CURRENT_BINARY_DIR}/windowshape.${stage}.qsb)
    endforeach()
    set_source_files_properties(${MELO_BLEND_QSB} PROPERTIES GENERATED TRUE)
    qt_add_resources(melo "melo_blend_shaders"
        PREFIX "/melo/shaders"
        BASE ${CMAKE_CURRENT_BINARY_DIR}
        FILES ${MELO_BLEND_QSB})

    add_custom_target(melo_shaders DEPENDS ${MELO_SHADER_QSB} ${MELO_HUELUM_SRC}.qsb ${MELO_HALO_QSB} ${MELO_BLEND_QSB})
    add_dependencies(melo melo_shaders)
endif()

# --- unit tests (built only when Qt6Test is present) ---
find_package(Qt6 COMPONENTS Test QUIET)
if(Qt6Test_FOUND)
    enable_testing()
    # A theme key QML writes but ThemeStore does not allow is a control that
    # silently never latches. Compare the two files.
    add_executable(tst_themekeys tests/cpp/tst_themekeys.cpp)
    target_compile_definitions(tst_themekeys PRIVATE
        MELO_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(tst_themekeys PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME themekeys COMMAND tst_themekeys)

    # The theme format's pure functions. Links the real ThemeFormat.
    add_executable(tst_themeformat tests/cpp/tst_themeformat.cpp src/core/ThemeFormat.cpp)
    target_include_directories(tst_themeformat PRIVATE src/core)
    target_link_libraries(tst_themeformat PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME themeformat COMMAND tst_themeformat)


    # Swatches at the level of the theme: the ui.themeSwatches override
    # answering instead of the theme's own, the union a save writes, and
    # Discard putting the theme's own back. A real ThemeStore over a temp
    # MELO_CONFIG_DIR, with the sidecar never started.
    add_executable(tst_themeswatches
        tests/cpp/tst_themeswatches.cpp
        src/core/ThemeStore.cpp
        src/core/ThemeFormat.cpp
        src/core/SettingsStore.cpp
        src/rpc/SidecarService.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/RpcClient.cpp
        src/rpc/NodeBootstrap.cpp)
    target_include_directories(tst_themeswatches PRIVATE src/core src/rpc)
    target_link_libraries(tst_themeswatches PRIVATE Qt6::Gui Qt6::Qml Qt6::Test)
    add_test(NAME themeswatches COMMAND tst_themeswatches)
    set_tests_properties(themeswatches PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

    add_executable(tst_themedefault
        tests/cpp/tst_themedefault.cpp
        src/core/ThemeStore.cpp
        src/core/ThemeFormat.cpp
        src/core/SettingsStore.cpp
        src/rpc/SidecarService.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/RpcClient.cpp
        src/rpc/NodeBootstrap.cpp)
    target_include_directories(tst_themedefault PRIVATE src/core src/rpc)
    target_link_libraries(tst_themedefault PRIVATE Qt6::Gui Qt6::Qml Qt6::Test)
    add_test(NAME themedefault COMMAND tst_themedefault)
    set_tests_properties(themedefault PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

    # An SVG folded into a glyph entry: the viewBox, the shapes, the one
    # translate that folds, and the files it has to refuse. Pure ThemeFormat,
    # so the samples are strings rather than files on disk.
    add_executable(tst_glyphimport tests/cpp/tst_glyphimport.cpp src/core/ThemeFormat.cpp)
    target_include_directories(tst_glyphimport PRIVATE src/core)
    target_link_libraries(tst_glyphimport PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME glyphimport COMMAND tst_glyphimport)

    # The QML->C++ QVariant boundary, where a JS object becomes null unless it
    # is unwrapped. Needs Qml for QJSEngine.
    add_executable(tst_jsboundary tests/cpp/tst_jsboundary.cpp)
    target_include_directories(tst_jsboundary PRIVATE src/core)
    target_link_libraries(tst_jsboundary PRIVATE Qt6::Gui Qt6::Qml Qt6::Test)
    add_test(NAME jsboundary COMMAND tst_jsboundary)

    # Font family and size are settings; a box around text drawn at a literal
    # pixel count is not. Both have clipped real labels here.
    add_executable(tst_fontreactive tests/cpp/tst_fontreactive.cpp)
    target_compile_definitions(tst_fontreactive PRIVATE
        MELO_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(tst_fontreactive PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME fontreactive COMMAND tst_fontreactive)

    # The QML suites. The runner must come from the Qt we build against: the
    # distro's /usr/bin/qmltestrunner-qt6 fails every suite on a library
    # mismatch. Ask the imported qmake where its own bin directory is, and look
    # there first.
    get_target_property(_melo_qmake_exe Qt6::qmake IMPORTED_LOCATION)
    get_filename_component(_melo_qt_bin "${_melo_qmake_exe}" DIRECTORY)
    # NAMES_PER_DIR matters as much as the hint: without it find_program looks
    # for the FIRST name in every directory before trying the second, so the
    # distro's qmltestrunner-qt6 in /usr/bin would beat the plain qmltestrunner
    # sitting in the Qt we are actually building against.
    find_program(MELO_QMLTESTRUNNER NAMES qmltestrunner-qt6 qmltestrunner
                 NAMES_PER_DIR
                 HINTS "${_melo_qt_bin}" "${QT6_INSTALL_PREFIX}/bin"
                       /usr/lib64/qt6/bin /usr/lib/qt6/bin)
    if(MELO_QMLTESTRUNNER)
        file(GLOB MELO_QML_TESTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/qml/tst_*.qml")
        foreach(qt_file ${MELO_QML_TESTS})
            get_filename_component(qt_name ${qt_file} NAME_WE)
            # Offscreen defaults to the software scene graph, which skips every
            # ShaderEffect case. With an X display (xvfb in CI) the offscreen
            # platform can create a GLX context, so render through OpenGL; with
            # none, forcing OpenGL crashes the runner, so keep the default.
            if(UNIX)
                add_test(NAME ${qt_name}
                         COMMAND sh -c "if [ -n \"$DISPLAY\" ]; then export QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl; fi; exec \"$0\" -input \"$1\""
                                 ${MELO_QMLTESTRUNNER} ${qt_file})
            else()
                add_test(NAME ${qt_name}
                         COMMAND ${MELO_QMLTESTRUNNER} -input ${qt_file})
            endif()
            # offscreen: these run in CI and over ssh, where there is no display
            set_tests_properties(${qt_name} PROPERTIES
                ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
        endforeach()
        # an SVG picture's reported size depends on the device pixel ratio
        add_test(NAME tst_imagefills_dpr-scaled
                 COMMAND ${MELO_QMLTESTRUNNER} -input
                         ${CMAKE_CURRENT_SOURCE_DIR}/tests/qml/tst_imagefills_dpr.qml)
        set_tests_properties(tst_imagefills_dpr-scaled PROPERTIES
            ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_SCALE_FACTOR=2")
    else()
        message(WARNING "qmltestrunner not found — the QML suites will not run")
    endif()
    # these draw with the GPU and compare grabs; in parallel they miss frames
    foreach(t tst_styledfills tst_edgefills tst_imagefills tst_imagefills_dpr
              tst_toonfills tst_borderblur tst_fillcache tst_scrollfills)
        if(TEST ${t})
            set_tests_properties(${t} PROPERTIES RUN_SERIAL TRUE)
        endif()
    endforeach()
    include(tests/local.cmake OPTIONAL)

    add_executable(tst_jsonrowmodel tests/cpp/tst_jsonrowmodel.cpp src/core/JsonRowModel.h)
    target_include_directories(tst_jsonrowmodel PRIVATE src/core)
    target_link_libraries(tst_jsonrowmodel PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME jsonrowmodel COMMAND tst_jsonrowmodel)

    # Who gets to switch the FFT on: SpectrumSource alone, Qt6::Core only. The
    # host side of the wiring is asserted in tst_windowsnap.
    add_executable(tst_spectrumarbiter
        tests/cpp/tst_spectrumarbiter.cpp
        src/vis/SpectrumSource.cpp
        src/vis/SpectrumSource.h)
    target_include_directories(tst_spectrumarbiter PRIVATE src/vis)
    target_link_libraries(tst_spectrumarbiter PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME spectrumarbiter COMMAND tst_spectrumarbiter)

    # Renders one projectM frame through the real item into a real FBO and
    # asserts the pixels are not all black; logs cannot show a black
    # visualiser. Skips without a GL 3.3 context rather than failing on a
    # machine that cannot answer.
    if(UNIX AND NOT APPLE AND MELO_MEDIA_LIBS)
        # BlendRect's claim is that the HARDWARE blends it with the real
        # framebuffer. Only pixels can confirm that, so this one renders.
        add_executable(tst_blendmodes tests/cpp/tst_blendmodes.cpp src/ui/BlendItem.cpp)
        target_include_directories(tst_blendmodes PRIVATE src/ui)
        target_link_libraries(tst_blendmodes PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
        target_compile_definitions(tst_blendmodes PRIVATE
            MELO_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src/qml")
        qt_add_resources(tst_blendmodes "tst_blend_shaders"
            PREFIX "/melo/shaders"
            BASE ${CMAKE_CURRENT_BINARY_DIR}
            FILES ${MELO_BLEND_QSB})
        add_dependencies(tst_blendmodes melo_shaders)
        # Not offscreen: it loads the software adaptation, which has no custom
        # materials, so every BlendRect draws nothing and the suite passes
        # vacuously. CI runs ctest under xvfb; initTestCase skips without GL.
        add_test(NAME blendmodes COMMAND tst_blendmodes)

        # The window's shape as geometry: the SVG path reader, the nine-slice
        # stretch and the input region a shape writes. What it draws is
        # checked by eye; what it clicks is checked here.
        add_executable(tst_windowmask tests/cpp/tst_windowmask.cpp src/ui/WindowShapeItem.cpp)
        target_include_directories(tst_windowmask PRIVATE src/ui)
        target_link_libraries(tst_windowmask PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
        add_test(NAME windowmask COMMAND tst_windowmask)
        set_tests_properties(windowmask PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
        # ...and again where a device pixel is not a logical one: every
        # distance the border reads is in logical pixels and the field it reads
        # them from is not, which is exactly where the two can part company
        add_test(NAME windowmask-scaled COMMAND tst_windowmask)
        set_tests_properties(windowmask-scaled PROPERTIES
            ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_SCALE_FACTOR=2")

        add_executable(tst_visualizer
            tests/cpp/tst_visualizer.cpp
            src/vis/VisualizerItem.cpp
            src/vis/VisualizerItem.h
            src/vis/ProjectMWrapper.cpp
            src/vis/ProjectMWrapper.h)
        target_include_directories(tst_visualizer PRIVATE src/vis src/audio)
        target_compile_definitions(tst_visualizer PRIVATE
            USE_PROJECTM4    # same API selection the melo target makes
            MELO_DEV_PRESET_DIR="${CMAKE_CURRENT_SOURCE_DIR}/vendor/presets")
        target_link_libraries(tst_visualizer PRIVATE
            Qt6::Gui Qt6::Quick Qt6::OpenGL Qt6::Test ${MELO_PM_LIBS})
        add_test(NAME visualizer COMMAND tst_visualizer)
    endif()

    # Containment regression test for the plugin QML engine.
    # MELO_DEV_PLUGIN_IMPORT_DIR is defined on `melo` only, so this target
    # defines it for PluginImportDir.h. MeloUiArchives takes a settings getter, not a
    # MeloUiSettings*, so it links without the coordinator/sidecar/gstreamer
    # world.
    add_executable(tst_plugincontainment
        tests/cpp/tst_plugincontainment.cpp
        src/plugins/PluginUiHost.cpp
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp)
    target_include_directories(tst_plugincontainment PRIVATE src/plugins src/core src/vis)
    target_compile_definitions(tst_plugincontainment PRIVATE
        MELO_DEV_PLUGIN_IMPORT_DIR="${MELO_PLUGIN_IMPORT_DIR}"
        MELO_TEST_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        # melo's QQmlApplicationEngine cannot be built in a unit test, so
        # onlyPluginUiHostRegistersTheArchiveProvider() scans the repo (not just
        # src/, so helpers elsewhere are caught) for addImageProvider calls.
        MELO_REPO_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(tst_plugincontainment PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test ZLIB::ZLIB)
    add_dependencies(tst_plugincontainment melo_plugin_imports)
    add_test(NAME plugincontainment COMMAND tst_plugincontainment)

    # Content fidelity + containment for the queue view a plugin is handed.
    # MeloUiQueueView has its own translation unit precisely so this links
    # against QueueModel alone — keep it that way.
    add_executable(tst_queueview
        tests/cpp/tst_queueview.cpp
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h)
    target_include_directories(tst_queueview PRIVATE src/plugins src/core)
    target_link_libraries(tst_queueview PRIVATE Qt6::Core Qt6::Qml Qt6::Test)
    add_test(NAME queueview COMMAND tst_queueview)

    # EQ curve, preamp and balance. AudioEngine IS constructible here: the test
    # sets MELO_FAKE_SINK, which swaps the audio sink for a fakesink, so the
    # pipeline builds without a device. Balance stays at the PlayerState seam.
    add_executable(tst_audioengine
        tests/cpp/tst_audioengine.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp
        src/core/PlayerState.h
        src/core/Track.h)
    target_include_directories(tst_audioengine PRIVATE src/audio src/core src/vis)
    target_link_libraries(tst_audioengine PRIVATE
        Qt6::Core Qt6::Qml Qt6::Test ${MELO_GST_LIB})
    add_test(NAME audioengine COMMAND tst_audioengine)

    add_executable(tst_pcmqueue tests/cpp/tst_pcmqueue.cpp)
    target_include_directories(tst_pcmqueue PRIVATE src/audio)
    target_link_libraries(tst_pcmqueue PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME pcmqueue COMMAND tst_pcmqueue)

    add_executable(tst_queuemodel tests/cpp/tst_queuemodel.cpp src/core/QueueModel.h src/core/Track.h)
    target_include_directories(tst_queuemodel PRIVATE src/core)
    target_link_libraries(tst_queuemodel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Test)
    add_test(NAME queuemodel COMMAND tst_queuemodel)

    # EQ write direction: a plugin moves a band, melo's EQ window follows, the
    # saved preset is untouched. Real EqWindow.qml -> MeloUiEq ->
    # PlaybackCoordinator -> AudioEngine; Settings and WindowCtl are stubbed.
    # SidecarService is never start()ed; its constructor only wires signals.
    add_executable(tst_eqsync
        tests/cpp/tst_eqsync.cpp
        src/plugins/MeloUi.cpp
        src/plugins/MeloUi.h
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/core/PlayerState.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h
        src/core/PlaybackCoordinator.cpp
        src/core/SettingsStore.cpp
        src/rpc/SidecarService.cpp
        src/rpc/RpcClient.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/NodeBootstrap.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp)
    target_include_directories(tst_eqsync PRIVATE src/plugins src/core src/rpc src/audio src/vis)
    target_compile_definitions(tst_eqsync PRIVATE
        MELO_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/src/qml"
        MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs")
    target_link_libraries(tst_eqsync PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::Test ZLIB::ZLIB ${MELO_GST_LIB})
    add_test(NAME eqsync COMMAND tst_eqsync)

    # Shuffle/repeat sequencing. Drives the REAL PlaybackCoordinator::advance()
    # via the engine's trackEnded signal, because the ruling under test is that
    # end-of-track and manual next share one policy path — a stand-in for the
    # coordinator could not show that. Same headless seam as tst_eqsync.
    add_executable(tst_advancepolicy
        tests/cpp/tst_advancepolicy.cpp
        src/plugins/MeloUi.cpp
        src/plugins/MeloUi.h
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/core/PlayerState.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h
        src/core/PlaybackCoordinator.cpp
        src/core/SettingsStore.cpp
        src/rpc/SidecarService.cpp
        src/rpc/RpcClient.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/NodeBootstrap.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp)
    target_include_directories(tst_advancepolicy PRIVATE src/plugins src/core src/rpc src/audio src/vis)
    target_compile_definitions(tst_advancepolicy PRIVATE
        MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs")
    target_link_libraries(tst_advancepolicy PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::Test ZLIB::ZLIB ${MELO_GST_LIB})
    add_test(NAME advancepolicy COMMAND tst_advancepolicy)

    # Window shaping from region.txt, on the real PluginWindowHost and real
    # offscreen QQuickWindows: the shape and the silence rule share
    # QWindow::setMask, so a stand-in host could not show a collision. The
    # MeloUi cone is linked with null dependencies and never started.
    add_executable(tst_windowshape
        tests/cpp/tst_windowshape.cpp
        src/plugins/PluginWindowHost.cpp
        src/plugins/PluginWindowHost.h
        src/plugins/PluginUiHost.cpp
        src/plugins/MeloUi.cpp
        src/plugins/MeloUi.h
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp
        src/core/PlayerState.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h
        src/core/PlaybackCoordinator.cpp
        src/core/SettingsStore.cpp
        src/core/WindowController.h
        ${MELO_WINDOWCTL}
        src/rpc/SidecarService.cpp
        src/rpc/RpcClient.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/NodeBootstrap.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp)
    target_include_directories(tst_windowshape PRIVATE
        src/plugins src/core src/rpc src/audio src/vis)
    target_compile_definitions(tst_windowshape PRIVATE
        MELO_DEV_PLUGIN_IMPORT_DIR="${MELO_PLUGIN_IMPORT_DIR}"
        MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs")
    target_link_libraries(tst_windowshape PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::DBus Qt6::Test
        ZLIB::ZLIB ${MELO_GST_LIB})
    add_dependencies(tst_windowshape melo_plugin_imports)
    add_test(NAME windowshape COMMAND tst_windowshape)

    # Per-window compositor geometry and drag snapping on real QQuickWindows
    # (same cone as tst_windowshape). Runs the generated KWin script in a
    # QJSEngine against a fake `workspace` to test the pid guard.
    add_executable(tst_windowsnap
        tests/cpp/tst_windowsnap.cpp
        src/plugins/PluginWindowHost.cpp
        src/plugins/PluginWindowHost.h
        src/plugins/PluginUiHost.cpp
        src/plugins/MeloUi.cpp
        src/plugins/MeloUi.h
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp
        src/core/PlayerState.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h
        src/core/PlaybackCoordinator.cpp
        src/core/SettingsStore.cpp
        src/core/WindowController.h
        ${MELO_WINDOWCTL}
        src/rpc/SidecarService.cpp
        src/rpc/RpcClient.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/NodeBootstrap.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp)
    target_include_directories(tst_windowsnap PRIVATE
        src/plugins src/core src/rpc src/audio src/vis)
    target_compile_definitions(tst_windowsnap PRIVATE
        MELO_DEV_PLUGIN_IMPORT_DIR="${MELO_PLUGIN_IMPORT_DIR}"
        MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs"
        # The window tests hand a REAL multi-window manifest to the real host;
        # tests/fixtures/skin-plugin carries its declaration.
        MELO_TEST_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
        # docs/plugins.md is read by everyFacadeMemberIsInTheDocs.
        MELO_REPO_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(tst_windowsnap PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::DBus Qt6::Test
        ZLIB::ZLIB ${MELO_GST_LIB})
    add_dependencies(tst_windowsnap melo_plugin_imports)
    add_test(NAME windowsnap COMMAND tst_windowsnap)

    # The forwarder Main.qml uses once several plugins own windows. Only the
    # empty hub is driven, but PluginWindowsHub.cpp calls
    # PluginWindowHost::setActive/opacityEntries, so the whole cone links.
    # Populated-hub behaviour is covered by tst_windowsnap and tst_windowshape.
    add_executable(tst_pluginwindowshub
        tests/cpp/tst_pluginwindowshub.cpp
        src/plugins/PluginWindowsHub.cpp
        src/plugins/PluginWindowsHub.h
        src/plugins/PluginWindowHost.cpp
        src/plugins/PluginWindowHost.h
        src/plugins/PluginUiHost.cpp
        src/plugins/MeloUi.cpp
        src/plugins/MeloUi.h
        src/plugins/MeloUiArchives.cpp
        src/plugins/MeloUiArchives.h
        src/plugins/MeloUiQueueView.cpp
        src/plugins/MeloUiQueueView.h
        src/plugins/SkinArchive.cpp
        src/plugins/SkinImageProvider.cpp
        src/plugins/ZipReader.cpp
        src/core/PlayerState.h
        src/core/QueueModel.h
        src/core/SuggestionsModel.h
        src/core/Track.h
        src/core/PlaybackCoordinator.cpp
        src/core/SettingsStore.cpp
        src/core/WindowController.h
        ${MELO_WINDOWCTL}
        src/rpc/SidecarService.cpp
        src/rpc/RpcClient.cpp
        src/rpc/SidecarProcess.cpp
        src/rpc/NodeBootstrap.cpp
        src/audio/AudioEngine.cpp
        src/audio/SourceDeck.cpp
        src/vis/SpectrumSource.cpp)
    target_include_directories(tst_pluginwindowshub PRIVATE
        src/plugins src/core src/rpc src/audio src/vis)
    target_compile_definitions(tst_pluginwindowshub PRIVATE
        MELO_DEV_PLUGIN_IMPORT_DIR="${MELO_PLUGIN_IMPORT_DIR}"
        MELO_DEV_SIDECAR="${CMAKE_CURRENT_SOURCE_DIR}/sidecar/dist/melo-sidecar.mjs")
    target_link_libraries(tst_pluginwindowshub PRIVATE
        Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::DBus Qt6::Test
        ZLIB::ZLIB ${MELO_GST_LIB})
    add_dependencies(tst_pluginwindowshub melo_plugin_imports)
    add_test(NAME pluginwindowshub COMMAND tst_pluginwindowshub)

    # Gesture occupancy, application QShortcut, plugin-id split. No
    # PluginWindowHost: this binary is the map, not the chrome that fires it.
    add_executable(tst_commandmap
        tests/cpp/tst_commandmap.cpp
        src/plugins/CommandMap.cpp
        src/plugins/CommandMap.h)
    target_include_directories(tst_commandmap PRIVATE src/plugins)
    target_link_libraries(tst_commandmap PRIVATE Qt6::Gui Qt6::Test)
    add_test(NAME commandmap COMMAND tst_commandmap)

    add_executable(tst_barbuttons
        tests/cpp/tst_barbuttons.cpp
        src/plugins/BarButtons.cpp
        src/plugins/BarButtons.h)
    target_include_directories(tst_barbuttons PRIVATE src/plugins)
    target_link_libraries(tst_barbuttons PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME barbuttons COMMAND tst_barbuttons)

    add_executable(tst_slotmap
        tests/cpp/tst_slotmap.cpp
        src/plugins/SlotMap.cpp
        src/plugins/SlotMap.h
        src/plugins/Occupancy.cpp
        src/plugins/Occupancy.h)
    target_include_directories(tst_slotmap PRIVATE src/plugins)
    target_link_libraries(tst_slotmap PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME slotmap COMMAND tst_slotmap)

    add_executable(tst_occupancy
        tests/cpp/tst_occupancy.cpp
        src/plugins/Occupancy.cpp
        src/plugins/Occupancy.h)
    target_include_directories(tst_occupancy PRIVATE src/plugins)
    target_link_libraries(tst_occupancy PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME occupancy COMMAND tst_occupancy)

    add_executable(tst_interceptmap
        tests/cpp/tst_interceptmap.cpp
        src/plugins/InterceptMap.cpp
        src/plugins/InterceptMap.h
        src/plugins/Occupancy.cpp
        src/plugins/Occupancy.h)
    target_include_directories(tst_interceptmap PRIVATE src/plugins)
    target_link_libraries(tst_interceptmap PRIVATE Qt6::Core Qt6::Test)
    add_test(NAME interceptmap COMMAND tst_interceptmap)

    # Every test gets a TIMEOUT (ctest default: 1500s) because the failure mode
    # is a hang, e.g. a fifo opened without O_NONBLOCK (MeloUiArchives.cpp),
    # which no in-test timing assertion can catch. Values are generous multiples
    # of observed runtimes; containment races a real symlink swap for 3s.
    set_tests_properties(plugincontainment PROPERTIES TIMEOUT 60)    # ~3.5s
    set_tests_properties(jsonrowmodel      PROPERTIES TIMEOUT 30)
    set_tests_properties(queueview         PROPERTIES TIMEOUT 30)
    # Two rows WAIT OUT the 16ms analysis timer to observe what did or did not
    # reach the ring, so a broken build hangs in qWait rather than answering
    # wrongly. ctest is the detector.
    set_tests_properties(spectrumarbiter   PROPERTIES TIMEOUT 30)    # ~0.3s
    # Builds real windows offscreen; two of its rows are elapsed-time bounds on
    # a hostile argument, so the ctest timeout is the outer guard for a scan
    # conversion that never returns.
    set_tests_properties(windowshape       PROPERTIES TIMEOUT 60)
    # Real windows offscreen again, and several rows WAIT OUT the host's 120ms
    # settle timer to prove nothing happened. The cycle row's failure mode is a
    # walk that never returns, so ctest is the outer guard there.
    set_tests_properties(windowsnap        PROPERTIES TIMEOUT 60)
    # No windows, no timers: one construction and two reads.
    set_tests_properties(pluginwindowshub  PROPERTIES TIMEOUT 30)
    # Occupancy, key install, typing flag. QShortcut needs QGuiApplication
    # (QTEST_MAIN + Qt6::Gui); no PluginWindowHost, no live windows.
    set_tests_properties(commandmap        PROPERTIES TIMEOUT 30)
    set_tests_properties(interceptmap      PROPERTIES TIMEOUT 30)
    # gstreamer builds a real pipeline; slower, and slower again on a cold runner
    set_tests_properties(audioengine       PROPERTIES TIMEOUT 120)
    set_tests_properties(eqsync            PROPERTIES TIMEOUT 120)
    set_tests_properties(advancepolicy     PROPERTIES TIMEOUT 120)

    # LeakSanitizer suppressions for GStreamer's registry, the session bus and
    # the GL driver. set_property(TEST ... APPEND), since the QML suites already
    # set QT_QPA_PLATFORM and set_tests_properties cannot APPEND. The file is
    # optional because LSan aborts on an unreadable suppressions path.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/lsan-suppressions.txt")
        get_property(_melo_tests DIRECTORY PROPERTY TESTS)
        set_property(TEST ${_melo_tests} APPEND PROPERTY ENVIRONMENT
            "LSAN_OPTIONS=suppressions=${CMAKE_CURRENT_SOURCE_DIR}/tests/lsan-suppressions.txt")
    endif()
endif()

include(src/dev/dev.cmake OPTIONAL)
