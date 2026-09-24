// Containment boundary. Plugin QML runs in melo's process with no sandbox, so
// containment is only what these enforce:
//   1. the plugin engine's import path is the curated dir and nothing else
//   2. no context properties except the MeloUi bridge
//   3. plugin content refuses a parent owned by another QQmlEngine
//
// Not covered: PluginWindowHost and Window.window.transientParent. A hosted
// QQuickWindow's transientParent is the main Window; that gap is open.
//
// If this fails, fix the containment, never the assertion.
#include <QtTest>
#include <QRegularExpression>
#include "MeloEngineOnly.h"
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QQmlApplicationEngine>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQuickItem>
#include <QRegularExpression>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QTemporaryDir>
#include <QVariantMap>
#include <atomic>
#include <functional>
#include <memory>
#include <thread>
#if defined(Q_OS_UNIX)
#include <cstdio>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif
#include "MeloUiArchives.h"
#include "PluginUiHost.h"
#include "PluginImportDir.h"
#include "SkinImageProvider.h"

// Registered from C++ solely to exercise the documented gap: qmlRegisterType
// writes to a process-global registry that importPathList does not gate.
// Registering melo's real types here would drag half the app into the test, and
// the gap is a property of the registry, not of those types.
class GapWitness : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
};

// Stands in for the MeloUi bridge. The hostile fixture reports through it,
// because the bridge is the only object a plugin is given and the test engine
// must not differ from the real one by having an extra context property.
class Probe : public QObject {
    Q_OBJECT
    // The two bridge members probe_archives.qml reads. Named exactly as the
    // real MeloUi names them: a stub that differed here would be testing a
    // bridge melo does not ship.
    Q_PROPERTY(QObject* archives READ archivesObject CONSTANT)
    Q_PROPERTY(QString pluginId READ pluginId CONSTANT)
public:
    QVariantMap results;
    bool finished = false;
    MeloUiArchives* archives = nullptr;   // null in the runs that do not test archives
    QString id = QStringLiteral("hostile");

    QObject* archivesObject() const { return archives; }
    QString pluginId() const { return id; }

    bool flag(const char* k) const { return results.value(QString::fromLatin1(k)).toBool(); }
    QString str(const char* k) const { return results.value(QString::fromLatin1(k)).toString(); }
    int num(const char* k) const { return results.value(QString::fromLatin1(k)).toInt(); }
    bool has(const char* k) const { return results.contains(QString::fromLatin1(k)); }
public slots:
    void report(const QString& k, const QVariant& v) { results[k] = v; }
    void done() { finished = true; }
};

// A plugin data dir laid out as the sidecar lays one out, plus the files a
// hostile plugin would want to reach from it.
//   <config>/plugin-data/hostile/skins/classic.wsz    the real skin, in bounds
//   <config>/plugin-data/hostile/skins/secret.txt     a real skin under a name
//                                                     the field's extensions bar
//   <config>/plugin-data/hostile/skins/sub/nested.wsz a real skin one level down
//   <config>/plugin-data/hostile/skins/link.wsz   ->  <config>/outside/secret.wsz
//   <config>/plugin-data/other/skins/classic.wsz      another plugin's copy
//   <config>/outside/secret.wsz                       out of bounds
//
// The out-of-bounds copies are real, loadable archives, so `ready == false` can
// only mean melo refused to open them (a non-zip like /etc/passwd fails to load
// even with no containment).
struct DataFixture {
    QTemporaryDir config;
    QString skinsDir, otherSkinsDir, outsideDir;

    // Needs a real archive, and melo's only ones are third-party skins with no
    // verified licence, kept out of the published tree. Absent means skip; the
    // containment suites need no fixture and always run.
    static bool fixturesPresent() {
        return QFile::exists(QStringLiteral(MELO_TEST_FIXTURES)
                             + QStringLiteral("/skins/Winamp5_Classified_v5.5.wsz"));
    }

    bool setup() {
        if (!config.isValid()) return false;
        qputenv("MELO_CONFIG_DIR", config.path().toUtf8());
        const QDir root(config.path());
        skinsDir = root.filePath(QStringLiteral("plugin-data/hostile/skins"));
        otherSkinsDir = root.filePath(QStringLiteral("plugin-data/other/skins"));
        outsideDir = root.filePath(QStringLiteral("outside"));
        for (const QString& d : { skinsDir, skinsDir + "/sub", otherSkinsDir, outsideDir })
            if (!QDir().mkpath(d)) return false;
        const QString src = QStringLiteral(MELO_TEST_FIXTURES)
                          + QStringLiteral("/skins/Winamp5_Classified_v5.5.wsz");
        if (!QFile::exists(src)) return false;
        return QFile::copy(src, skinsDir + "/classic.wsz")
            && QFile::copy(src, skinsDir + "/secret.txt")
            && QFile::copy(src, skinsDir + "/sub/nested.wsz")
            // A file named as a Windows traversal: on Linux the backslash is
            // ordinary, so only the backslash rule refuses this loadable
            // archive. On Windows the same value climbs out of the data dir.
            && QFile::copy(src, skinsDir + "/..\\..\\..\\outside\\secret.wsz")
            && QFile::copy(src, otherSkinsDir + "/classic.wsz")
            && QFile::copy(src, outsideDir + "/secret.wsz")
            && QFile::link(outsideDir + "/secret.wsz", skinsDir + "/link.wsz");
    }

    // How many ".." it takes to climb from the field's dir back to <config>.
    // Spelled out rather than guessed: a traversal row one level short lands on
    // a path that does not exist, and then it passes against no containment at
    // all.
    static QString upToConfig() { return QStringLiteral("../../../"); }
};

// One `file` field, as melo receives a validated manifest's settings array.
QJsonArray fileFieldSchema(const QString& key, const QString& dir,
                           const QStringList& exts = QStringList{QStringLiteral("wsz")}) {
    QJsonArray extensions;
    for (const QString& e : exts) extensions.append(e);
    return QJsonArray{ QJsonObject{
        {QStringLiteral("key"), key},
        {QStringLiteral("type"), QStringLiteral("file")},
        {QStringLiteral("label"), QStringLiteral("Skin")},
        {QStringLiteral("dir"), dir},
        {QStringLiteral("extensions"), extensions},
    }};
}

// QQuickImageBase::Status, as plugin QML reports it.
constexpr int kImageReady = 1;
constexpr int kImageError = 3;

// QVERIFY inside runHostile() returns from THE HELPER, not from the test slot,
// so a failed setup would otherwise let the slot run on and assert over an empty
// result map. Every caller goes through this macro; nothing calls runHostile
// directly.
#define RUN_HOSTILE(...) do { \
        runHostile(__VA_ARGS__); \
        QVERIFY2(!QTest::currentTestFailed(), "hostile fixture setup failed — see above"); \
    } while (false)

// The probes are stored as `.qml.probe` and copied to their real names here:
// Qt's finalization scans the project for QML imports and links a static plugin
// for each, and the probes import everything the plugin engine must refuse.
// LocalStorage alone pulls in Qt6Sql and the SQL drivers: 14.19MB -> 21.62MB on
// the lite AppImage.
static QString fixtureDir() {
    static QTemporaryDir dir;
    static bool built = false;
    if (!built) {
        built = true;
        const QDir src(QStringLiteral(MELO_TEST_FIXTURES "/hostile-plugin"));
        for (const QString& name : src.entryList(QDir::Files)) {
            QString out = name;
            if (out.endsWith(QStringLiteral(".probe"))) out.chop(6);
            QFile::copy(src.filePath(name), dir.filePath(out));
        }
    }
    return dir.path();
}

static bool writeQml(const QString& path, const char* src) {
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    return f.write(src) == qint64(qstrlen(src));
}

static QQuickItem* createItem(QQmlEngine* engine, const char* src,
                              const char* url, std::unique_ptr<QObject>& owner) {
    QQmlComponent c(engine);
    c.setData(src, QUrl(QString::fromLatin1(url)));
    owner.reset(c.create(engine->rootContext()));
    if (!owner) qWarning("%s", qPrintable(c.errorString()));
    return qobject_cast<QQuickItem*>(owner.get());
}

class TestPluginContainment : public QObject {
    Q_OBJECT

    // Loads the hostile fixture into a real host under a parent chain in the
    // plugin's own engine, as a real plugin window runs. The tree walk runs
    // from here because Component.onCompleted fires before the host reparents.
    // windowSrc / leakedCtxName are for the detector self-tests below.
    void runHostile(Probe& probe, const char* windowSrc = nullptr,
                    const char* leakedCtxName = nullptr,
                    const std::function<void(QObject*)>& after = {}) {
        if (!windowSrc)
            windowSrc = "import QtQuick\n"
                        "Item { objectName: \"pluginWindowRoot\"\n"
                        "       Item { objectName: \"pluginWindowChild\" } }";
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        // Exactly what main.cpp does, on exactly the engine main.cpp does it on.
        if (probe.archives) host.installArchiveProvider(probe.archives->resolver());
        if (leakedCtxName)
            host.engine()->rootContext()->setContextProperty(
                QString::fromLatin1(leakedCtxName), &probe);

        std::unique_ptr<QObject> windowRoot;
        QQuickItem* root = createItem(host.engine(), windowSrc,
                                      "file:///plugin-window.qml", windowRoot);
        QVERIFY(root);
        QCOMPARE(root->childItems().size(), 1);
        QQuickItem* attachPoint = root->childItems().first();

        QObject* content = host.createWindowContent(QStringLiteral("Hostile.qml"), attachPoint);
        QVERIFY2(content != nullptr, qPrintable(host.errorString()));
        QTRY_VERIFY_WITH_TIMEOUT(probe.finished, 5000);

        // The attachment must have actually happened, otherwise the tree walk
        // below runs over an empty ancestor chain and passes vacuously.
        auto* contentItem = qobject_cast<QQuickItem*>(content);
        QVERIFY(contentItem);
        QCOMPARE(contentItem->parentItem(), attachPoint);

        QVERIFY(QMetaObject::invokeMethod(content, "runTreeWalk",
                                          Q_ARG(QVariant, QVariant(QStringLiteral("attached")))));
        // Anything that has to happen while the plugin is still LOADED — the
        // reload passes, which cannot run after this function returns because
        // the host and its engine die with the scope.
        if (after) after(content);
        // The host owns `content` and destroys it in ~PluginUiHost. Deleting it
        // here would be a double free.
    }

private slots:
    void hostilePluginReachesNothing() {
        Probe probe;
        RUN_HOSTILE(probe);
        // This IS the bridge positive control, and the only honest form of one:
        // the fixture reports THROUGH MeloUi, so an absent or broken bridge
        // produces no results at all rather than a `false` in one of them.
        QVERIFY2(probe.finished, "hostile fixture never reported — the bridge is broken or the run "
                                 "aborted; every absent result below is meaningless");

        // positive control: without it every "absent" import result below could
        // just mean the engine cannot load anything at all.
        QVERIFY2(probe.flag("allowed_shapes"),
                 "an ALLOWED import (QtQuick.Shapes) failed to resolve — the plugin engine is broken, "
                 "so the blocked-import results below say nothing about curation");

        // (2) no context properties except the bridge
        QVERIFY2(!probe.flag("ctxprop"),
                 qPrintable(QStringLiteral("melo context properties are visible to plugin QML: ")
                            + probe.str("ctxprop_names")));

        // In this fixture, the attached parent chain must not contain a shell
        // object. This does not exercise a real hosted window or transientParent.
        QVERIFY2(probe.results.value("attached_hops").toInt() >= 2,
                 "the post-attach tree walk found no ancestors — it cannot have tested anything");
        QVERIFY2(!probe.flag("attached_treewalk"),
                 "plugin QML walked its parent chain to a shell object");

        // (1) curated import path
        QVERIFY2(!probe.flag("folderlistmodel"),
                 "Qt.labs.folderlistmodel resolved — the import allowlist leaks (filesystem read)");
        QVERIFY2(!probe.flag("localstorage"),
                 "QtQuick.LocalStorage resolved — the import allowlist is not granular (sqlite write)");
        QVERIFY2(!probe.flag("labsplatform"),
                 "Qt.labs.platform resolved — the import allowlist leaks (native dialogs, tray)");
        QVERIFY2(!probe.flag("labssettings"),
                 "Qt.labs.settings resolved — the import allowlist leaks (writes melo's config store)");
        // The QtQml family has to be granular too: QtQml.XmlListModel fetches
        // `source` through QNAM, which serves file:// — it is not gated the way
        // XMLHttpRequest is, so it is a general file-read primitive.
        QVERIFY2(!probe.flag("xmllistmodel"),
                 "QtQml.XmlListModel resolved — the import allowlist is not granular for QtQml "
                 "(arbitrary local file read via XmlListModel.source over QNAM)");
        QVERIFY2(!probe.flag("dialogs"),
                 "QtQuick.Dialogs resolved — the import allowlist leaks (file pickers)");
        QVERIFY2(!probe.flag("controls"),
                 "QtQuick.Controls resolved — the import allowlist is not granular");
    }

    // Detector self-test for mechanism 2: this binary installs no melo globals,
    // so plant one named like a melo global and require the fixture to catch
    // it, or `ctxprop == false` above could mean the fixture stopped looking.
    void ctxPropProbeDetectsAPlantedGlobal() {
        Probe probe;
        RUN_HOSTILE(probe, nullptr, "Settings");
        QVERIFY(probe.finished);
        QVERIFY2(probe.flag("ctxprop"),
                 "the fixture did not notice a context property named Settings — "
                 "the context-property assertions cannot fail and guard nothing");
        QCOMPARE(probe.str("ctxprop_names"), QStringLiteral("Settings"));
    }

    // DETECTOR SELF-TEST for mechanism 3, same argument: plant a shell-looking
    // ancestor (an object carrying `shellRef`) in the plugin's own engine and
    // require the tree walk to reach it.
    void treeWalkDetectsAShellAncestor() {
        Probe probe;
        RUN_HOSTILE(probe,
                   "import QtQuick\n"
                   "Item { objectName: \"fakeShellRoot\"; property var shellRef: \"melo\"\n"
                   "       Item { objectName: \"fakeShellChild\" } }");
        QVERIFY(probe.finished);
        QVERIFY2(probe.flag("attached_treewalk"),
                 "the tree walk missed a shell object one hop up — "
                 "the tree-walk assertion cannot fail and guards nothing");
    }

    // Whitebox complement to the import probes above: the curated dir is not
    // merely FIRST on the import path, it is the whole path.
    void importPathIsExactlyTheCuratedDir() {
        Probe probe;
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        QCOMPARE(host.engine()->importPathList(), QStringList{meloPluginImportDir()});
    }

    // Mechanism 3 is enforced, not documented: an object belonging to another
    // QQmlEngine is a shell object, and attaching plugin content to it would put
    // melo's tree one `parent` hop away.
    void shellEngineParentIsRefused() {
        Probe probe;
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));

        QQmlEngine shellEngine;   // stands in for melo's own engine
        std::unique_ptr<QObject> shellOwner;
        QQuickItem* shellItem = createItem(&shellEngine,
            "import QtQuick\n"
            "Item { objectName: \"shellRoot\"; property var shellRef: \"melo\" }",
            "file:///shell.qml", shellOwner);
        QVERIFY(shellItem);

        QObject* content = host.createWindowContent(QStringLiteral("Hostile.qml"), shellItem);
        QVERIFY2(content == nullptr,
                 "plugin content was attached to an object from melo's own QML engine");
        QVERIFY(!host.errorString().isEmpty());
        QVERIFY2(!probe.finished,
                 "the plugin's QML ran before the parent was rejected — refusal must come first");
    }

    // A slot is the deliberate exception: a plugin replacing the visualiser
    // draws in melo's window, so createSlotContent accepts the parent chain
    // createWindowContent refuses. It still refuses a null gate, and the host
    // owns the occupant and destroys it before the engine.
    void aSlotAttachesWhereAWindowWouldBeRefused() {
        Probe probe;
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));

        // The shell-side gate: a bare C++ item, which is what main.qml's slot
        // gate resolves to by the time the host sees it.
        QQuickItem gate;
        QObject* content = host.createSlotContent(QStringLiteral("Hostile.qml"), &gate);
        QVERIFY2(content != nullptr, qPrintable(host.errorString()));
        auto* item = qobject_cast<QQuickItem*>(content);
        QVERIFY(item);
        QCOMPARE(item->parentItem(), &gate);
        QCOMPARE(content->parent(), &host);   // ownership stays the host's

        QVERIFY(host.createSlotContent(QStringLiteral("Hostile.qml"), nullptr) == nullptr);
    }

    // A parent the content cannot legally attach to must fail loudly rather than
    // silently leave the content unparented next to melo's tree.
    void unattachableParentIsRefused() {
        Probe probe;
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        QObject notAnItem;
        QVERIFY(host.createWindowContent(QStringLiteral("Hostile.qml"), &notAnItem) == nullptr);
        QVERIFY(!host.errorString().isEmpty());
    }

    // Type registration is process-global and cannot be gated, so each
    // `Melo 1.0` type refuses a foreign engine itself. Visualizer renders the
    // process-global PCM queue, so a plugin instance would render live audio
    // with no grant.
    void meloRegisteredTypesRefuseAForeignEngine() {
        QQmlEngine melo, plugin;
        meloOwnEngine() = &melo;

        std::unique_ptr<QObject> ours, theirs;
        QQuickItem* mine = createItem(&melo, "import QtQuick\nItem {}",
                                      "file:///melo.qml", ours);
        QQuickItem* other = createItem(&plugin, "import QtQuick\nItem {}",
                                       "file:///plugin.qml", theirs);
        QVERIFY(mine && other);

        QVERIFY2(meloEngineOwns(mine, "Visualizer"),
                 "melo's own engine was refused its own types");
        QVERIFY2(!meloEngineOwns(other, "Visualizer"),
                 "a plugin engine was allowed a Melo 1.0 type");
        // Refusing is not advisory: the item is taken out of the scene.
        QVERIFY(!other->isVisible());
        QVERIFY(!other->isEnabled());

        // An item with no engine at all (bare C++) is melo's own business.
        QQuickItem loose;
        QVERIFY(meloEngineOwns(&loose, "Visualizer"));
        meloOwnEngine() = nullptr;
    }

    // EVERY registered type has to do it: a type added later that forgets
    // reopens the gap.
    void everyMeloRegisteredTypeChecksItsEngine() {
        QFile mf(QStringLiteral(MELO_REPO_DIR "/src/main.cpp"));
        QVERIFY2(mf.open(QIODevice::ReadOnly), "cannot read src/main.cpp");
        const QString main = QString::fromUtf8(mf.readAll());
        static const QRegularExpression re(
            QStringLiteral("qmlRegisterType<([A-Za-z0-9_]+)>\\(\"Melo\""));
        auto it = re.globalMatch(main);
        int seen = 0;
        while (it.hasNext()) {
            const QString cls = it.next().captured(1);
            ++seen;
            // Registered types do not all live under src/vis — the check is
            // "every type melo puts in the process-global registry refuses a
            // foreign engine", so it has to find the header wherever it is
            // rather than only where the first three happened to sit.
            QString hdr;
            for (const char* dir : {"/src/vis/", "/src/ui/", "/src/core/"}) {
                QFile hf(QStringLiteral(MELO_REPO_DIR) + QLatin1String(dir) + cls + ".h");
                if (hf.open(QIODevice::ReadOnly)) { hdr = QString::fromUtf8(hf.readAll()); break; }
            }
            QVERIFY2(!hdr.isEmpty(), qPrintable("no header found for " + cls
                                                + " — a Melo 1.0 type whose header cannot be "
                                                  "located cannot be shown to refuse a plugin engine"));
            QVERIFY2(hdr.contains(QStringLiteral("meloEngineOwns(this")),
                     qPrintable(cls + " is registered as a Melo 1.0 type but does "
                                      "not refuse a foreign engine"));
        }
        QVERIFY2(seen >= 3, "found no Melo 1.0 registrations to check");
    }

    // Pins a known gap: qmlRegisterType's registry is process-global and not
    // gated by importPathList, so a plugin can import `Melo 1.0`; sensitive
    // types must refuse a foreign engine. If this fails the gap closed: verify
    // how, then assert the import does not resolve.
    void knownGap_cppRegisteredTypesResolveInPluginEngines() {
        Probe probe;
        RUN_HOSTILE(probe);
        QVERIFY(probe.finished);
        QVERIFY2(probe.flag("cpp_registry"),
                 "a C++-registered QML URI no longer resolves in a plugin engine — "
                 "the known registry gap appears to be closed; see the comment above this test");
    }

    // Manifest keys address only what the plugin declared. Filtering to slots
    // is not enough: `destroyed` is a legal key slug, and
    // indexOfMethod("destroyed()") resolves moc's default-argument clone, so a
    // manifest could make melo's "Run" button emit QObject::destroyed on a live
    // plugin root.
    void invokeActionRefusesQObjectsOwnMethods() {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        QVERIFY(writeQml(tmp.path() + "/Entry.qml",
                         "import QtQuick\n"
                         "QtObject {\n"
                         "  property bool pinged: false\n"
                         "  signal ping()\n"
                         "  onPing: pinged = true\n"
                         "}\n"));
        Probe probe;
        PluginUiHost host(QStringLiteral("act"), tmp.path(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        QVERIFY2(host.load(QStringLiteral("Entry.qml")), qPrintable(host.errorString()));

        // positive control: without it every refusal below could just mean
        // invokeAction stopped working altogether.
        QVERIFY2(host.invokeAction(QStringLiteral("ping")),
                 "a signal the plugin declared is no longer invokable — the refusals below "
                 "prove nothing");
        QVERIFY(host.pluginRoot()->property("pinged").toBool());

        QVERIFY2(!host.invokeAction(QStringLiteral("destroyed")),
                 "a manifest key reached QObject::destroyed on a live plugin root");
        QVERIFY2(!host.invokeAction(QStringLiteral("deleteLater")),
                 "a manifest key reached QObject::deleteLater");
        QVERIFY2(!host.invokeAction(QStringLiteral("objectNameChanged")),
                 "a manifest key reached a QObject-inherited signal");
    }

    // Commands go through Entry.command(id), never indexOfMethod(id + "()").
    // A command id `destroyed` is a legal slug; looking it up as a zero-arg
    // method would emit QObject::destroyed on a live plugin root.
    void invokeCommandRefusesQObjectMethods() {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        QVERIFY(writeQml(tmp.path() + "/Entry.qml",
                         "import QtQuick\n"
                         "QtObject {\n"
                         "  property bool pinged: false\n"
                         "  function command(id) { if (id === \"ping\") pinged = true }\n"
                         "}\n"));
        Probe probe;
        PluginUiHost host(QStringLiteral("cmd"), tmp.path(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        QVERIFY2(host.load(QStringLiteral("Entry.qml")), qPrintable(host.errorString()));

        // positive control: without it every refusal below could just mean
        // invokeCommand stopped working altogether.
        QVERIFY2(host.invokeCommand(QStringLiteral("ping")),
                 "command(id) the plugin declared is no longer invokable — the refusals below "
                 "prove nothing");
        QVERIFY(host.pluginRoot()->property("pinged").toBool());

        QPointer<QObject> root = host.pluginRoot();
        bool destroyedEmitted = false;
        QObject::connect(root, &QObject::destroyed, [&] { destroyedEmitted = true; });
        QVERIFY2(!host.invokeCommand(QStringLiteral("destroyed")),
                 "a command id reached QObject::destroyed on a live plugin root");
        QVERIFY2(!destroyedEmitted && !root.isNull(),
                 "invokeCommand(\"destroyed\") emitted QObject::destroyed");
        QVERIFY2(!host.invokeCommand(QStringLiteral("deleteLater")),
                 "a command id reached QObject::deleteLater");
        QCoreApplication::sendPostedEvents(root, QEvent::DeferredDelete);
        QVERIFY2(!root.isNull(), "invokeCommand(\"deleteLater\") destroyed the plugin root");
    }

    void invokeInterceptRefusesQObjectMethods() {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        QVERIFY(writeQml(tmp.path() + "/Entry.qml",
                         "import QtQuick\n"
                         "QtObject {\n"
                         "  property bool pinged: false\n"
                         "  function intercept(id) { if (id === \"play\") pinged = true }\n"
                         "}\n"));
        Probe probe;
        PluginUiHost host(QStringLiteral("cmd"), tmp.path(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        QVERIFY2(host.load(QStringLiteral("Entry.qml")), qPrintable(host.errorString()));

        // positive control: without it every refusal below could just mean
        // invokeIntercept stopped working altogether.
        QVERIFY2(host.invokeIntercept(QStringLiteral("play")),
                 "intercept(id) the plugin declared is no longer invokable — the refusals below "
                 "prove nothing");
        QVERIFY(host.pluginRoot()->property("pinged").toBool());

        QPointer<QObject> root = host.pluginRoot();
        bool destroyedEmitted = false;
        QObject::connect(root, &QObject::destroyed, [&] { destroyedEmitted = true; });
        QVERIFY2(!host.invokeIntercept(QStringLiteral("destroyed")),
                 "an intercept id reached QObject::destroyed on a live plugin root");
        QVERIFY2(!destroyedEmitted && !root.isNull(),
                 "invokeIntercept(\"destroyed\") emitted QObject::destroyed");
        QVERIFY2(!host.invokeIntercept(QStringLiteral("deleteLater")),
                 "an intercept id reached QObject::deleteLater");
        QCoreApplication::sendPostedEvents(root, QEvent::DeferredDelete);
        QVERIFY2(!root.isNull(), "invokeIntercept(\"deleteLater\") destroyed the plugin root");
    }

    // The shadowing refusal is about the DIRECTORY, not the two paths melo was
    // asked to load: QML registers every .qml file in a directory as a type, so
    // an undeclared sibling Plugin.qml shadows the injected `Plugin` in every
    // file loaded from there while melo never opens it.
    void anUndeclaredSiblingPluginQmlIsRefused() {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        QVERIFY(QDir(tmp.path()).mkpath(QStringLiteral("ui")));
        QVERIFY(writeQml(tmp.path() + "/ui/Entry.qml", "import QtQuick\nQtObject {}\n"));
        Probe probe;
        {   // control: the same layout without the shadowing sibling loads
            PluginUiHost ok(QStringLiteral("shadow"), tmp.path(), &probe);
            QVERIFY2(ok.load(QStringLiteral("ui/Entry.qml")), qPrintable(ok.errorString()));
        }
        QVERIFY(writeQml(tmp.path() + "/ui/Plugin.qml", "import QtQuick\nQtObject {}\n"));
        PluginUiHost host(QStringLiteral("shadow"), tmp.path(), &probe);
        QVERIFY2(!host.load(QStringLiteral("ui/Entry.qml")),
                 "an undeclared sibling Plugin.qml was accepted — it shadows the injected "
                 "Plugin object in every window loaded from that directory");
        QVERIFY(host.errorString().contains(QStringLiteral("Plugin.qml")));
        QVERIFY2(host.createWindowContent(QStringLiteral("ui/Entry.qml"), nullptr) == nullptr,
                 "window content loaded from a directory carrying a shadowing Plugin.qml");
    }

    // ---------------------------------------------------------------------
    // MeloUi.archives. The rule: no API here accepts a path. A plugin names a
    // settings KEY its own manifest declared, and the shell turns that into a
    // file inside the plugin's own data dir.
    // ---------------------------------------------------------------------

    void archivesRefuseEveryPathAPluginCanExpress() {
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");

        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));

        // A SECOND plugin, declaring a key the hostile one does not. Without it
        // "get(\"otherskin\") is null" would also hold if no manifest anywhere
        // had ever declared that key — the probe would be asking about a name
        // rather than about whose manifest it came from.
        QVariantMap otherValues{{QStringLiteral("otherskin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives other(QStringLiteral("other"),
                             [&otherValues](const QString& k) { return otherValues.value(k).toString(); });
        other.setSchema(fileFieldSchema(QStringLiteral("otherskin"), QStringLiteral("skins")));
        QObject* otherFacade = other.get(QStringLiteral("otherskin"));
        QVERIFY2(otherFacade && otherFacade->property("ready").toBool(),
                 "the second plugin's own key did not resolve — \"another plugin's key\" "
                 "below would then be asking about a key that works for nobody");

        Probe probe;
        probe.archives = &archives;
        RUN_HOSTILE(probe, nullptr, nullptr, [&](QObject* content) {
            // The reload path. The user picks a different file; every open
            // facade must follow it, in both directions.
            values[QStringLiteral("skin")] = QStringLiteral("absent.wsz");
            archives.refresh();
            QVERIFY(QMetaObject::invokeMethod(content, "runArchives",
                                              Q_ARG(QVariant, QVariant(QStringLiteral("second")))));
            values[QStringLiteral("skin")] = QStringLiteral("classic.wsz");
            archives.refresh();
            QVERIFY(QMetaObject::invokeMethod(content, "runArchives",
                                              Q_ARG(QVariant, QVariant(QStringLiteral("third")))));
        });
        QVERIFY2(probe.finished, "the hostile fixture never reported");
        QVERIFY2(probe.flag("arch_probe_loaded"),
                 qPrintable(QStringLiteral("probe_archives.qml did not load: ")
                            + probe.str("arch_probe_error")));

        // --- POSITIVE CONTROLS. Every refusal below is meaningless without
        // them: they are what separates "melo refused" from "archives is
        // broken and returns nothing to anyone".
        QVERIFY2(probe.flag("first_present"), "MeloUi.archives is not reachable from plugin QML");
        QVERIFY2(probe.flag("first_ready"),
                 qPrintable(QStringLiteral("the declared key did not resolve: ")
                            + probe.str("first_error")));
        QCOMPARE(probe.str("first_error"), QString());
        QVERIFY2(probe.num("first_names") > 0, "the archive listed no entries");
        QVERIFY2(!probe.str("first_url").isEmpty(), "image() produced no url for an entry that exists");
        QVERIFY2(probe.flag("first_img_ready"),
                 "the url image() produced did not load — the provider is not wired to this engine");
        QCOMPARE(probe.num("first_img_w"), 275);          // main.bmp's real width
        QVERIFY2(probe.flag("first_url_upper"), "entry lookup is not case-folded");

        // --- the KEY is not a path
        QVERIFY2(!probe.flag("first_key_traversal"),
                 "MeloUi.archives.get(\"../../etc\") returned a facade — the key is being "
                 "treated as a path");
        QVERIFY2(!probe.flag("first_key_abs"),
                 "MeloUi.archives.get(\"/etc/passwd\") returned a facade");
        QVERIFY2(!probe.flag("first_key_undeclared"),
                 "get() answered a key the plugin's manifest never declared");
        QVERIFY2(!probe.flag("first_key_other_plugin"),
                 "get() answered a key that belongs to ANOTHER plugin's manifest");

        // --- the ENTRY NAME is not a path
        QCOMPARE(probe.str("first_entry_traversal"), QString());
        QCOMPARE(probe.str("first_entry_traversal_text"), QString());
        QCOMPARE(probe.str("first_entry_abs"), QString());

        // --- a hand-written url is not a path. %2F is the encoding that
        // survives to requestImage, so it is the only way to smuggle a
        // separator into one id component; the provider decodes after the
        // split, which is what makes it inert.
        QCOMPARE(probe.num("first_url_pct_status"), kImageError);
        QCOMPARE(probe.num("first_url_pct_w"), 0);
        QCOMPARE(probe.num("first_url_dots_status"), kImageError);
        QVERIFY2(probe.num("first_url_other_status") == kImageError,
                 "a hand-written url naming ANOTHER plugin's id served an image");
        QCOMPARE(probe.num("first_url_undeclared_status"), kImageError);

        // --- the reload path
        QVERIFY2(probe.has("second_ready"), "the second pass never ran");
        QVERIFY2(!probe.flag("second_ready"),
                 "the archive stayed loaded after the setting was pointed at a file that "
                 "does not exist — a plugin keeps the old skin open forever");
        QCOMPARE(probe.num("second_names"), 0);
        QCOMPARE(probe.str("second_url"), QString());
        QVERIFY2(probe.flag("third_ready"), "the archive did not come back when the setting did");
        QVERIFY2(probe.flag("third_img_ready"), "the reloaded archive serves no pixels");
        QVERIFY2(probe.str("third_url") != probe.str("first_url"),
                 "the url is identical across a reload — QML caches a pixmap by url, so the "
                 "plugin would go on drawing the skin it opened first");
    }

    // The settings VALUE is plugin-writable: MeloUi.settings.set is
    // Q_INVOKABLE and nothing between it and melo's settings file validates a
    // `file` field's value. So this is not "what if the user types something
    // odd" — it is the primitive a plugin actually has.
    void settingValueNeverEscapesThePluginDataDir_data() {
        QTest::addColumn<QString>("value");
        QTest::addColumn<bool>("absolute");
        QTest::newRow("dotdot")        << DataFixture::upToConfig() + QStringLiteral("outside/secret.wsz") << false;
        QTest::newRow("dotdot-win")    << QStringLiteral("..\\..\\..\\outside\\secret.wsz") << false;
        QTest::newRow("subdir")        << QStringLiteral("sub/nested.wsz")           << false;
        QTest::newRow("absolute")      << QString()                                  << true;
        QTest::newRow("symlink-out")   << QStringLiteral("link.wsz")                 << false;
        QTest::newRow("wrong-ext")     << QStringLiteral("secret.txt")               << false;
        // An embedded NUL passes the extension filter and truncates at open(),
        // so the file opened is not the file validated. It stays inside the
        // data dir; the shape matches the swap race below.
        QTest::newRow("embedded-nul")
            << (QStringLiteral("secret.txt") + QChar(u'\0') + QStringLiteral(".wsz")) << false;
        // No "." or ".." rows: both name a DIRECTORY, which can never load as
        // a zip, so they would pass against a wide-open resolver. Every row
        // here aims at a real, loadable archive.
    }

    void settingValueNeverEscapesThePluginDataDir() {
        QFETCH(QString, value);
        QFETCH(bool, absolute);
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        if (absolute) value = fx.outsideDir + QStringLiteral("/secret.wsz");

        QVariantMap values;
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));

        // POSITIVE CONTROL, in this same test rather than a neighbouring one:
        // every file the rows above aim at is a REAL, LOADABLE archive, and
        // this proves the loader would have opened one if it had been allowed
        // to. Without it "not ready" could just mean nothing ever loads.
        values[QStringLiteral("skin")] = QStringLiteral("classic.wsz");
        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY(facade);
        QVERIFY2(facade->property("ready").toBool(),
                 "the in-bounds file did not load — the refusals below prove nothing");
        QVERIFY(!facade->property("names").toStringList().isEmpty());

        values[QStringLiteral("skin")] = value;
        archives.refresh();
        QVERIFY2(!facade->property("ready").toBool(),
                 qPrintable(QStringLiteral("a settings value of \"%1\" opened a file the settings "
                                           "picker would never have offered for that key")
                                .arg(value)));
        QVERIFY(facade->property("names").toStringList().isEmpty());
        const QString err = facade->property("error").toString();
        QVERIFY2(!err.isEmpty(),
                 "a refusal with no reason — the plugin author cannot tell this from a missing file");
        // The error is shown to the PLUGIN, so any separator at all means a
        // path got in.
        QVERIFY2(!err.contains(QLatin1Char('/')), qPrintable(QStringLiteral("error leaks a path: ") + err));
        QVERIFY2(!err.contains(fx.config.path()), qPrintable(err));
    }

    // A file that is in bounds and named correctly passes every refusal above
    // and can then fail to OPEN. Passing the reader's own message through to
    // MeloUiArchive::error would carry the absolute path with it, so a plugin
    // could drop a mode-000 file in its own data dir and read the path back out.
    void errorNeverNamesAPathWhenTheOpenItselfFails() {
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        const QString locked = fx.skinsDir + QStringLiteral("/locked.wsz");
        QVERIFY(QFile::copy(fx.skinsDir + QStringLiteral("/classic.wsz"), locked));
        QVERIFY(QFile::setPermissions(locked, QFileDevice::Permissions()));

        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY2(facade && facade->property("ready").toBool(),
                 "the readable file did not load — the unreadable one below proves nothing");

        values[QStringLiteral("skin")] = QStringLiteral("locked.wsz");
        archives.refresh();
        // Running as root makes a mode-000 file readable and there is nothing
        // to test; say so rather than passing.
        if (facade->property("ready").toBool())
            QSKIP("a mode-000 file was readable — running as root?");
        const QString err = facade->property("error").toString();
        QVERIFY(!err.isEmpty());
        QVERIFY2(err.contains(QStringLiteral("locked.wsz")),
                 qPrintable(QStringLiteral("the error does not even name the file: ") + err));
        QVERIFY2(!err.contains(QLatin1Char('/')),
                 qPrintable(QStringLiteral("the open failure leaked a path to the plugin: ") + err));
        QVERIFY2(!err.contains(fx.config.path()), qPrintable(err));
    }

    // O_NOFOLLOW guards only the final component: with `<root>/skins` a symlink
    // out of the data dir, open(O_NOFOLLOW) on `<root>/skins/secret.wsz`
    // succeeds. Only the /proc/self/fd check on the held descriptor catches it.
    void aSymlinkedIntermediateDirectoryIsRefused() {
#if !defined(Q_OS_UNIX)
        QSKIP("symlink layout is Unix-shaped; the Windows branch is untested (no Windows ctest job)");
#else
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QTemporaryDir config;
        QVERIFY(config.isValid());
        qputenv("MELO_CONFIG_DIR", config.path().toUtf8());
        const QDir root(config.path());
        const QString dataRoot = root.filePath(QStringLiteral("plugin-data/hostile"));
        const QString elsewhere = root.filePath(QStringLiteral("elsewhere"));
        QVERIFY(QDir().mkpath(dataRoot));
        QVERIFY(QDir().mkpath(elsewhere));
        const QString src = QStringLiteral(MELO_TEST_FIXTURES)
                          + QStringLiteral("/skins/Winamp5_Classified_v5.5.wsz");
        QVERIFY(QFile::copy(src, elsewhere + "/secret.wsz"));
        // the FIELD's dir is a symlink out of the data root
        QVERIFY(QFile::link(elsewhere, dataRoot + "/skins"));

        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("secret.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));

        // POSITIVE CONTROL: the same file, reached without the symlinked
        // directory, does load. Without it "not ready" could mean the fixture
        // is simply broken.
        {
            QTemporaryDir ok;
            QVERIFY(ok.isValid());
            qputenv("MELO_CONFIG_DIR", ok.path().toUtf8());
            const QString okSkins = QDir(ok.path()).filePath(QStringLiteral("plugin-data/hostile/skins"));
            QVERIFY(QDir().mkpath(okSkins));
            QVERIFY(QFile::copy(src, okSkins + "/secret.wsz"));
            QVariantMap v{{QStringLiteral("skin"), QStringLiteral("secret.wsz")}};
            MeloUiArchives control(QStringLiteral("hostile"),
                                   [&v](const QString& k) { return v.value(k).toString(); });
            control.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
            QObject* f = control.get(QStringLiteral("skin"));
            QVERIFY2(f && f->property("ready").toBool(),
                     "the control archive did not load — the refusal below proves nothing");
        }

        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY(facade);
        QVERIFY2(!facade->property("ready").toBool(),
                 "melo read through a symlinked intermediate directory — O_NOFOLLOW does not "
                 "cover those, and the descriptor was never checked against the data root");
        QVERIFY(facade->property("names").toStringList().isEmpty());
#endif
    }

    // A FIFO in the field's dir must be refused without blocking: open() on a
    // fifo with no writer blocks the GUI thread forever, before the S_ISREG
    // check. Reachable because node's --permission allows symlinkSync (not
    // mkfifo), so the sidecar can point the dir at any readable fifo. A
    // regression shows as a ctest timeout; the elapsed-time assertion only
    // diagnoses it.
    void aFifoIsRefusedWithoutBlockingTheGuiThread() {
#if !defined(Q_OS_UNIX)
        QSKIP("fifos are Unix-shaped; the Windows branch rejects FILE_TYPE_PIPE, untested");
#else
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        const QByteArray fifo = QFile::encodeName(fx.skinsDir + QStringLiteral("/pipe.wsz"));
        QVERIFY2(::mkfifo(fifo.constData(), 0600) == 0, "could not create the fifo");
        // No writer is ever opened: an unopened fifo is precisely the state that
        // blocks a reader in open().

        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY2(facade && facade->property("ready").toBool(),
                 "the real archive did not load — the refusal below proves nothing");

        values[QStringLiteral("skin")] = QStringLiteral("pipe.wsz");
        QElapsedTimer clock;
        clock.start();
        archives.refresh();
        const qint64 elapsed = clock.elapsed();

        QVERIFY2(!facade->property("ready").toBool(), "melo opened a fifo as a skin");
        QVERIFY(facade->property("names").toStringList().isEmpty());
        QVERIFY2(elapsed < 1000,
                 qPrintable(QStringLiteral("the refusal took %1 ms — melo blocked on the fifo")
                                .arg(elapsed)));
        QVERIFY(!facade->property("error").toString().isEmpty());
#endif
    }

    // The check-then-open swap as a real race: plugin QML drives reload()
    // through MeloUi.settings.set (no sidecar round trip) while the sidecar,
    // holding --allow-fs-write here, rename()s a symlink over the name.
    // `race.wsz` is a real archive and the symlink target is not a zip, so the
    // only legitimate outcomes are a load or a refusal; a zip-parse error is
    // the breach.
    void theFileCannotBeSwappedBetweenTheCheckAndTheOpen() {
#if !defined(Q_OS_UNIX)
        QSKIP("rename/symlink race is Unix-shaped; the Windows branch is untested (no Windows ctest job)");
#else
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        const QString real = fx.skinsDir + QStringLiteral("/race.wsz");
        const QString decoy = fx.skinsDir + QStringLiteral("/.decoy");
        const QString notAZip = fx.outsideDir + QStringLiteral("/not-a-zip.bin");
        QVERIFY(QFile::copy(fx.skinsDir + QStringLiteral("/classic.wsz"), real));
        {   // deliberately NOT a zip, so reading it is unmistakable
            QFile f(notAZip);
            QVERIFY(f.open(QIODevice::WriteOnly));
            QVERIFY(f.write(QByteArray(4096, 'A')) == 4096);
        }
        QVERIFY(QFile::link(notAZip, decoy));
        const QString spare = fx.skinsDir + QStringLiteral("/.spare");
        QVERIFY(QFile::copy(fx.skinsDir + QStringLiteral("/classic.wsz"), spare));

        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("race.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY2(facade && facade->property("ready").toBool(),
                 "the honest file did not load before the race started");

        // The attacker: rename() over the name, atomically, as fast as it goes.
        // Two sources, so the name is never absent and the swap is a pure
        // substitution — exactly what the sidecar half can do.
        std::atomic<bool> stop{false};
        std::atomic<qint64> swaps{0};
        const QByteArray decoyPath = QFile::encodeName(decoy);
        const QByteArray sparePath = QFile::encodeName(spare);
        const QByteArray realPath = QFile::encodeName(real);
        std::thread swapper([&] {
            while (!stop.load(std::memory_order_relaxed)) {
                // link the decoy in, then put an honest file back
                if (::rename(decoyPath.constData(), realPath.constData()) == 0) {
                    ++swaps;
                    // recreate the decoy for the next round
                    ::symlink(QFile::encodeName(notAZip).constData(), decoyPath.constData());
                }
                if (::rename(sparePath.constData(), realPath.constData()) == 0) {
                    ++swaps;
                    QFile::copy(fx.skinsDir + QStringLiteral("/classic.wsz"), spare);
                }
            }
        });

        // Bounded by TIME, not by a fixed count: a real skin decodes on every
        // successful observation, so a count large enough to be convincing
        // takes 33 seconds. Three seconds is ~1000 observations here.
        int loaded = 0, refused = 0;
        QString breach;
        QElapsedTimer clock;
        clock.start();
        for (int i = 0; clock.elapsed() < 3000 && breach.isEmpty(); ++i) {
            // alternate the value, or reload() short-circuits on "same value"
            values[QStringLiteral("skin")] = (i % 2) ? QStringLiteral("race.wsz") : QString();
            archives.refresh();
            if (i % 2 == 0) continue;
            if (facade->property("ready").toBool()) { ++loaded; continue; }
            const QString err = facade->property("error").toString();
            if (err.contains(QStringLiteral("not inside the plugin's own data folder"))
                || err.contains(QStringLiteral("cannot open"))) { ++refused; continue; }
            breach = err;          // a zip-parse error: melo read the far end
        }
        stop = true;
        swapper.join();

        qInfo("race: %lld swaps, %d loads, %d refusals", swaps.load(), loaded, refused);

        // Assert the breach first: the loop breaks on one, so a failing build
        // makes few observations and would otherwise report only the
        // observation floor.
        QVERIFY2(breach.isEmpty(),
                 qPrintable(QStringLiteral("melo read a file the swap pointed it at: ") + breach));

        QVERIFY2(swaps.load() > 100, "the attacker thread barely ran — the race was never on");
        // Bounds the OBSERVER, not the attacker. `swaps > 100` says the swap
        // thread ran; it says nothing about how many times the reader actually
        // looked. 50 is well
        // under the ~200 a normal run makes and well over "it barely tried".
        QVERIFY2(loaded + refused >= 50,
                 qPrintable(QStringLiteral("only %1 observations in 3s — the machine was too "
                                           "loaded for this to have raced anything")
                                .arg(loaded + refused)));
#endif
    }

    // Every member a reachable object's class adds above QObject (properties,
    // Q_INVOKABLEs, signals connectable and emittable, slots) is
    // plugin-reachable, so these two surfaces must be exactly their API. Both
    // derive straight from QObject, so the meta-object offsets cover them. A
    // failure means a member was added: justify it, then update the list.
    void archiveObjectsExposeNothingBeyondTheirApi() {
        auto surface = [](const QMetaObject* mo) {
            QStringList out;
            for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i)
                out << QStringLiteral("property ") + QLatin1String(mo->property(i).name());
            for (int i = mo->methodOffset(); i < mo->methodCount(); ++i)
                out << QString::fromLatin1(mo->method(i).methodSignature());
            out.sort();
            return out;
        };

        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY(facade);

        QCOMPARE(surface(archives.metaObject()),
                 (QStringList{QStringLiteral("get(QString)")}));
        QCOMPARE(surface(facade->metaObject()),
                 (QStringList{QStringLiteral("changed()"),
                              QStringLiteral("image(QString)"),
                              // A classic skin's title colour is encoded in
                              // text.bmp's ink; this reads one pixel of an
                              // image already in the archive and accepts no
                              // path.
                              QStringLiteral("pixel(QString,int,int)"),
                              QStringLiteral("property error"),
                              // Read-only, and the one property here that
                              // always CHANGES on an adopt — see
                              // MeloUiArchives.h. It hands a plugin nothing it
                              // could not already count by watching `changed`.
                              QStringLiteral("property generation"),
                              QStringLiteral("property names"),
                              QStringLiteral("property ready"),
                              QStringLiteral("text(QString)")}));
    }

    // A plugin binding to skin.ready never calls get() again, so only a
    // settings change the shell pushes in can reload its archive. This is that
    // push.
    void aSettingsChangePushesIntoAnAlreadyOpenFacade() {
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));

        QObject* facade = archives.get(QStringLiteral("skin"));
        QVERIFY(facade);
        QVERIFY(facade->property("ready").toBool());
        const int entries = facade->property("names").toStringList().size();
        QVERIFY(entries > 0);
        QSignalSpy spy(facade, SIGNAL(changed()));

        // get() is deliberately NOT called again anywhere below.
        values[QStringLiteral("skin")] = QStringLiteral("absent.wsz");
        archives.refresh();
        QVERIFY2(!facade->property("ready").toBool(),
                 "the facade kept the archive it opened first after the setting moved");
        QVERIFY2(!facade->property("error").toString().isEmpty(), "a silent failure");
        QCOMPARE(spy.count(), 1);

        values[QStringLiteral("skin")] = QStringLiteral("classic.wsz");
        archives.refresh();
        QVERIFY2(facade->property("ready").toBool(), "the archive did not come back");
        QCOMPARE(facade->property("names").toStringList().size(), entries);
        QCOMPARE(spy.count(), 2);

        // An unrelated settings write fires the same `changed` on MeloUiSettings
        // and must not re-read the disk or churn the url out from under a
        // binding. Same value, same file, nothing to do.
        archives.refresh();
        QCOMPARE(spy.count(), 2);
    }

    // get() returns a QObject* from a Q_INVOKABLE, which is the shape that
    // hands QML JavaScriptOwnership. If it did, QML's collector could delete a
    // facade the shell still holds and still writes to on every settings
    // change — a use-after-free a plugin triggers at will with gc().
    void getFacadeSurvivesGarbageCollection() {
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));

        QPointer<QObject> facade = archives.get(QStringLiteral("skin"));
        QVERIFY(facade);
        QCOMPARE(QQmlEngine::objectOwnership(facade), QQmlEngine::CppOwnership);

        QQmlEngine engine;
        engine.rootContext()->setContextProperty(QStringLiteral("Archives"), &archives);
        // Take a JS reference, drop it, and collect. The read is there so the
        // wrapper is really created — an expression the engine optimises away
        // would prove nothing.
        QQmlExpression expr(engine.rootContext(), nullptr,
                            QStringLiteral("(function(){ var f = Archives.get('skin');"
                                           "  var n = f.names.length; f = null; return n })()"));
        const QVariant n = expr.evaluate();
        QVERIFY2(!expr.hasError(), qPrintable(expr.error().toString()));
        QVERIFY(n.toInt() > 0);

        engine.collectGarbage();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        engine.collectGarbage();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);

        QVERIFY2(!facade.isNull(),
                 "QML's garbage collector deleted the facade get() returned — the shell still "
                 "holds it and still writes to it on every settings change");
        QVERIFY(facade->property("ready").toBool());
        // Same key, same object: a plugin's `readonly property var skin` must
        // stay valid across reloads, and a fresh facade per call would also
        // mean unbounded growth.
        QCOMPARE(archives.get(QStringLiteral("skin")), facade.data());
    }

    // addImageProvider writes to the ENGINE, unlike qmlRegisterType which
    // writes to a process-global registry.
    void archiveProviderIsPerEngineNotProcessGlobal() {
        DataFixture fx;
        if (!DataFixture::fixturesPresent())
            QSKIP("skin fixtures are not in this tree (they are not redistributable)");
        QVERIFY2(fx.setup(), "could not build the plugin data fixture");
        QVariantMap values{{QStringLiteral("skin"), QStringLiteral("classic.wsz")}};
        MeloUiArchives archives(QStringLiteral("hostile"),
                                [&values](const QString& k) { return values.value(k).toString(); });
        archives.setSchema(fileFieldSchema(QStringLiteral("skin"), QStringLiteral("skins")));
        QVERIFY(archives.get(QStringLiteral("skin")));

        Probe probe;
        PluginUiHost host(QStringLiteral("hostile"), fixtureDir(), &probe);
        QVERIFY2(host.engine() != nullptr, qPrintable(host.errorString()));
        host.installArchiveProvider(archives.resolver());

        const QString pid = QString::fromLatin1(SkinImageProvider::kProviderId);
        // positive control: it really is installed somewhere.
        QVERIFY2(host.engine()->imageProvider(pid) != nullptr,
                 "the plugin's own engine has no archive provider — the absence below is vacuous");

        // melo's own engine, built with the class main.cpp builds it with.
        QQmlApplicationEngine shell;
        QVERIFY2(shell.imageProvider(pid) == nullptr,
                 "melo's main QQmlApplicationEngine carries the plugin archive provider — every "
                 "plugin's decoded skin is one image:// url away from melo's own QML");

        // and not merely absent from the lookup: unusable from that engine.
        std::unique_ptr<QObject> owner;
        QQuickItem* item = createItem(&shell,
            "import QtQuick\n"
            "Item { property alias st: i.status\n"
            "       Image { id: i; asynchronous: false\n"
            "               source: \"image://plugin-archive/hostile/skin/main.bmp\" } }",
            "file:///shell-image.qml", owner);
        QVERIFY(item);
        QCOMPARE(item->property("st").toInt(), kImageError);
    }

    // archiveProviderIsPerEngineNotProcessGlobal() checks a fresh engine, and
    // melo's configured one cannot be built here, so an addImageProvider added
    // to main.cpp is caught by reading the tree. Rule: exactly one call site,
    // the per-plugin one.
    void onlyPluginUiHostRegistersTheArchiveProvider() {
        const QDir repo(QStringLiteral(MELO_REPO_DIR));
        // The whole repo, not src/. A call added beside the tree, or hidden in a
        // helper that lives somewhere else, is precisely the edit a src/-only
        // scan would not see — and this test exists for the edit nobody
        // remembers to check.
        QDirIterator it(repo.absolutePath(),
                        QStringList{QStringLiteral("*.cpp"), QStringLiteral("*.h"),
                                    QStringLiteral("*.hpp"), QStringLiteral("*.qml"),
                                    QStringLiteral("*.js"), QStringLiteral("*.mjs"),
                                    QStringLiteral("*.ts")},
                        QDir::Files, QDirIterator::Subdirectories);
        // Skipped because they are not melo's code: build output (which contains
        // generated copies of it), git internals, vendored third-party trees and
        // installed node modules.
        static const QStringList kSkip{
            QStringLiteral("build/"),   QStringLiteral(".git/"),
            QStringLiteral("vendor/"),  QStringLiteral("node_modules/"),
            QStringLiteral("dist/"),
        };
        QStringList callSites;
        int filesScanned = 0;
        while (it.hasNext()) {
            const QString path = it.next();
            const QString rel = repo.relativeFilePath(path);
            bool skip = false;
            for (const QString& s : kSkip)
                if (rel.startsWith(s) || rel.contains(QLatin1Char('/') + s)) { skip = true; break; }
            if (skip) continue;
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            ++filesScanned;
            const QString text = QString::fromUtf8(f.readAll());
            // A CALL, not a mention: `->addImageProvider(` or `.addImageProvider(`.
            // The headers here discuss the API by name (`QQmlEngine::addImage
            // Provider`) and must not count, or the assertion would have to be
            // loosened until it caught nothing.
            static const QRegularExpression call(
                QStringLiteral("[.>]\\s*addImageProvider\\s*\\("));
            if (!text.contains(call)) continue;
            // Only the skin provider: main.cpp's thumbnail provider on melo's
            // own engine exposes no plugin data. The "plugin-archive" id is
            // matched too, to catch a registration spelled that way.
            if (!text.contains(QStringLiteral("SkinImageProvider"))
                && !text.contains(QStringLiteral("\"plugin-archive\"")))
                continue;
            // Test code may install a provider on an engine it built itself —
            // tst_skinarchive does, and that is the point of it. The rule is
            // about SHIPPING code.
            if (rel.startsWith(QStringLiteral("tests/"))) continue;
            callSites << rel;
        }
        // positive control: the scan really read melo's sources.
        QVERIFY2(filesScanned > 100,
                 qPrintable(QStringLiteral("only %1 files scanned — MELO_REPO_DIR is wrong and the "
                                           "assertion below is vacuous").arg(filesScanned)));
        callSites.sort();
        QVERIFY2(callSites == QStringList{QStringLiteral("src/plugins/PluginUiHost.cpp")},
                 qPrintable(QStringLiteral(
                     "addImageProvider is called from: %1. Outside tests/ it must be called from "
                     "src/plugins/PluginUiHost.cpp and nowhere else — a call on melo's own "
                     "QQmlApplicationEngine puts every plugin's decoded skin one image:// url "
                     "away from melo's QML and from every other plugin.").arg(callSites.join(", "))));
    }

    void importDirIsPresent() {
        QVERIFY2(!meloPluginImportDir().isEmpty(),
                 "curated import dir missing — plugin QML must refuse to load");
    }
};

int main(int argc, char** argv) {
    // Headless by default so `ctest` needs no display, while still honouring an
    // explicit platform for local debugging.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    qmlRegisterType<GapWitness>("MeloProbeRegistry", 1, 0, "GapWitness");
    TestPluginContainment tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_plugincontainment.moc"
