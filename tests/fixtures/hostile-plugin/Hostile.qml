// A malicious ui plugin: reports what it reaches through MeloUi, the only
// object it is given; every `true` under a "reached"/"resolved" key is a
// containment failure. It reports through MeloUi because a second context
// property would break rule (2), "no context properties except the bridge".
import QtQuick

Item {
    id: plugin

    // A failed name lookup is a ReferenceError in QML, not `undefined`, so every
    // probe runs inside a catch. A throwing probe means "not reachable", never
    // "the fixture aborted half way and the rest went unreported".
    function probe(f) { try { return f() } catch (e) { return false } }

    // The MeloUi.archives probe. Kept alive as a property rather than created
    // and dropped inside onCompleted, because the C++ side runs it a SECOND
    // time after changing the plugin's setting under it — that pass is the
    // reload path, and a probe that had already been destroyed could not see it.
    property var archiveProbe: null
    function runArchives(tag) { if (archiveProbe) archiveProbe.run(tag) }

    // Walks up `parent` looking for a shell object. Called once here (nothing is
    // attached yet at Component.onCompleted time) and again from C++ AFTER the
    // host has reparented this item — that second call is the one that matters,
    // because it runs in the state a real plugin window lives in.
    function runTreeWalk(tag) {
        var reached = false, hops = 0, p = plugin.parent
        while (p && hops < 12) {
            if (probe(function() { return p.shellRef !== undefined && p.shellRef !== null })) {
                reached = true; break
            }
            p = p.parent; hops++
        }
        MeloUi.report(tag + "_treewalk", reached)
        // How far the walk actually got. A walk over zero ancestors proves
        // nothing, so the test asserts on this too.
        MeloUi.report(tag + "_hops", hops)
    }

    Component.onCompleted: {
        // No "is the bridge visible?" probe here: reporting goes THROUGH MeloUi,
        // so an absent bridge throws on the first report and nothing arrives at
        // all. The C++ side asserts results arrived, which is the same control
        // without pretending a `false` could ever be reported.

        // (2) melo's globals must be absent, not shadowed: main.cpp's object
        // context properties plus the `Theme` singleton. Not exhaustive over the
        // MELO_* debug flags; the rule is all-or-nothing per engine, and these
        // are the names whose leak would hand a plugin something.
        var leaked = []
        if (probe(function() { return typeof Player       !== "undefined" })) leaked.push("Player")
        if (probe(function() { return typeof PlayerState  !== "undefined" })) leaked.push("PlayerState")
        if (probe(function() { return typeof Queue        !== "undefined" })) leaked.push("Queue")
        if (probe(function() { return typeof Suggestions  !== "undefined" })) leaked.push("Suggestions")
        if (probe(function() { return typeof Settings     !== "undefined" })) leaked.push("Settings")
        if (probe(function() { return typeof ThemeBackend !== "undefined" })) leaked.push("ThemeBackend")
        if (probe(function() { return typeof Theme        !== "undefined" })) leaked.push("Theme")
        if (probe(function() { return typeof Library      !== "undefined" })) leaked.push("Library")
        if (probe(function() { return typeof sidecar      !== "undefined" })) leaked.push("sidecar")
        if (probe(function() { return typeof WindowCtl    !== "undefined" })) leaked.push("WindowCtl")
        if (probe(function() { return typeof Spectrum     !== "undefined" })) leaked.push("Spectrum")
        if (probe(function() { return typeof NodeSetup    !== "undefined" })) leaked.push("NodeSetup")
        MeloUi.report("ctxprop", leaked.length > 0)
        MeloUi.report("ctxprop_names", leaked.join(","))

        runTreeWalk("created")

        // (1) imports, loaded dynamically so a failed import is catchable.
        var probes = {
            "folderlistmodel": "probe_folderlist.qml",
            "localstorage":    "probe_localstorage.qml",
            "dialogs":         "probe_dialogs.qml",
            "controls":        "probe_controls.qml",
            "labsplatform":    "probe_labsplatform.qml",
            "labssettings":    "probe_labssettings.qml",
            // One probe per blocked module FAMILY, not per module name. Every
            // probe above is Qt.labs.* or QtQuick.*; QtQml.XmlListModel is an
            // arbitrary-file read in a family none of them covers.
            "xmllistmodel":    "probe_xmllistmodel.qml",
            // POSITIVE CONTROL: an allowed import. If this ever goes false the
            // engine is broken outright and every blocked-import result above
            // is meaningless.
            "allowed_shapes":  "probe_allowed.qml",
            // Documents a known gap, asserted as-is rather than as a guarantee:
            // qmlRegisterType writes to a PROCESS-GLOBAL registry that the
            // curated import path does not gate.
            "cpp_registry":    "probe_cppregistry.qml"
        }
        for (var key in probes) {
            var c = Qt.createComponent(Qt.resolvedUrl(probes[key]))
            MeloUi.report(key, c.status === Component.Ready)
        }

        // NOT part of the loop above: that loop asks "did this import resolve",
        // and MeloUi.archives is a bridge member, not an import. It is created
        // and RUN here.
        var ac = Qt.createComponent(Qt.resolvedUrl("probe_archives.qml"))
        MeloUi.report("arch_probe_loaded", ac.status === Component.Ready)
        if (ac.status !== Component.Ready) MeloUi.report("arch_probe_error", ac.errorString())
        else {
            plugin.archiveProbe = ac.createObject(plugin)
            plugin.runArchives("first")
        }

        MeloUi.done()
    }
}
