# Builds the curated QML import directory handed to plugin engines.
# Symlinking a whole module directory readmits its submodules: QtQuick brings
# QtQuick.LocalStorage/.Dialogs/.Controls/.VirtualKeyboard, QtQml brings
# QtQml.XmlListModel/.StateMachine. XmlListModel fetches `source` through QNAM,
# which serves file:// without XMLHttpRequest's gate (QML_XHR_ALLOW_FILE_READ),
# so it gives plugins arbitrary local file read. Link the base module's files,
# then add submodules one at a time.
#
# Inputs: QT_QML_DIR, OUT_DIR
file(REMOVE_RECURSE "${OUT_DIR}")

# The curated modules: real directories we own, holding the base module's
# files and the named submodules only.
# QtQml/Models and WorkerScript are linked because QtQml's qmldir declares them
# (`import ... auto`). Their types resolve without the links anyway, through the
# process-global type registry (pinned by tst_plugincontainment::
# knownGap_cppRegisteredTypesResolveInPluginEngines), and they add nothing
# QtQuick lacks. XmlListModel and StateMachine are not declared by QtQml's
# qmldir and not in the static registry, so the missing link is what blocks
# XmlListModel.
set(_melo_modules QtQml QtQuick)
set(_melo_subs_QtQml Models WorkerScript)
set(_melo_subs_QtQuick Shapes)

foreach(mod ${_melo_modules})
    file(MAKE_DIRECTORY "${OUT_DIR}/${mod}")
    # Guard before anything is written INTO the module dir: it must be a real
    # directory we own. If a future edit ever links the whole module instead,
    # every CREATE_LINK below resolves THROUGH that symlink and writes into the
    # real Qt installation, corrupting the developer's Qt instead of failing.
    if(NOT IS_DIRECTORY "${OUT_DIR}/${mod}" OR IS_SYMLINK "${OUT_DIR}/${mod}")
        message(FATAL_ERROR "plugin import dir: ${OUT_DIR}/${mod} is not a real directory — links would be written into the Qt installation at ${QT_QML_DIR}")
    endif()

    # base module: files only, never the directory
    file(GLOB _files LIST_DIRECTORIES false "${QT_QML_DIR}/${mod}/*")
    foreach(f ${_files})
        get_filename_component(_n "${f}" NAME)
        file(CREATE_LINK "${f}" "${OUT_DIR}/${mod}/${_n}" SYMBOLIC)
    endforeach()

    # Also link the submodules the module's own qmldir auto-imports. Qt 6.7
    # splits QtQml's types into QtQml.Base and declares
    # `import QtQml.Base auto`; 6.10 has no such directory. Without
    # the link, plugin QML using QtObject fails with "QtObject is not a type".
    set(_melo_declared "")
    if(EXISTS "${QT_QML_DIR}/${mod}/qmldir")
        file(STRINGS "${QT_QML_DIR}/${mod}/qmldir" _melo_qmldir_imports
             REGEX "^import +${mod}\\.[A-Za-z0-9_]+ +auto")
        foreach(_melo_line IN LISTS _melo_qmldir_imports)
            string(REGEX REPLACE "^import +${mod}\\.([A-Za-z0-9_]+) +auto.*" "\\1"
                   _melo_sub "${_melo_line}")
            list(APPEND _melo_declared "${_melo_sub}")
        endforeach()
    endif()
    set(_melo_subs ${_melo_subs_${mod}} ${_melo_declared})
    list(REMOVE_DUPLICATES _melo_subs)

    # The denylist still wins over the declaration (XmlListModel: see the
    # header). A future Qt that auto-imports one of these gets a warning.
    foreach(_melo_denied XmlListModel StateMachine)
        # list(FIND), not IN_LIST: this file runs under `cmake -P`, where no
        # project policies are set and IN_LIST is not an operator.
        list(FIND _melo_declared "${_melo_denied}" _melo_denied_at)
        if(NOT _melo_denied_at EQUAL -1)
            message(WARNING "melo: ${mod}'s qmldir auto-imports ${mod}.${_melo_denied}, which the plugin import dir refuses to expose — plugin QML relying on it will not load, and ${mod} itself may not resolve cleanly")
        endif()
        list(REMOVE_ITEM _melo_subs ${_melo_denied})
    endforeach()

    # explicitly allowed submodules, one at a time
    foreach(sub ${_melo_subs})
        if(EXISTS "${QT_QML_DIR}/${mod}/${sub}")
            file(CREATE_LINK "${QT_QML_DIR}/${mod}/${sub}" "${OUT_DIR}/${mod}/${sub}" SYMBOLIC)
        else()
            # Plugin QML importing a missing submodule would otherwise fail
            # only at runtime.
            message(WARNING "melo: ${QT_QML_DIR}/${mod}/${sub} not found — the curated plugin import dir will NOT expose ${mod}.${sub}, and plugin QML importing it will fail to load")
        endif()
    endforeach()

    # Build assert: a missing or empty import dir must fail the build, never
    # fall back to full imports silently.
    if(NOT EXISTS "${OUT_DIR}/${mod}/qmldir")
        message(FATAL_ERROR "plugin import dir generation failed: ${OUT_DIR}/${mod}/qmldir missing")
    endif()
endforeach()

# Top-level allowlist. The submodule denylist below only catches names listed in
# advance, so widening the module list above (e.g. adding `Qt`) would readmit
# Qt.labs.folderlistmodel, Qt.labs.platform and Qt.labs.settings unnoticed. A
# new module has to be named here too.
file(GLOB _top RELATIVE "${OUT_DIR}" "${OUT_DIR}/*")
foreach(_entry ${_top})
    if(NOT _entry STREQUAL "QtQml" AND NOT _entry STREQUAL "QtQuick")
        message(FATAL_ERROR "plugin import dir exposes top-level module '${_entry}' — only QtQml and QtQuick are allowed; containment broken")
    endif()
endforeach()

# Submodule denylist, per module family. Named separately from the allowlist
# above so that re-linking a whole module directory fails the build rather than
# silently readmitting these.
set(_melo_blocked_QtQuick LocalStorage Dialogs Controls VirtualKeyboard)
set(_melo_blocked_QtQml XmlListModel StateMachine)
foreach(mod ${_melo_modules})
    foreach(blocked ${_melo_blocked_${mod}})
        if(EXISTS "${OUT_DIR}/${mod}/${blocked}")
            message(FATAL_ERROR "plugin import dir leaks ${mod}.${blocked} — containment broken")
        endif()
    endforeach()
endforeach()
message(STATUS "melo: plugin QML import dir generated at ${OUT_DIR}")
