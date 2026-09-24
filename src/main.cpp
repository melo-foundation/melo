// SPDX-License-Identifier: GPL-3.0-or-later
#include <QGuiApplication>
#include <QFontDatabase>
#include "media/ThumbImageProvider.h"
#include <QQmlApplicationEngine>
#include <QQmlNetworkAccessManagerFactory>
#include <QNetworkDiskCache>
#include <QQmlComponent>
#include <QQmlContext>
#include <QOpenGLContext>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>
#include <QDir>
#include "core/paths.h"
#include <QLockFile>
#include <string>
#include <atomic>
#include <QUrl>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QFileInfo>
#include <cstdio>
#include <gst/gst.h>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

#include "VisualizerItem.h"
#include "SpectrumSource.h"
#include "BackgroundItem.h"
#include "ParticlesItem.h"
#include "BlendItem.h"
#include "WindowShapeItem.h"
#include "AudioEngine.h"
#include "PcmQueue.h"
#include "SourceDeck.h"
#include "SidecarService.h"
#include "NodeBootstrap.h"
#include "PlayerState.h"
#include "QueueModel.h"
#include "SuggestionsModel.h"
#include "SettingsStore.h"
#include "ThemeStore.h"
#include "LibraryStore.h"
#include "PlaybackCoordinator.h"
#include "WindowController.h"
#include "MprisService.h"
#include "MeloUi.h"
#include "PluginUiHost.h"
#include "PluginUiHub.h"
#include "PluginWindowHost.h"
#include "PluginWindowsHub.h"
#include "CommandMap.h"
#include "InterceptMap.h"
#include "SlotMap.h"
#include "BarButtons.h"
#include "PluginFills.h"
#include "PortalDialog.h"
#include <memory>
#include <utility>
#include <vector>
#include <algorithm>

// --smoke counts QML diagnostics itself rather than leaving CI to grep a log.
// It has to: on a systemd distro Qt's default handler sends qWarning to the
// JOURNAL when stderr is not a TTY, so a pipe gets nothing and a grep over it
// reports a clean start for a window full of ReferenceErrors.
static std::atomic<int> g_smokeQmlErrors{0};
static QtMessageHandler g_prevHandler = nullptr;
static void smokeMessageHandler(QtMsgType type, const QMessageLogContext& ctx, const QString& msg) {
    if (type == QtWarningMsg || type == QtCriticalMsg || type == QtFatalMsg) {
        // A QML runtime error always names its ".qml:" file; the substrings
        // catch the engine's type and import errors, which name no file.
        const bool namesQmlFile = msg.contains(QLatin1String(".qml:"));
        if (namesQmlFile
            || msg.contains(QLatin1String("is not a type"))
            || msg.contains(QLatin1String("not installed"))
            || msg.contains(QLatin1String("must be of Item type"))) {
            g_smokeQmlErrors.fetch_add(1);
        }
    }
    std::fprintf(stderr, "%s\n", qPrintable(msg));
    if (g_prevHandler && type == QtFatalMsg) g_prevHandler(type, ctx, msg);
}

// A disk cache for QML's network fetches. The engine's default manager has no
// cache and Qt's pixmap cache holds about one 720x404 cover, so scrolling back
// over a feed re-fetched every thumbnail: 459 repeat loads of 228 URLs in one pass.
class MeloNamFactory : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager* create(QObject* parent) override {
        auto* nam = new QNetworkAccessManager(parent);
        auto* cache = new QNetworkDiskCache(nam);
        cache->setCacheDirectory(meloConfigDir() + QStringLiteral("/httpcache"));
        cache->setMaximumCacheSize(512LL * 1024 * 1024);
        nam->setCache(cache);
        return nam;
    }
};

// Qt re-walks the window's item tree after every polish to re-stack child
// windows (updateChildWindowStackingOrder, unguarded in Qt 6.10.3), and
// setVisible() re-arms it, so a scrolling view pays for it every frame.
// Suppressing it: 12.8 -> 4.6 late frames per 10k px on a 21k-item window.
// Skipped only while the window has no child QWindow, checked every frame.
//
// The suppressor re-polishes from beforeSynchronizing, so polishItems()'s LIFO
// drain reaches it just before the flag is tested. Opt-in (MELO_NO_STACK_WALK=1):
// forcing a polish pass every frame makes interactive resize jitter. The fix
// is QTBUG-134949 / Gerrit 736359, patched into the static release build.
#ifdef MELO_HAVE_QUICK_PRIVATE
#include <QtQuick/private/qquickwindow_p.h>
#include <QtQuick/private/qquickitem_p.h>
class StackingWalkSuppressor : public QQuickItem {
public:
    explicit StackingWalkSuppressor(QQuickItem* parent) : QQuickItem(parent) {
        setObjectName(QStringLiteral("stackingWalkSuppressor"));
        setFlag(ItemHasContents, false);
        setSize(QSizeF(0, 0));
    }
    // polish() without its maybeUpdate(). A frame request per polish keeps every
    // window rendering during an interactive resize, where resizeFreeze allows
    // only configure frames; the main window's configures then land late and
    // ~11% commit a previous-size buffer, which the fractional-scale viewport
    // stretches. Gating on the resized window does not help: the other windows
    // ask for the frames.
    void schedulePolishQuietly() {
        QQuickWindow* w = window();
        if (!w) return;
        auto* ip = QQuickItemPrivate::get(this);
        if (ip->polishScheduled) return;
        ip->polishScheduled = true;
        QQuickWindowPrivate::get(w)->itemsToPolish.prepend(this);
    }
    void updatePolish() override {
        QQuickWindow* w = window();
        if (!w) return;
        // children() is a const reference -- no allocation on a per-frame path
        for (QObject* child : w->children())
            if (qobject_cast<QWindow*>(child)) return;   // something to stack; leave Qt alone
        QQuickWindowPrivate::get(w)->needsChildWindowStackingOrderUpdate = false;
    }
};
#endif

// The frame clock. QQuickWindow::frameSwapped is the last signal of a
// rendered frame and is emitted on the render thread; QML wants it on the
// GUI thread, so every window's is relayed here with a queued connection
// and re-emitted as one signal with the window's title.
class FrameClock : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    void watch(QQuickWindow* w) {
        QObject::connect(w, &QQuickWindow::frameSwapped, this, [this, w] { emit swapped(w->title()); }, Qt::QueuedConnection);
        // Before sync, so a shader uniform written here lands in this frame
        // (from frameSwapped it paints one frame stale). Direct: under the basic
        // render loop this is the GUI thread, and a queued call misses the sync.
        QObject::connect(w, &QQuickWindow::beforeSynchronizing, this,
                         [this] { emit syncing(); }, Qt::DirectConnection);
#ifdef MELO_HAVE_QUICK_PRIVATE
        if (qEnvironmentVariableIntValue("MELO_NO_STACK_WALK") > 0) {
            auto* sup = new StackingWalkSuppressor(w->contentItem());
            QObject::connect(w, &QQuickWindow::beforeSynchronizing, sup,
                             [sup] { sup->schedulePolishQuietly(); }, Qt::DirectConnection);
            sup->schedulePolishQuietly();
            std::fprintf(stderr, "[stackwalk] melo suppressor ACTIVE on %s\n",
                         qPrintable(w->title().isEmpty() ? QStringLiteral("(untitled)") : w->title()));
        }
#endif
    }
    // A window that is not exposed swaps no frames — hidden, minimised, or
    // not yet mapped — so nothing should wait on one; what asks may start
    // at once instead.
    Q_INVOKABLE bool exposed(const QString& title) const {
        for (QWindow* w : QGuiApplication::allWindows()) if (w->title() == title) return w->isExposed();
        return false;
    }
signals:
    void swapped(const QString& title);
    void syncing();
};
#include "main.moc"

#ifdef MELO_EXTRA_STARTUP
// Defined by a source file that only some builds compile. Runs just before
// Main.qml loads, and may point qmlDir somewhere else.
void meloExtraStartup(QQmlApplicationEngine& qml, QString& qmlDir, AudioEngine& audio);
#endif

int main(int argc, char** argv) {
    setvbuf(stderr, nullptr, _IONBF, 0);
    const bool smoke = [argc, argv] {
        for (int i = 1; i < argc; ++i)
            if (std::string(argv[i]) == "--smoke") return true;
        return false;
    }();
    if (smoke) g_prevHandler = qInstallMessageHandler(&smokeMessageHandler);
#ifdef Q_OS_WIN
    // Packaged layout (portable zip / installer): GStreamer plugins and gio
    // TLS modules ship beside melo.exe. Both env vars must be set BEFORE
    // gst_init, and QCoreApplication doesn't exist yet — use the Win32 API
    // for the exe dir.
    {
        wchar_t exePath[MAX_PATH];
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        const QString exeDir = QFileInfo(QString::fromWCharArray(exePath)).absolutePath();
        if (QDir(exeDir + "/gst-plugins").exists())
            qputenv("GST_PLUGIN_PATH", QDir::toNativeSeparators(exeDir + "/gst-plugins").toLocal8Bit());
        if (QDir(exeDir + "/gio-modules").exists())
            qputenv("GIO_EXTRA_MODULES", QDir::toNativeSeparators(exeDir + "/gio-modules").toLocal8Bit());
    }
#endif
    gst_init(&argc, &argv);

    // Lite AppImage runs on the SYSTEM GStreamer — probe every element the
    // pipelines need and report what's missing instead of failing silently
    // (an unbuildable pipeline just logs to stderr and plays nothing).
    const auto haveGstElement = [](const char* name) {
        if (GstElementFactory* f = gst_element_factory_find(name)) {
            gst_object_unref(f);
            return true;
        }
        return false;
    };
    QStringList missingGst;
    for (const char* name : {"audiomixer", "equalizer-10bands", "audioconvert",
                             "audioresample", "volume", "appsink", "uridecodebin",
                             "typefind", "autoaudiosink", "pulsesink", "souphttpsrc", "oggdemux",
                             "vorbisdec", "opusdec", "mpg123audiodec",
                             "qtdemux", "matroskademux", "id3demux", "flacdec",
                             "wavparse"}) {
        if (!haveGstElement(name)) missingGst << QString::fromLatin1(name);
    }
    // AAC: uridecodebin takes whichever decoder exists — distros ship
    // different ones (ubuntu: faad; fedora: fdkaacdec / rpmfusion avdec_aac)
    if (!haveGstElement("faad") && !haveGstElement("avdec_aac") && !haveGstElement("fdkaacdec"))
        missingGst << QStringLiteral("aac decoder");
    if (!missingGst.isEmpty())
        std::fprintf(stderr, "[melo] missing GStreamer elements: %s\n",
                     missingGst.join(", ").toUtf8().constData());

#ifndef Q_OS_WIN
    // projectM renders raw GL under the scenegraph, so force the OpenGL RHI
    // before any QQuickWindow exists. MELO_GRAPHICS=vulkan is an unsupported
    // test switch for the threaded loop off GL (QTBUG-95817 is NVIDIA + Wayland
    // + GL only); the visualizer cannot draw there.
    if (qEnvironmentVariable("MELO_GRAPHICS") == QLatin1String("vulkan"))
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
    else
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#endif

    // Basic render loop: the threaded loop on Wayland renders frames of the
    // previous size during an interactive resize and content jumps; the basic
    // loop renders on the GUI thread, matching the latest configure.
    if (!qEnvironmentVariableIsSet("QSG_RENDER_LOOP"))
        qputenv("QSG_RENDER_LOOP", "basic");

    QSurfaceFormat fmt;
    fmt.setRenderableType(QSurfaceFormat::OpenGL);
    fmt.setVersion(3, 3);
    fmt.setProfile(QSurfaceFormat::CompatibilityProfile);
    fmt.setAlphaBufferSize(8);   // transparent root for mini mode (fixed-size window)
    QSurfaceFormat::setDefaultFormat(fmt);

    QGuiApplication app(argc, argv);
    app.setApplicationName("melo");
    app.setApplicationVersion(QStringLiteral(MELO_VERSION));   // project(VERSION) in CMakeLists.txt

    // One instance per config directory: two sidecars writing the same library
    // and settings files means the last writer silently discards the other's
    // changes. Keyed on the dir so a MELO_CONFIG_DIR test instance can run
    // beside a live melo. MELO_ALLOW_SECOND_INSTANCE disables it; the last
    // save still wins.
    const bool allowSecond = qEnvironmentVariableIsSet("MELO_ALLOW_SECOND_INSTANCE");
    QDir().mkpath(meloConfigDir());
    QLockFile instanceLock(meloConfigDir() + QStringLiteral("/melo.lock"));
    instanceLock.setStaleLockTime(0);   // a crashed melo's PID is checked, not timed out
    if (allowSecond) {
        std::fprintf(stderr,
                     "[melo] MELO_ALLOW_SECOND_INSTANCE: the single-instance lock is off. "
                     "Two melos on %s both write the library and the settings, and the last "
                     "save wins.\n", qPrintable(meloConfigDir()));
    }
    if (!allowSecond && !instanceLock.tryLock(100)) {
        qint64 pid = 0; QString host, appName;
        instanceLock.getLockInfo(&pid, &host, &appName);

        // Forward the request over the running instance's MPRIS, then exit.
        // The desktop file's Actions and MimeType rely on this.
#ifndef Q_OS_WIN
        const QStringList args = QCoreApplication::arguments().mid(1);
        QDBusInterface player(QStringLiteral("org.mpris.MediaPlayer2.melo"),
                              QStringLiteral("/org/mpris/MediaPlayer2"),
                              QStringLiteral("org.mpris.MediaPlayer2.Player"),
                              QDBusConnection::sessionBus());
        bool handled = false;
        if (player.isValid()) {
            for (const QString& a : args) {
                if (a == QStringLiteral("--play-pause")) { player.call(QStringLiteral("PlayPause")); handled = true; }
                else if (a == QStringLiteral("--next"))     { player.call(QStringLiteral("Next")); handled = true; }
                else if (a == QStringLiteral("--previous")) { player.call(QStringLiteral("Previous")); handled = true; }
                else if (!a.startsWith(QStringLiteral("--"))) {
                    const QUrl u = QUrl::fromUserInput(a, QDir::currentPath(), QUrl::AssumeLocalFile);
                    player.call(QStringLiteral("OpenUri"), u.toString());
                    handled = true;
                }
            }
            if (!handled) {   // a bare re-launch: bring the window forward
                QDBusInterface root(QStringLiteral("org.mpris.MediaPlayer2.melo"),
                                    QStringLiteral("/org/mpris/MediaPlayer2"),
                                    QStringLiteral("org.mpris.MediaPlayer2"),
                                    QDBusConnection::sessionBus());
                if (root.isValid()) { root.call(QStringLiteral("Raise")); handled = true; }
            }
        }
        if (handled) return 0;
#endif
        std::fprintf(stderr,
                     "[melo] already running (pid %lld) on this config directory: %s\n"
                     "[melo] set MELO_CONFIG_DIR to run a second instance against its own files\n",
                     static_cast<long long>(pid), qPrintable(meloConfigDir()));
#ifdef Q_OS_WIN
        MessageBoxW(nullptr, L"melo is already running.", L"melo", MB_ICONINFORMATION);
#endif
        return 0;
    }

    // Fonts melo ships, plus anything the user has dropped in their own fonts
    // folder. The default family is only a default if it is actually there:
    // relying on the system to have Red Hat Display means it renders in
    // whatever the system substitutes on any machine that does not.
    {
        QStringList dirs;
        dirs << QCoreApplication::applicationDirPath() + QStringLiteral("/fonts")
             // ../share/melo/fonts: where `cmake --install` and a distro
             // package put them
             << QCoreApplication::applicationDirPath() + QStringLiteral("/../share/melo/fonts")
             << QStringLiteral(MELO_FONT_DIR)
             << meloConfigDir() + QStringLiteral("/fonts");
        int loaded = 0;
        for (const QString& d : dirs) {
            QDir dir(d);
            if (!dir.exists()) continue;
            for (const QString& n : dir.entryList({"*.otf", "*.ttf", "*.ttc", "*.woff2"},
                                                  QDir::Files, QDir::Name))
                if (QFontDatabase::addApplicationFont(dir.filePath(n)) >= 0) ++loaded;
        }
        if (loaded) qInfo("[fonts] loaded %d", loaded);
    }

    // Probe for real OpenGL 3.3: Qt Quick runs on GL 2.1, and projectM would
    // segfault there. Linux uses it only to gate projectM; Windows also picks
    // GL or Qt's default D3D11 (WARP fallback) from it.
    bool hasGL = false;
    {
        QOpenGLContext probe;
        if (probe.create()) {
            const QSurfaceFormat f = probe.format();
            hasGL = f.majorVersion() > 3
                 || (f.majorVersion() == 3 && f.minorVersion() >= 3);
        }
    }
#ifdef Q_OS_WIN
    if (hasGL) QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    else std::fprintf(stderr, "[melo] no OpenGL 3.3 — D3D11/WARP scene graph, visualizer disabled\n");
#else
    if (!hasGL) std::fprintf(stderr, "[melo] no OpenGL 3.3 — visualizer disabled\n");
#endif

    // Declared BEFORE the engine: destructs AFTER it (and after the decks it
    // owns spawn their final teardown workers) but BEFORE ~QGuiApplication:
    // the workers' gst frees would race Qt shutdown and corrupt the heap
    // (intermittent exit SIGABRT).
    struct DeckTeardownJoiner {
        ~DeckTeardownJoiner() { SourceDeck::joinAllTeardowns(); }
    } deckTeardownJoiner;

    // --- object graph ---
    PcmQueue pcmQueue;
    AudioEngine engine(pcmQueue);
    VisualizerItem::setPcmQueue(&pcmQueue);

    SidecarService sidecar;
    PlayerState playerState;
    QueueModel queueModel;
    SuggestionsModel suggestionsModel;
    SettingsStore settings(&sidecar);
    ThemeStore themeStore(&settings);
    LibraryStore library(&sidecar, &settings);
    PlaybackCoordinator coordinator(&engine, &sidecar, &playerState,
                                    &queueModel, &suggestionsModel, &settings);
    WindowController windowCtl;

    // interactive resize -> freeze tick-driven UI updates (see coordinator)
    QObject::connect(&windowCtl, &WindowController::interactiveStarted,
                     &coordinator, [&coordinator] { coordinator.setUiFrozen(true); });
    QObject::connect(&windowCtl, &WindowController::mainGeometry,
                     &coordinator, [&coordinator] { coordinator.setUiFrozen(false); });

    QObject::connect(&sidecar, &SidecarService::rpcFailed,
                     [&playerState](const QString& what, const QString& msg) {
        std::fprintf(stderr, "[melo] RPC %s failed: %s\n",
                     what.toUtf8().constData(), msg.toUtf8().constData());
        if (what != "search") playerState.setError(what + ": " + msg);
    });
    // lite build, no usable node: fetch the pinned runtime, then retry
    NodeBootstrap nodeSetup;
    QObject::connect(&sidecar, &SidecarService::nodeMissing,
                     &nodeSetup, &NodeBootstrap::download);
    QObject::connect(&nodeSetup, &NodeBootstrap::finished,
                     &sidecar, [&sidecar](bool ok) { if (ok) sidecar.start(); });

    sidecar.start();

    // qmlRegisterType is process-global, so plugin engines resolve `import Melo
    // 1.0` too. Each type refuses a foreign engine at componentComplete, checked
    // against meloOwnEngine(); see MeloEngineOnly.h.
    qmlRegisterType<VisualizerItem>("Melo", 1, 0, "Visualizer");
    qmlRegisterType<BackgroundItem>("Melo", 1, 0, "BackgroundItem");
    qmlRegisterType<ParticlesItem>("Melo", 1, 0, "ParticlesItem");
    qmlRegisterType<BlendItem>("Melo", 1, 0, "BlendRect");
    qmlRegisterType<WindowShapeItem>("Melo", 1, 0, "WindowShape");

    // Application-wide QShortcuts, so keys still work while a plugin window
    // has focus. Declared before the engine so it outlives the QML naming it.
    CommandMap commandMap;
    InterceptMap interceptMap;
    SlotMap slotMap;
    BarButtons barButtons;
    PluginFills pluginFills;
    coordinator.setInterceptOffer([&](const QString& action) {
        return interceptMap.offer(action);
    });
    coordinator.setInterceptOccupied([&](const QString& a) {
        return !interceptMap.occupant(a).isEmpty();
    });

    QQmlApplicationEngine qml;
    meloOwnEngine() = &qml;   // the one engine Melo 1.0 types may live in

    qml.rootContext()->setContextProperty("CommandMap", &commandMap);
    qml.rootContext()->setContextProperty("InterceptMap", &interceptMap);
    qml.rootContext()->setContextProperty("SlotMap", &slotMap);
    qml.rootContext()->setContextProperty("BarButtons", &barButtons);
    auto* frameClock = new FrameClock(&app);
    qml.rootContext()->setContextProperty("FrameClock", frameClock);
    // every window that exists after load, and any that appears later
    QObject::connect(&app, &QGuiApplication::focusWindowChanged, frameClock, [frameClock](QWindow* w) {
        if (auto* qw = qobject_cast<QQuickWindow*>(w)) if (!qw->property("frameClockWatched").toBool()) { qw->setProperty("frameClockWatched", true); frameClock->watch(qw); }
    });
    // ...and on a window that never takes focus. Attaching only on focus means
    // a measured run made while the desktop is busy elsewhere reports frames=0
    // and zeroes every per-frame statistic, silently — the drag still happens,
    // nothing counts it. A window that is exposed is a window worth watching.
    {
        auto* sweep = new QTimer(frameClock);
        sweep->setInterval(250);
        QObject::connect(sweep, &QTimer::timeout, frameClock, [frameClock] {
            for (QWindow* w : QGuiApplication::allWindows())
                if (auto* qw = qobject_cast<QQuickWindow*>(w))
                    if (qw->isExposed() && !qw->property("frameClockWatched").toBool()) {
                        qw->setProperty("frameClockWatched", true);
                        frameClock->watch(qw);
                    }
        });
        sweep->start();
    }
    qml.rootContext()->setContextProperty("PluginFills", &pluginFills);
    qml.rootContext()->setContextProperty("Player", &coordinator);
    qml.rootContext()->setContextProperty("PlayerState", &playerState);
    qml.rootContext()->setContextProperty("Queue", &queueModel);
    qml.rootContext()->setContextProperty("Suggestions", &suggestionsModel);
    qml.rootContext()->setContextProperty("Settings", &settings);
    qml.rootContext()->setContextProperty("ThemeBackend", &themeStore);
    qml.rootContext()->setContextProperty("Library", &library);
    qml.rootContext()->setContextProperty("sidecar", &sidecar);
    qml.rootContext()->setContextProperty("WindowCtl", &windowCtl);
    PortalDialog portal;
    qml.rootContext()->setContextProperty("Portal", &portal);
    SpectrumSource spectrum;
    qml.rootContext()->setContextProperty("Spectrum", &spectrum);
    BackgroundItem::setSpectrum(&spectrum);
    // false when this machine can't do OpenGL 3.3 (Windows VMs/RDP): the UI
    // runs on D3D11/WARP and QML disables projectM gracefully
    qml.rootContext()->setContextProperty("MELO_HAS_GL", hasGL);
    qml.rootContext()->setContextProperty("MELO_LIB_DEBUG",
                                         qEnvironmentVariableIsSet("MELO_LIB_DEBUG"));
    // MELO_FOCUS_DEBUG=1: trace window-activation state (taskbar-focus bugs)
    qml.rootContext()->setContextProperty("MELO_FOCUS_DEBUG",
        qEnvironmentVariableIsSet("MELO_FOCUS_DEBUG"));
    // MELO_ARRANGE_DEBUG=1: trace the arranger's drag — press, threshold,
    // begin, move, and every way it can end
    qml.rootContext()->setContextProperty("MELO_ARRANGE_DEBUG",
        qEnvironmentVariableIsSet("MELO_ARRANGE_DEBUG"));
    // MELO_BAR_DEBUG=1: every bar arrangement decision (document, width,
    // variant, crossfade)
    qml.rootContext()->setContextProperty("MELO_BAR_DEBUG",
        qEnvironmentVariableIsSet("MELO_BAR_DEBUG"));
    // MELO_GEOM_DEBUG=1: trace the windows' own geometry changes
    qml.rootContext()->setContextProperty("MELO_GEOM_DEBUG",
        qEnvironmentVariableIsSet("MELO_GEOM_DEBUG"));
    // MELO_INK_DEBUG=1: every ink-bearing label says what it decided
    qml.rootContext()->setContextProperty("MELO_INK_DEBUG",
                                          qEnvironmentVariableIsSet("MELO_INK_DEBUG"));
    qml.rootContext()->setContextProperty("NodeSetup", &nodeSetup);
    // non-empty on lite builds whose system GStreamer lacks pieces
    qml.rootContext()->setContextProperty("MELO_MISSING_GST", missingGst.join(", "));
    // distro-exact install hint for the missing-plugins error (lite builds
    // lean on system GStreamer; a bare install has core only)
    {
        QString hint = QStringLiteral("install your distro's GStreamer plugin packages");
#ifndef Q_OS_WIN
        QFile osr(QStringLiteral("/etc/os-release"));
        if (osr.open(QIODevice::ReadOnly)) {
            const QString os = QString::fromUtf8(osr.readAll());
            auto idHas = [&os](const char* k) {
                return os.contains(QLatin1String(k), Qt::CaseInsensitive);
            };
            if (idHas("arch") || idHas("manjaro") || idHas("endeavour"))
                hint = QStringLiteral("run: sudo pacman -S gst-plugins-base gst-plugins-good");
            else if (idHas("debian") || idHas("ubuntu") || idHas("mint") || idHas("pop"))
                hint = QStringLiteral("run: sudo apt install gstreamer1.0-plugins-base gstreamer1.0-plugins-good");
            else if (idHas("fedora") || idHas("nobara"))
                hint = QStringLiteral("run: sudo dnf install gstreamer1-plugins-base gstreamer1-plugins-good");
            else if (idHas("opensuse") || idHas("suse"))
                hint = QStringLiteral("run: sudo zypper install gstreamer-plugins-base gstreamer-plugins-good");
        }
#endif
        qml.rootContext()->setContextProperty("MELO_GST_HINT", hint);
    }
    // Declared BEFORE the load, null, so Main.qml can test them: an identifier
    // that was never a context property is a ReferenceError in a binding, not
    // undefined. Filled in by rebuildUiPlugins() below when at least one plugin
    // holds the `ui` grant; null the rest of the time, which is the default.
    qml.rootContext()->setContextProperty("PluginWindows", nullptr);
    qml.rootContext()->setContextProperty("PluginUi", nullptr);

    // QML dir: env override -> beside the executable (packaged/portable
    // layout) -> the dev tree path compiled in at build time. The packaged
    // exe MUST NOT rely on MELO_DEV_QML_DIR — that's the build machine's path.
    QString qmlDir = qEnvironmentVariable("MELO_QML_DIR");
    if (qmlDir.isEmpty()) {
        // NB: "melo-qml", NOT "qml" — windeployqt owns appdir/qml (Qt's own
        // QML modules), and copying into it nested our UI at qml/qml/
        const QString local = QCoreApplication::applicationDirPath() + "/melo-qml";
        qmlDir = QFileInfo::exists(local + "/Main.qml") ? local
                                                        : QStringLiteral(MELO_DEV_QML_DIR);
    }
    static MeloNamFactory meloNamFactory;
    qml.setNetworkAccessManagerFactory(&meloNamFactory);
    // Decoded once: see ThumbImageProvider. Inert until QML asks for
    // image://thumb/<url>, so adding it changes nothing on its own.
    qml.addImageProvider(QString::fromLatin1(ThumbImageProvider::kProviderId),
                         new ThumbImageProvider(meloConfigDir()
                                                + QStringLiteral("/httpcache")));
#ifdef MELO_EXTRA_STARTUP
    meloExtraStartup(qml, qmlDir, engine);
#endif
    qml.load(QUrl::fromLocalFile(qmlDir + "/Main.qml"));
    if (qml.rootObjects().isEmpty()) {
        std::fprintf(stderr, "[melo] failed to load Main.qml\n");
        // QQmlApplicationEngine swallows the diagnostics for some load
        // failures (a duplicate signal handler prints nothing at all), so
        // re-compile through QQmlComponent purely to recover the error list
        QQmlComponent probe(&qml, QUrl::fromLocalFile(qmlDir + "/Main.qml"));
        for (const QQmlError &e : probe.errors())
            std::fprintf(stderr, "[melo]   %s\n", qPrintable(e.toString()));
#ifdef Q_OS_WIN
        // GUI-subsystem app: stderr is invisible — surface the fatal visibly
        MessageBoxW(nullptr,
                    L"melo failed to load its UI (qml folder missing beside melo.exe?)",
                    L"melo", MB_ICONERROR);
#endif
        return 1;
    }

    // The line CI greps for (`melo --smoke`): every QML startup failure fails
    // the root component, and no unit suite instantiates the real root.
    std::fprintf(stderr, "[melo] ui ready\n");
    if (smoke) {
        // Long enough for deferred loaders and the sidecar handshake to have
        // thrown if they are going to; short enough to be a CI step.
        QTimer::singleShot(4000, &app, [] { QGuiApplication::quit(); });
    }

    // MPRIS: taskbar hover controls, media keys, KDE Connect (Linux only)
#ifndef Q_OS_WIN
    MprisService mpris(&coordinator, &playerState);
    if (auto* w = qobject_cast<QWindow*>(qml.rootObjects().first()))
        mpris.setWindow(w);
    // A file association, a `melo <path>` from a terminal, or a second launch
    // handing its arguments over — all arrive as MPRIS OpenUri and land here.
    // Queued: OpenUri is delivered on the D-Bus thread.
    QObject::connect(&mpris, &MprisService::openUriRequested, qml.rootObjects().first(),
                     [root = qml.rootObjects().first()](const QString& uri) {
                         QMetaObject::invokeMethod(root, "openExternalUri", Qt::QueuedConnection,
                                                   Q_ARG(QVariant, uri));
                     });
    // Files given to the FIRST instance on its own command line.
    {
        QStringList opens;
        for (const QString& a : QCoreApplication::arguments().mid(1))
            if (!a.startsWith(QStringLiteral("--"))) opens << a;
        if (!opens.isEmpty()) {
            QObject* root = qml.rootObjects().first();
            QTimer::singleShot(0, root, [root, opens] {
                for (const QString& a : opens)
                    QMetaObject::invokeMethod(root, "openExternalUri", Qt::QueuedConnection,
                        Q_ARG(QVariant, QUrl::fromUserInput(a, QDir::currentPath(),
                                                            QUrl::AssumeLocalFile).toString()));
            });
        }
    }
#endif

    // --- ui plugins ---
    // One stack per plugin holding the `ui` grant; the grant is the whole load
    // key. Compact is first-party (Main.qml builtinMini).
    QObject* qmlRoot = qml.rootObjects().first();
    QWindow* mainWindow = qobject_cast<QWindow*>(qmlRoot);
    struct UiPluginStack {
        // Destroyed in REVERSE declaration order, which is the order that
        // matters: windows first (plugin items lose their visual parent while
        // their engine is still alive), then the QML host (which destroys the
        // content it owns), then the bridge its context property named.
        std::unique_ptr<MeloUi> bridge;
        std::unique_ptr<PluginUiHost> host;
        std::unique_ptr<PluginWindowHost> windows;
        QString id;
        // What the CURRENT stack was built from. The id alone is not enough: a
        // plugin restart reloads its manifest under the SAME id, and a changed
        // `ui` block or entry qml has to rebuild the windows.
        QByteArray builtFrom;
    };
    std::vector<UiPluginStack> uiPlugins;
    // The two objects QML names, both of them forwarders over the stacks above.
    // Reset with them, and null whenever there are none — Main.qml and the
    // settings window both test for null.
    std::unique_ptr<PluginWindowsHub> uiHub;
    std::unique_ptr<PluginUiHub> pluginUiHub;
    QJsonArray pluginList;
    bool pluginListAsked = false;

    interceptMap.setPluginInvoker([&](const QString& pluginId, const QString& action) {
        return pluginUiHub && pluginUiHub->invokeIntercept(pluginId, action);
    });

    auto rebuildInterceptOccupancy = [&] {
        interceptMap.clearOccupants();
        for (const QJsonValue& v : pluginList) {
            const QJsonObject p = v.toObject();
            if (!p.value("enabled").toBool()) continue;
            const QJsonArray acts = p.value("grants").toObject().value("intercept").toArray();
            const QString id = p.value("id").toString();
            if (id.isEmpty()) continue;
            for (const QJsonValue& a : acts) {
                const QString act = a.toString();
                if (!act.isEmpty())
                    interceptMap.setOccupant(act, id);
            }
        }
    };

    // Puts slot occupants on screen, on a rebuild (the old engine's item is
    // dead) or a binding change. One row per slot melo has a gate for; the
    // rest of the catalog draws nothing. A new slot is a gate in Main.qml and
    // a row here.
    struct LiveSlot { const char* id; QPointer<QObject> item; QPointer<PluginUiHost> host; QString qml; };
    std::vector<LiveSlot> liveSlots{{"visualizer", {}, {}, {}}, {"queuePanel", {}, {}, {}}};
    auto rebuildSlotContent = [&] {
        for (LiveSlot& live : liveSlots) {
            const QString slot = QString::fromLatin1(live.id);
            const QString qml = slotMap.qmlFor(slot);
            const QString owner = slotMap.occupant(slot);
            PluginUiHost* host = nullptr;
            for (const UiPluginStack& st : uiPlugins)
                if (st.id == owner) { host = st.host.get(); break; }
            // Idempotent: both callers fire on unrelated changes, and re-creating
            // an occupant loses its state. The host is part of the identity: a
            // rebuilt plugin has a new engine even with the same slot and path.
            if (live.item && live.host == host && live.qml == qml) continue;
            if (live.item) { delete live.item.data(); live.item = nullptr; }
            live.host = nullptr;
            live.qml.clear();
            if (qml.isEmpty() || !host) continue;   // builtin, hidden, or not loaded
            auto* gate = qmlRoot->findChild<QQuickItem*>(
                QStringLiteral("meloSlot:") + slot);
            if (!gate) continue;
            // The offer carries an ABSOLUTE path (rebuildSlotOffers joins it
            // onto the plugin dir). QDir::filePath returns an absolute argument
            // unchanged, so the host resolves it the same either way.
            live.item = host->createSlotContent(qml, gate);
            if (!live.item) {
                std::fprintf(stderr, "[melo] plugin %s: slot %s failed: %s\n",
                             owner.toUtf8().constData(), live.id,
                             host->errorString().toUtf8().constData());
                continue;
            }
            live.host = host;
            live.qml = qml;
            QMetaObject::invokeMethod(gate, "fit");
        }
    };
    // The user's pick in Appearance reaches SlotMap directly from QML, so the
    // binding changing has to be a route into this too — the offers rebuild
    // only covers the plugin list changing.
    QObject::connect(&slotMap, &SlotMap::changed, qmlRoot, [&] { rebuildSlotContent(); });

    // Slot offers need the ui grant, as windows do. Paths are made absolute
    // here because melo's own QML loads them. Binds are untouched: a plugin
    // going away empties its offers and the user's pick survives (SlotMap.h).
    auto rebuildSlotOffers = [&] {
        QHash<QString, QHash<QString, QString>> offers;
        for (const QJsonValue& v : pluginList) {
            const QJsonObject p = v.toObject();
            if (!p.value("enabled").toBool()) continue;
            if (!p.value("grants").toObject().value("ui").toBool()) continue;
            const QString id = p.value("id").toString();
            const QString dir = p.value("dir").toString();
            const QJsonObject decl = p.value("ui").toObject().value("slots").toObject();
            if (id.isEmpty() || dir.isEmpty() || decl.isEmpty()) continue;
            QHash<QString, QString> bySlot;
            for (auto it = decl.constBegin(); it != decl.constEnd(); ++it) {
                const QString rel = it.value().toString();
                if (!rel.isEmpty()) bySlot.insert(it.key(), QDir(dir).filePath(rel));
            }
            if (!bySlot.isEmpty()) offers.insert(id, bySlot);
        }
        slotMap.setOffers(offers);
        rebuildSlotContent();
    };

    // Plugin bar buttons: ui grant required, replaced wholesale like slot
    // offers. The user's hidden set is not touched here; Main.qml restores it.
    auto rebuildBarButtons = [&] {
        QVariantList out;
        for (const QJsonValue& v : pluginList) {
            const QJsonObject p = v.toObject();
            if (!p.value("enabled").toBool()) continue;
            if (!p.value("grants").toObject().value("ui").toBool()) continue;
            const QString id = p.value("id").toString();
            const QString dir = p.value("dir").toString();
            if (id.isEmpty() || dir.isEmpty()) continue;
            for (const QJsonValue& bv : p.value("ui").toObject().value("buttons").toArray()) {
                const QJsonObject b = bv.toObject();
                const QString icon = b.value("icon").toString();
                out << QVariantMap{
                    {QStringLiteral("pluginId"), id},
                    {QStringLiteral("id"),       b.value("id").toString()},
                    {QStringLiteral("bar"),      b.value("bar").toString()},
                    {QStringLiteral("label"),    b.value("label").toString()},
                    // Qualified here, because that is what CommandMap dispatches
                    // and what a keyboard binding to the same command uses — a
                    // button and a shortcut must not be able to diverge.
                    {QStringLiteral("command"),  id + QLatin1Char('.')
                                                 + b.value("command").toString()},
                    // Absolute, and a URL: the Image that draws it is melo's own
                    // QML, which has no plugin dir to resolve against.
                    {QStringLiteral("icon"),     icon.isEmpty()
                                                 ? QString()
                                                 : QUrl::fromLocalFile(
                                                       QDir(dir).filePath(icon)).toString()}};
            }
        }
        barButtons.setButtons(out);
        // the plugins' fills, the same gate: enabled, and ui granted
        QVariantList fills;
        for (const QJsonValue& v : pluginList) {
            const QJsonObject p = v.toObject();
            if (!p.value("enabled").toBool()) continue;
            if (!p.value("grants").toObject().value("ui").toBool()) continue;
            const QString id = p.value("id").toString();
            const QString dir = p.value("dir").toString();
            if (id.isEmpty() || dir.isEmpty()) continue;
            for (const QJsonValue& fv : p.value("ui").toObject().value("fills").toArray()) {
                const QJsonObject f = fv.toObject();
                fills << QVariantMap{
                    {QStringLiteral("kind"),    id + QLatin1Char('.') + f.value("id").toString()},
                    {QStringLiteral("name"),    f.value("name").toString()},
                    {QStringLiteral("colours"), f.value("colours").toInt(1)},
                    {QStringLiteral("base"),    f.value("base").toBool(f.value("colours").toInt(1) >= 1)},
                    {QStringLiteral("palette"), f.value("palette").toBool(f.value("colours").toInt(1) >= 2)},
                    {QStringLiteral("shaped"),  f.value("shaped").toBool(false)},
                    {QStringLiteral("shader"),  QUrl::fromLocalFile(
                                                    QDir(dir).filePath(f.value("shader").toString())).toString()}};
            }
        }
        pluginFills.setFills(fills);
    };

    // Returns true when it actually tore the stacks down and rebuilt them.
    auto rebuildUiPlugins = [&]() -> bool {
        // Everything a stack is built out of, in one comparable value.
        // Deliberately not the whole plugin entry: `state` flips on every
        // restart and rebuilding the windows for that would be a visible
        // flicker for nothing.
        const auto sigOf = [](const QJsonObject& p) {
            return QJsonDocument(QJsonObject{
                {"dir",      p.value("dir")},
                {"entryQml", p.value("entryQml")},
                {"ui",       p.value("ui")},
                // The schema is MeloUi.archives' allowlist, so a changed `file`
                // field must rebuild. Values reload via MeloUiSettings::changed.
                {"settings", p.value("settings")},
            }).toJson(QJsonDocument::Compact);
        };
        // List order, which is the sidecar's stable order: the comparison below
        // is positional, and so is window stacking.
        std::vector<QJsonObject> wanted;
        for (const QJsonValue& v : std::as_const(pluginList)) {
            const QJsonObject p = v.toObject();
            // The whole predicate: an ungranted plugin's QML is never
            // instantiated. Skipped plugins are not errors here.
            if (!p.value("enabled").toBool()) continue;
            if (!p.value("error").isNull()) continue;
            if (!p.value("ui").isObject()) continue;
            if (!p.value("grants").toObject().value("ui").toBool()) continue;
            if (p.value("entryQml").toString().isEmpty()) continue;
            wanted.push_back(p);
        }
        // A plugins/changed usually changes nothing melo builds from (a plugin
        // process restarted), and tearing every granted plugin's windows down
        // for one is a visible flicker across all of them.
        bool same = wanted.size() == uiPlugins.size();
        for (size_t i = 0; same && i < wanted.size(); ++i)
            same = wanted[i].value("id").toString() == uiPlugins[i].id
                   && sigOf(wanted[i]) == uiPlugins[i].builtFrom;
        if (same) {
            rebuildInterceptOccupancy();
            rebuildSlotOffers();
            rebuildBarButtons();
            return false;
        }

        qml.rootContext()->setContextProperty("PluginWindows", nullptr);
        qml.rootContext()->setContextProperty("PluginUi", nullptr);
        // Hubs before stacks: they hold pointers into them, and the context
        // properties above are already off the QML side.
        uiHub.reset();
        pluginUiHub.reset();
        uiPlugins.clear();
        // Unhide melo first on every teardown, or windows that no longer exist
        // leave nothing on screen. The plugin asks again once its windows are up.
        QMetaObject::invokeMethod(qmlRoot, "setShellHidden", Q_ARG(QVariant, false));
        if (wanted.empty()) {
            commandMap.setPluginInvoker([](const QString&, const QString&) { return false; });
            interceptMap.setPluginInvoker([](const QString&, const QString&) { return false; });
            QMetaObject::invokeMethod(qmlRoot, "syncPluginMini");
            rebuildInterceptOccupancy();
            rebuildSlotOffers();
            rebuildBarButtons();
            return true;
        }
        uiHub = std::make_unique<PluginWindowsHub>();
        pluginUiHub = std::make_unique<PluginUiHub>();
        commandMap.setPluginInvoker([&](const QString& pluginId, const QString& id) {
            return pluginUiHub && pluginUiHub->invokeCommand(pluginId, id);
        });
        interceptMap.setPluginInvoker([&](const QString& pluginId, const QString& action) {
            return pluginUiHub && pluginUiHub->invokeIntercept(pluginId, action);
        });

        for (const QJsonObject& pick : wanted) {
            const QString id = pick.value("id").toString();
            const QString dir = pick.value("dir").toString();
            UiPluginStack stack;
            stack.id = id;
            stack.builtFrom = sigOf(pick);
            stack.bridge = std::make_unique<MeloUi>(id, dir, &playerState, &coordinator,
                                                    &sidecar, &queueModel,
                                                    &suggestionsModel, &spectrum);
            MeloUi* bridge = stack.bridge.get();
            // BEFORE the settings fetch and before any plugin QML runs: the
            // schema is the allowlist MeloUi.archives answers get() from, and an
            // empty one means every key is refused.
            bridge->setSettingsSchema(pick.value("settings").toArray());
            if (auto* s = bridge->settingsObj()) s->refresh();
            stack.host = std::make_unique<PluginUiHost>(id, dir, bridge);
            PluginUiHost* host = stack.host.get();
            // On this plugin's engine only, never `qml` (tst_plugincontainment
            // asserts it); one per plugin, or every decoded skin would be one
            // image:// url from every other plugin.
            if (auto* a = bridge->archivesObj()) host->installArchiveProvider(a->resolver());
            // Settings-page writes have to be pushed to the live plugin;
            // nothing else would. QPointer, because plugin QML can reach
            // refreshSettings() and the bridge is not guaranteed to still be
            // there when it does.
            host->setSettingsRefresher([b = QPointer<MeloUi>(bridge)] {
                if (b) if (auto* s = b->settingsObj()) s->refresh();
            });
            if (!host->load(pick.value("entryQml").toString())) {
                std::fprintf(stderr, "[melo] plugin %s: entry qml failed: %s\n",
                             id.toUtf8().constData(), host->errorString().toUtf8().constData());
                // Kept in the vector anyway: this is the record the comparison
                // above remembers the attempt by, so a plugins/changed that
                // changed nothing does not retry a broken plugin — and does not
                // tear every working plugin's windows down to do it.
                uiPlugins.push_back(std::move(stack));
                continue;
            }
            // melo's own settings window drives `action` fields through this,
            // keyed by id: with two granted plugins, a single `pluginId` on the
            // hub would send plugin A's Run button into plugin B's entry.qml.
            pluginUiHub->add(id, host);
            QObject::connect(bridge->appObj(), &MeloUiApp::pluginSettingsRequested, qmlRoot,
                             [qmlRoot, id] {
                if (auto* sw = qmlRoot->findChild<QObject*>("settingsWin")) {
                    sw->setProperty("tab", QStringLiteral("plugins"));
                    QMetaObject::invokeMethod(sw, "open");
                    // LAST, not first: both the tab change and open() reset the
                    // settings window to the plugin LIST, so targeting the page
                    // before them lands the user one screen short of where the
                    // plugin's own control said it was going.
                    QMetaObject::invokeMethod(sw, "openPluginSettings",
                                              Q_ARG(QVariant, QVariant(id)));
                }
            });
            // A plugin's windows get the FFT whatever melo's background is set
            // to; the host follows window visibility and releases on teardown.
            stack.windows = std::make_unique<PluginWindowHost>(host, bridge, mainWindow,
                                                               &windowCtl, &spectrum);
            QObject::connect(bridge->appObj(), &MeloUiApp::scaleRequested, stack.windows.get(),
                             &PluginWindowHost::setScale);
            // A skin's close/eject button asks to be dismissed, not to switch
            // melo's presentation — compact is first-party (MeloUi.h). melo's
            // own window is NOT raised here: dismissing a plugin the user put
            // in front of another application must not also steal that focus.
            QObject::connect(bridge->appObj(), &MeloUiApp::exitMiniModeRequested,
                             stack.windows.get(), &PluginWindowHost::dismissWindows);
            // ...and the same button gives melo back, or dismissing a skin that
            // had hidden the shell would leave an empty desktop.
            QObject::connect(bridge->appObj(), &MeloUiApp::exitMiniModeRequested, qmlRoot,
                             [qmlRoot] {
                QMetaObject::invokeMethod(qmlRoot, "setShellHidden", Q_ARG(QVariant, false));
            });
            QObject::connect(bridge->appObj(), &MeloUiApp::alwaysUpRequested,
                             stack.windows.get(), &PluginWindowHost::setAlwaysUp);
            QObject::connect(bridge->appObj(), &MeloUiApp::shellHiddenRequested, qmlRoot,
                             [qmlRoot](bool hidden) {
                QMetaObject::invokeMethod(qmlRoot, "setShellHidden", Q_ARG(QVariant, hidden));
            });
            // A slots-only (or buttons-only) plugin has no windows, and that
            // is a declaration melo accepts — see validateUi. Building a window
            // host for it would fail on an empty `windows` array and report it
            // as a broken plugin.
            const QJsonObject uiBlock = pick.value("ui").toObject();
            if (uiBlock.value("windows").toArray().isEmpty()) {
                stack.windows.reset();
                uiPlugins.push_back(std::move(stack));
                continue;
            }
            if (!stack.windows->build(uiBlock)) {
                std::fprintf(stderr, "[melo] plugin %s: windows failed: %s\n",
                             id.toUtf8().constData(),
                             stack.windows->errorString().toUtf8().constData());
                stack.windows.reset();   // no half-built windows on screen
                uiPlugins.push_back(std::move(stack));
                continue;
            }
            // Active in full mode, which is where these windows live: the
            // manifest's `initial` decides which of them are shown, and nothing
            // else would tell them to follow it.
            stack.windows->setActive(true, true);
            uiHub->add(stack.windows.get());
            uiPlugins.push_back(std::move(stack));
        }
        // Named only when there is something behind them: a hub that answers
        // for nothing would make Main.qml's `PluginWindows` non-null and push an
        // empty entry list into its KWin call.
        if (!uiHub->isEmpty())
            qml.rootContext()->setContextProperty("PluginWindows", uiHub.get());
        if (!pluginUiHub->isEmpty())
            qml.rootContext()->setContextProperty("PluginUi", pluginUiHub.get());
        // Restate the folded opacity so the KWin call covers the windows that
        // just appeared. It must not HIDE them: compact is first-party, so
        // syncPluginMini does not gate plugin windows on mini mode.
        QMetaObject::invokeMethod(qmlRoot, "syncPluginMini");
        rebuildInterceptOccupancy();
        rebuildSlotOffers();
        rebuildBarButtons();
        return true;
    };

    // A successful first fetch clears the bridge's retry flag, so a sidecar or
    // plugin restart would leave a stale bag; re-fetch here, where both show.
    auto refreshPluginSettings = [&] {
        for (const UiPluginStack& stack : uiPlugins)
            if (stack.bridge)
                if (auto* s = stack.bridge->settingsObj()) s->refresh();
    };

    QObject::connect(&sidecar, &SidecarService::pluginsChanged, &app,
                     [&](const QJsonArray& plugins) {
        pluginList = plugins;
        // A rebuild constructs fresh bridges, which fetch settings themselves.
        // Only the no-op path needs this: a plugin restart that changed nothing
        // melo builds from (which is what a plugins/changed usually is) can
        // still have changed its settings SCHEMA, and nothing else would re-read it.
        if (!rebuildUiPlugins()) refreshPluginSettings();
    });
    // Nothing else in melo asks for the plugin list at startup (the settings
    // window does it on open), so a plugin granted `ui` in a previous session
    // would never load. Ask once, unconditionally: the grant lives in the LIST,
    // so there is no setting melo could read first to decide whether to bother.
    auto maybeAskForPlugins = [&] {
        if (pluginListAsked || !sidecar.ready()) return;
        pluginListAsked = true;
        sidecar.listPlugins();
    };
    QObject::connect(&sidecar, &SidecarService::readyChanged, &app, [&] {
        if (!sidecar.ready()) return;
        refreshPluginSettings();
        // The ask is gated on sidecar.ready(), so it has to be re-tried from
        // here: settings-loaded is the other route in and it is not guaranteed
        // to arrive after this one.
        maybeAskForPlugins();
    });
    QObject::connect(&settings, &SettingsStore::loadedChanged, &app, maybeAskForPlugins);
    QObject::connect(&settings, &SettingsStore::changed, &app, [&] {
        maybeAskForPlugins();
        rebuildUiPlugins();
    });

    for (QWindow* w : QGuiApplication::allWindows())
        if (auto* qw = qobject_cast<QQuickWindow*>(w)) if (!qw->property("frameClockWatched").toBool()) { qw->setProperty("frameClockWatched", true); frameClock->watch(qw); }
    const int rc = app.exec();
    if (smoke) {
        const int n = g_smokeQmlErrors.load();
        std::fprintf(stderr, "[melo] smoke: %d QML diagnostic(s)\n", n);
        return n == 0 ? rc : 3;
    }
    return rc;

}
