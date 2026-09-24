// Per-window compositor geometry and the drag-snapping it enables:
//   1. The generated KWin script runs in a QJSEngine against a fake
//      `workspace`, so the pid guard, pid-unique bus name and own-property
//      caption lookup are checked by behaviour.
//   2. The payload is one string: callDBus marshals a JS number as a double,
//      so a five-argument call fails to match an int slot (GeometryReceiver in
//      WindowController.h). Both halves are asserted.
//   3. A report moves the docked group, except a window's first one, which the
//      watcher sends on arming.
// Offscreen with no KWin, moveWindows() is a no-op and QWindow::setPosition is
// the move, which makes group geometry observable.
#include <QtTest>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJSEngine>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QMetaObject>
#include <QMetaProperty>
#include <limits>
#include <QTemporaryDir>
#include <QWindow>
#include <memory>

#include "MeloUi.h"
#include "MeloUiArchives.h"
#include "PluginUiHost.h"
#include "PluginWindowHost.h"
#include "SpectrumSource.h"
#include "WindowController.h"

// ---------------------------------------------------------------------------
// A three-window plugin on disk. main <- eq <- pl: a chain, because a group that
// follows one link would pass every assertion a two-window fixture can make.
// ---------------------------------------------------------------------------
static const int kMainH = 80, kEqH = 116, kPlH = 60, kShadeH = 20;
// The resize grid, one case per window: main vh plus a shade height (their
// ordering decides whether a resizable window can shade), eq v only (a
// compositor width can be refused), pl no resize block (fixed-size). Both
// declared sizes are on-grid (80 = minimum, 116 = 58 + 2*29); the off-grid
// manifest is its own fixture.
static const int kStepW = 25, kStepH = 29;
static const int kEqMinH = 58;

struct PluginFixture {
    QTemporaryDir dir;
    std::unique_ptr<MeloUi> bridge;
    std::unique_ptr<PluginUiHost> ui;
    std::unique_ptr<PluginWindowHost> host;
    QJsonObject uiBlock;              // what build() handed the host

    static QString title(const QString& id) {
        return QStringLiteral("melo-plugin-snapper-%1").arg(id);
    }

    // A stub window.qml on disk, a bridge, a plugin engine and a host — the
    // part every rig here needs before it has said anything about windows.
    bool prepare(WindowController* wc, SpectrumSource* spectrum) {
        if (!dir.isValid()) return false;
        QFile f(QDir(dir.path()).filePath(QStringLiteral("window.qml")));
        const QByteArray body = "import QtQuick\nRectangle { color: \"#202020\" }\n";
        if (!f.open(QIODevice::WriteOnly) || f.write(body) != body.size()) return false;
        f.close();

        bridge = std::make_unique<MeloUi>(QStringLiteral("snapper"), dir.path(),
                                          nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
        ui = std::make_unique<PluginUiHost>(QStringLiteral("snapper"), dir.path(), bridge.get());
        if (!ui->engine() || !ui->load(QString())) return false;
        host = std::make_unique<PluginWindowHost>(ui.get(), bridge.get(), nullptr, wc, spectrum);
        return true;
    }

    // The real multi-window manifest on the real host. Only each window's `qml`
    // is repointed at the stub (the skin's QML needs a decoded skin and melo's
    // injected world); every number and topology is the manifest's. Sets *why
    // on failure, so a missing manifest fails the suite instead of emptying it.
    bool buildShipped(WindowController* wc, QString* why) {
        // Mirrors the Winamp skin plugin's manifest.json (ui.windows, ui.snap):
        // three windows, a snapTo chain, a two-axis resize grid, a shade height
        // and a snap distance;
        // re-copy when those blocks change there.
        const QString path =
            QStringLiteral(MELO_TEST_FIXTURES "/skin-plugin/manifest.json");
        QFile mf(path);
        if (!mf.open(QIODevice::ReadOnly)) { *why = QStringLiteral("cannot read ") + path; return false; }
        QJsonParseError perr{};
        const QJsonDocument doc = QJsonDocument::fromJson(mf.readAll(), &perr);
        if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
            *why = path + QStringLiteral(": ") + perr.errorString();
            return false;
        }
        QJsonObject block = doc.object().value(QStringLiteral("ui")).toObject();
        QJsonArray decls = block.value(QStringLiteral("windows")).toArray();
        if (decls.isEmpty()) { *why = path + QStringLiteral(": no ui.windows"); return false; }
        QJsonArray out;
        for (const QJsonValue& v : std::as_const(decls)) {
            QJsonObject d = v.toObject();
            if (!d.value(QStringLiteral("qml")).toString().endsWith(QStringLiteral(".qml"))) {
                *why = path + QStringLiteral(": a window declares no qml file");
                return false;
            }
            d.insert(QStringLiteral("qml"), QStringLiteral("window.qml"));
            out << d;
        }
        block.insert(QStringLiteral("windows"), out);
        if (!prepare(wc, nullptr)) { *why = QStringLiteral("fixture setup failed"); return false; }
        uiBlock = block;
        if (!host->build(uiBlock)) { *why = host->errorString(); return false; }
        return true;
    }

    // `spectrum` null: no FFT arbiter, and the host holds no owner key (asserted
    // below). `offGridPl` declares pl off its own resize grid, the mistake the
    // shell corrects at build. `zeroMins` writes eq's minima as an explicit 0 ("no
    // minimum", not one). `hidden` names windows declared `initial: "hidden"`, as
    // the skin ships (main <- eq(hidden) <- pl(hidden)).
    bool build(WindowController* wc, bool cyclic = false, SpectrumSource* spectrum = nullptr,
               bool offGridPl = false, bool zeroMins = false,
               const QStringList& hidden = {}) {
        if (!prepare(wc, spectrum)) return false;

        auto win = [](const QString& id, int h, const QString& snapTo) {
            QJsonObject o{{QStringLiteral("id"), id},
                          {QStringLiteral("qml"), QStringLiteral("window.qml")},
                          {QStringLiteral("width"), 320},
                          {QStringLiteral("height"), h}};
            if (!snapTo.isEmpty()) o.insert(QStringLiteral("snapTo"), snapTo);
            return o;
        };
        QJsonObject main = win(QStringLiteral("main"), kMainH,
                               // A snapTo CYCLE, which the manifest validator
                               // rejects but this class promises to survive
                               // regardless.
                               cyclic ? QStringLiteral("eq") : QString());
        main.insert(QStringLiteral("primary"), true);
        main.insert(QStringLiteral("shade"),
                    QJsonObject{{QStringLiteral("height"), kShadeH}});
        main.insert(QStringLiteral("resize"),
                    QJsonObject{{QStringLiteral("axes"), QStringLiteral("vh")},
                                {QStringLiteral("stepW"), kStepW},
                                {QStringLiteral("stepH"), kStepH},
                                {QStringLiteral("minWidth"), 320},
                                {QStringLiteral("minHeight"), kMainH}});
        QJsonObject eq = win(QStringLiteral("eq"), kEqH, QStringLiteral("main"));
        eq.insert(QStringLiteral("resize"),
                  zeroMins
                      ? QJsonObject{{QStringLiteral("axes"), QStringLiteral("vh")},
                                    {QStringLiteral("stepH"), kStepH},
                                    {QStringLiteral("stepW"), kStepW},
                                    {QStringLiteral("minWidth"), 0},
                                    {QStringLiteral("minHeight"), 0}}
                      : QJsonObject{{QStringLiteral("axes"), QStringLiteral("v")},
                                    {QStringLiteral("stepH"), kStepH},
                                    {QStringLiteral("minHeight"), kEqMinH}});
        QJsonObject pl = win(QStringLiteral("pl"), kPlH, QStringLiteral("eq"));
        if (offGridPl)
            pl.insert(QStringLiteral("resize"),
                      QJsonObject{{QStringLiteral("axes"), QStringLiteral("v")},
                                  {QStringLiteral("stepH"), kStepH},
                                  {QStringLiteral("minHeight"), kEqMinH}});   // 60 is not 58 + k*29
        QJsonArray decls;
        for (QJsonObject* w : {&main, &eq, &pl}) {
            if (hidden.contains(w->value(QStringLiteral("id")).toString()))
                w->insert(QStringLiteral("initial"), QStringLiteral("hidden"));
            decls << *w;
        }
        uiBlock = QJsonObject{
            {QStringLiteral("snap"), QJsonObject{{QStringLiteral("distance"), 10}}},
            {QStringLiteral("windows"), decls}};
        return host->build(uiBlock);
    }

    // The real QQuickWindow behind an id, found by the caption the host
    // registered. position() changes only when melo calls setPosition (on
    // Wayland a user drag is never reported to the client), so this is for
    // melo's own moves; at() below is where a window is.
    QWindow* window(const QString& id) const {
        for (QWindow* w : QGuiApplication::topLevelWindows())
            if (w->title() == title(id)) return w;
        return nullptr;
    }

    // The ui.windows[] entry this fixture declared for `id` — what the host
    // read, rather than a second copy of it written out in the test.
    QJsonObject declOf(const QString& id) const {
        for (const QJsonValue& v : uiBlock.value(QStringLiteral("windows")).toArray())
            if (v.toObject().value(QStringLiteral("id")).toString() == id) return v.toObject();
        return {};
    }

    MeloUiWindow* facade(const QString& id) const {
        return qobject_cast<MeloUiWindow*>(bridge->window().value(id).value<QObject*>());
    }

    // A panel's own size, through the same facade a plugin reads. Not
    // window()->size(): once a docked group shares one window, that is the
    // BOX, and a test asking it for a panel's height gets the whole stack.
    QSize sizeOf(const QString& id) const {
        QObject* f = bridge->window().value(id).value<QObject*>();
        return f ? QSize(f->property("width").toInt(), f->property("height").toInt()) : QSize();
    }

    // Where the host believes the window is — the same value a plugin reads as
    // MeloUi.window.<id>.x/y, and the value every snap computation uses.
    QPoint at(const QString& id) const {
        QObject* f = bridge->window().value(id).value<QObject*>();
        return f ? QPoint(f->property("x").toInt(), f->property("y").toInt()) : QPoint();
    }
};

// ---------------------------------------------------------------------------
// The generated KWin script, RUN. `workspace` and `callDBus` are the only two
// names it depends on, so a fake of each turns the script into something a test
// can observe instead of grep.
// ---------------------------------------------------------------------------
struct ScriptRun {
    QJSEngine js;
    QString error;

    // wins: {pid, caption, x, y, w, h}
    struct FakeWin { qint64 pid; QString caption; int x, y, w, h; };

    bool run(const QString& script, const QList<FakeWin>& wins) {
        QString harness = QStringLiteral(
            "var calls = [];\n"
            "function callDBus() { calls.push(Array.prototype.slice.call(arguments)); }\n"
            "function mkWin(pid, caption, x, y, w, h) {\n"
            "  var hs = [], gs = [];\n"
            "  return { pid: pid, caption: caption, resize: false,\n"
            "           frameGeometry: { x: x, y: y, width: w, height: h },\n"
            "           frameGeometryChanged: { connect: function(f) { gs.push(f); } },\n"
            "           interactiveMoveResizeFinished: { connect: function(f) { hs.push(f); } },\n"
            "           armed: function() { return hs.length; },\n"
            "           geometryArmed: function() { return gs.length; },\n"
            "           move: function(nx, ny) {\n"
            "             this.frameGeometry = { x: nx, y: ny, width: this.frameGeometry.width,\n"
            "                                    height: this.frameGeometry.height };\n"
            "             for (var i = 0; i < gs.length; ++i) gs[i]();\n"
            "           },\n"
            "           fire: function() { for (var i = 0; i < hs.length; ++i) hs[i](); } };\n"
            "}\n"
            "var wins = [];\n"
            "var addedHandlers = [];\n"
            "var workspace = { windowList: function() { return wins; },\n"
            "                  windowAdded: { connect: function(f) { addedHandlers.push(f); } },\n"
            "                  cursorPos: { x: 0, y: 0 } };\n");
        for (const FakeWin& w : wins) {
            // The caption as a JS string literal. The U+2028/U+2029 escape is
            // the HARNESS's own: they are line terminators in JS, so a raw one
            // here would be a SyntaxError in this fake rather than in the
            // script under test, and the row would fail for the wrong reason.
            QString lit = QString::fromUtf8(QJsonDocument(QJsonArray{w.caption})
                                                .toJson(QJsonDocument::Compact))
                              .mid(1).chopped(1);
            lit.replace(QChar(0x2028), QLatin1String("\\u2028"));
            lit.replace(QChar(0x2029), QLatin1String("\\u2029"));
            harness += QStringLiteral("wins.push(mkWin(%1, %2, %3, %4, %5, %6));\n")
                           .arg(QString::number(w.pid), lit,
                                QString::number(w.x), QString::number(w.y),
                                QString::number(w.w), QString::number(w.h));
        }
        if (!eval(harness)) return false;
        return eval(script);
    }

    bool eval(const QString& code) {
        const QJSValue v = js.evaluate(code);
        if (v.isError()) {
            error = v.toString();
            return false;
        }
        return true;
    }

    // Every callDBus the script has made so far, as JSON.
    QJsonArray calls() {
        const QJSValue v = js.evaluate(QStringLiteral("JSON.stringify(calls)"));
        return QJsonDocument::fromJson(v.toString().toUtf8()).array();
    }
    QJSValue value(const QString& expr) { return js.evaluate(expr); }
};

class TstWindowSnap : public QObject {
    Q_OBJECT

    static constexpr qint64 kPid = 4242;
    static QString svc() { return QStringLiteral("com.melo.Geometry.instance4242"); }
    static QString cap(const QString& id) {
        return QStringLiteral("melo-plugin-snapper-%1").arg(id);
    }

    // Emit the controller's per-window report. QMetaObject rather than a
    // friend declaration, and the return value is CHECKED: a renamed or
    // re-signatured signal must fail this test, not silently do nothing.
    static void report(WindowController* wc, const QString& caption, int x, int y,
                       int w = 320, int h = 80) {
        const bool sent = QMetaObject::invokeMethod(
            wc, "windowGeometry", Qt::DirectConnection,
            Q_ARG(QString, caption), Q_ARG(int, x), Q_ARG(int, y),
            Q_ARG(int, w), Q_ARG(int, h));
        QVERIFY2(sent, "WindowController::windowGeometry(QString,int,int,int,int) is not there");
    }

private slots:

    // ---------------------------------------------------------------- script

    // 1. The pid guard, executed. Two windows with the SAME caption and
    //    different pids — which is the real situation, melo is multi-instance
    //    and captions are per-plugin, not per-process. Exactly one report.
    void theScriptReportsOnlyThisProcessesWindows() {
        ScriptRun r;
        QVERIFY2(r.run(WindowController::windowGeometryScript(
                           {cap("main"), cap("eq")}, kPid, svc()),
                       {{kPid, cap("main"), 100, 200, 320, kMainH},
                        {kPid + 1, cap("main"), 900, 900, 320, kMainH},
                        {kPid + 1, cap("eq"), 900, 900, 320, kEqH}}),
                 qPrintable(r.error));

        const QJsonArray calls = r.calls();
        QCOMPARE(calls.size(), 1);
        const QJsonArray c = calls.at(0).toArray();
        QCOMPARE(c.at(0).toString(), svc());
        QCOMPARE(c.at(1).toString(), QStringLiteral("/melo/geometry"));
        QCOMPARE(c.at(2).toString(), QStringLiteral("com.melo.Geometry"));
        QCOMPARE(c.at(3).toString(), QStringLiteral("ReportWindow"));
        // ONE argument after the method name, and it is the whole geometry.
        QCOMPARE(c.size(), 5);
        QCOMPARE(c.at(4).toString(), cap("main") + QStringLiteral(",100,200,320,80"));

        // ...and the other instance's windows were not even connected to.
        QCOMPARE(r.value(QStringLiteral("wins[0].armed()")).toInt(), 1);
        QCOMPARE(r.value(QStringLiteral("wins[1].armed()")).toInt(), 0);
        QCOMPARE(r.value(QStringLiteral("wins[2].armed()")).toInt(), 0);
    }

    // 2. A completed user drag reports again, with the new geometry. Without
    //    this the script could arm nothing and still pass test 1's first half.
    void aFinishedInteractiveMoveReportsTheNewGeometry() {
        ScriptRun r;
        QVERIFY2(r.run(WindowController::windowGeometryScript({cap("main")}, kPid, svc()),
                       {{kPid, cap("main"), 0, 0, 320, kMainH}}), qPrintable(r.error));
        QCOMPARE(r.calls().size(), 1);
        QVERIFY2(r.eval(QStringLiteral(
            "wins[0].frameGeometry = { x: 640, y: 480, width: 320, height: 80 };\n"
            "wins[0].fire();\n")), qPrintable(r.error));
        const QJsonArray calls = r.calls();
        QCOMPARE(calls.size(), 2);
        QCOMPARE(calls.at(1).toArray().at(4).toString(),
                 cap("main") + QStringLiteral(",640,480,320,80"));
    }

    // 3. A window KWin has not told us about yet. On Wayland a surface reaches
    //    the compositor asynchronously, so the windows melo just mapped can be
    //    absent from windowList() when the script runs; windowAdded is what
    //    stops the watcher from silently missing exactly its own windows.
    void aWindowThatAppearsLaterIsArmedToo() {
        ScriptRun r;
        QVERIFY2(r.run(WindowController::windowGeometryScript(
                           {cap("main"), cap("eq")}, kPid, svc()), {}), qPrintable(r.error));
        QCOMPARE(r.calls().size(), 0);
        QVERIFY(r.value(QStringLiteral("addedHandlers.length")).toInt() > 0);
        QVERIFY2(r.eval(QStringLiteral(
            "var late = mkWin(%1, \"%2\", 7, 8, 320, 116);\n"
            "addedHandlers[0](late);\n"
            "var foreign = mkWin(%3, \"%2\", 1, 1, 320, 116);\n"
            "addedHandlers[0](foreign);\n"
            "var unwatched = mkWin(%1, \"melo\", 1, 1, 320, 116);\n"
            "addedHandlers[0](unwatched);\n")
            .arg(QString::number(kPid), cap("eq"), QString::number(kPid + 1))),
            qPrintable(r.error));
        const QJsonArray calls = r.calls();
        QCOMPARE(calls.size(), 1);      // the late one only
        QCOMPARE(calls.at(0).toArray().at(4).toString(),
                 cap("eq") + QStringLiteral(",7,8,320,116"));
        QCOMPARE(r.value(QStringLiteral("foreign.armed()")).toInt(), 0);
        QCOMPARE(r.value(QStringLiteral("unwatched.armed()")).toInt(), 0);
    }

    // 4. A caption that is a property of Object.prototype. Plain member lookup
    //    walks the prototype chain, so `want[caption]` is TRUTHY for a window
    //    captioned "toString" — it would be watched and reported without ever
    //    having been asked for. Same hazard setWindowOpacities documents.
    void aCaptionFromTheProtoypeChainIsNotWatched() {
        ScriptRun r;
        QVERIFY2(r.run(WindowController::windowGeometryScript({cap("main")}, kPid, svc()),
                       {{kPid, QStringLiteral("toString"), 1, 2, 3, 4},
                        {kPid, QStringLiteral("constructor"), 1, 2, 3, 4},
                        {kPid, QStringLiteral("hasOwnProperty"), 1, 2, 3, 4},
                        {kPid, cap("main"), 5, 6, 320, kMainH}}), qPrintable(r.error));
        const QJsonArray calls = r.calls();
        QCOMPARE(calls.size(), 1);
        QCOMPARE(calls.at(0).toArray().at(4).toString(),
                 cap("main") + QStringLiteral(",5,6,320,80"));
    }


    // Every plugin-facing member appears in docs/plugins.md, checked against
    // the metaobjects: it is all a plugin author has. Only a code span counts
    // (`play()`, not "play" in prose).
    void everyFacadeMemberIsInTheDocs() {
        QFile f(QStringLiteral(MELO_REPO_DIR "/docs/plugins.md"));
        QVERIFY2(f.open(QIODevice::ReadOnly), "cannot read docs/plugins.md");
        const QString doc = QString::fromUtf8(f.readAll());

        QSet<QString> documented;
        static const QRegularExpression notWord(QStringLiteral("[^A-Za-z0-9_]"));
        auto take = [&](const QString& text) {
            for (const QString& tok : text.split(notWord, Qt::SkipEmptyParts))
                documented.insert(tok);
        };
        // Fenced blocks first, then removed. A fence is three backticks, so
        // leaving them in shifts inline pairing by one for the rest of the
        // file: the scanner starts taking prose as code and eats the opening
        // backtick of the next real span.
        QString prose = doc;
        static const QRegularExpression fence(
            QStringLiteral("```[^\n]*\n(.*?)```"),
            QRegularExpression::DotMatchesEverythingOption);
        auto fences = fence.globalMatch(doc);
        while (fences.hasNext()) take(fences.next().captured(1));
        prose.remove(fence);
        // The examples are documentation too, which is why their contents were
        // taken above rather than dropped with them.
        static const QRegularExpression span(QStringLiteral("`([^`]+)`"));
        auto spans = span.globalMatch(prose);
        while (spans.hasNext()) take(spans.next().captured(1));

        struct Facade { const char* path; const QMetaObject* mo; };
        const QVector<Facade> facades{
            {"MeloUi",             &MeloUi::staticMetaObject},
            {"MeloUi.player",      &MeloUiPlayer::staticMetaObject},
            {"MeloUi.settings",    &MeloUiSettings::staticMetaObject},
            {"MeloUi.queue",       &MeloUiQueue::staticMetaObject},
            {"MeloUi.suggestions", &MeloUiSuggestions::staticMetaObject},
            {"MeloUi.eq",          &MeloUiEq::staticMetaObject},
            {"MeloUi.spectrum",    &MeloUiSpectrum::staticMetaObject},
            {"MeloUi.app",         &MeloUiApp::staticMetaObject},
            {"MeloUi.window.<id>", &MeloUiWindow::staticMetaObject},
            {"MeloUi.archives",    &MeloUiArchives::staticMetaObject},
            {"MeloUi.archives.get(...)", &MeloUiArchive::staticMetaObject},
        };

        QStringList missing;
        for (const Facade& fa : facades) {
            const QMetaObject* mo = fa.mo;
            for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
                const QString n = QString::fromLatin1(mo->property(i).name());
                if (!documented.contains(n))
                    missing << QStringLiteral("%1.%2").arg(QLatin1String(fa.path), n);
            }
            for (int i = mo->methodOffset(); i < mo->methodCount(); ++i) {
                const QMetaMethod m = mo->method(i);
                // Q_INVOKABLE only. A signal is reachable too, but its name is
                // the property's `changed` in every case here.
                if (m.methodType() != QMetaMethod::Method) continue;
                const QString n = QString::fromLatin1(m.name());
                if (!documented.contains(n))
                    missing << QStringLiteral("%1.%2()").arg(QLatin1String(fa.path), n);
            }
        }
        QVERIFY2(missing.isEmpty(),
                 qPrintable(QStringLiteral("undocumented, add to docs/plugins.md: ")
                                + missing.join(QStringLiteral(", "))));
    }

    // The built-in mini queue follows its bar inside KWin instead of waiting
    // for a client round trip. Plugin docking uses the same mechanism, but its
    // links are one-way: a main drag carries EQ/playlist, while dragging EQ is
    // free to disconnect it and carries only EQ's own playlist descendant.
    void pluginGlueMovesTheGroupLiveButNeverMovesAnAncestor() {
        const QVariantList links{
            QVariantMap{{"leader", cap("main")}, {"follower", cap("eq")},
                        {"dx", 0}, {"dy", kMainH}},
            QVariantMap{{"leader", cap("main")}, {"follower", cap("pl")},
                        {"dx", 0}, {"dy", kMainH + kEqH}},
            QVariantMap{{"leader", cap("eq")}, {"follower", cap("pl")},
                        {"dx", 0}, {"dy", kEqH}},
        };
        ScriptRun r;
        QVERIFY2(r.run(WindowController::pluginWindowGlueScript(links, kPid),
                       {{kPid, cap("main"), 0, 0, 320, kMainH},
                        {kPid, cap("eq"), 0, kMainH, 320, kEqH},
                        {kPid, cap("pl"), 0, kMainH + kEqH, 320, kPlH}}),
                 qPrintable(r.error));

        // One compositor geometry signal places every descendant immediately.
        QVERIFY2(r.eval(QStringLiteral("wins[0].move(500, 300);")), qPrintable(r.error));
        QCOMPARE(r.value(QStringLiteral("wins[1].frameGeometry.x")).toInt(), 500);
        QCOMPARE(r.value(QStringLiteral("wins[1].frameGeometry.y")).toInt(), 300 + kMainH);
        QCOMPARE(r.value(QStringLiteral("wins[2].frameGeometry.x")).toInt(), 500);
        QCOMPARE(r.value(QStringLiteral("wins[2].frameGeometry.y")).toInt(),
                 300 + kMainH + kEqH);

        // Moving the child has no reverse link to main. It is therefore a real
        // independent drag; its own descendant still follows in the same pass.
        QVERIFY2(r.eval(QStringLiteral("wins[1].move(700, 40);")), qPrintable(r.error));
        QCOMPARE(r.value(QStringLiteral("wins[0].frameGeometry.x")).toInt(), 500);
        QCOMPARE(r.value(QStringLiteral("wins[0].frameGeometry.y")).toInt(), 300);
        QCOMPARE(r.value(QStringLiteral("wins[2].frameGeometry.x")).toInt(), 700);
        QCOMPARE(r.value(QStringLiteral("wins[2].frameGeometry.y")).toInt(), 40 + kEqH);
    }

    void pluginGlueDoesNotFightResizeAndArmsLateWindows() {
        const QVariantList links{
            QVariantMap{{"leader", cap("main")}, {"follower", cap("eq")},
                        {"dx", 0}, {"dy", kMainH}},
        };
        ScriptRun r;
        QVERIFY2(r.run(WindowController::pluginWindowGlueScript(links, kPid),
                       {{kPid, cap("main"), 0, 0, 320, kMainH}}), qPrintable(r.error));
        QVERIFY(r.value(QStringLiteral("addedHandlers.length")).toInt() > 0);
        QVERIFY2(r.eval(QStringLiteral(
            "var late = mkWin(%1, \"%2\", 900, 900, 320, 116);\n"
            "addedHandlers[0](late);\n")
            .arg(QString::number(kPid), cap("eq"))), qPrintable(r.error));
        QCOMPARE(r.value(QStringLiteral("late.frameGeometry.x")).toInt(), 0);
        QCOMPARE(r.value(QStringLiteral("late.frameGeometry.y")).toInt(), kMainH);

        // Same rule as regular mini glue: no per-frame reposition while the
        // leader is resizing, then one final seat on resize-finished.
        QVERIFY2(r.eval(QStringLiteral(
            "wins[0].resize = true; wins[0].move(50, 60);\n")), qPrintable(r.error));
        QCOMPARE(r.value(QStringLiteral("late.frameGeometry.x")).toInt(), 0);
        QVERIFY2(r.eval(QStringLiteral(
            "wins[0].resize = false; wins[0].fire();\n")), qPrintable(r.error));
        QCOMPARE(r.value(QStringLiteral("late.frameGeometry.x")).toInt(), 50);
        QCOMPARE(r.value(QStringLiteral("late.frameGeometry.y")).toInt(), 60 + kMainH);
    }

    // 5. Captions a plugin can produce that would break the whole script.
    //    Every row must still parse and still watch its window: a SyntaxError
    //    drops the watcher for every window.
    void ahostileCaptionDoesNotBreakTheScript_data() {
        QTest::addColumn<QString>("caption");
        QTest::newRow("line separator U+2028")
            << QStringLiteral("melo-plugin-a%1main").arg(QChar(0x2028));
        QTest::newRow("paragraph separator U+2029")
            << QStringLiteral("melo-plugin-a%1main").arg(QChar(0x2029));
        // %1/%2 are QString::arg markers: with a CHAINED arg() the caption's
        // marker swallows the pid substitution and leaves a literal %2 behind.
        QTest::newRow("arg marker") << QStringLiteral("%1-%2");
        QTest::newRow("double quote") << QStringLiteral("a\"b");
        QTest::newRow("backslash") << QStringLiteral("a\\b");
        QTest::newRow("newline") << QStringLiteral("a\nb");
        QTest::newRow("comma") << QStringLiteral("a,b");
        QTest::newRow("brace") << QStringLiteral("}); evil(); ({");
    }

    void ahostileCaptionDoesNotBreakTheScript() {
        QFETCH(QString, caption);
        const QString script = WindowController::windowGeometryScript({caption}, kPid, svc());
        // The pid substitution survived the caption (the chained-arg defect).
        QVERIFY2(script.contains(QStringLiteral("w.pid !== 4242")),
                 qPrintable(QStringLiteral("no pid guard in:\n%1").arg(script)));
        // Raw U+2028/U+2029 are JS line terminators inside a string literal:
        // legal in JSON, a SyntaxError in JS, and the whole script is dropped.
        QVERIFY(!script.contains(QChar(0x2028)));
        QVERIFY(!script.contains(QChar(0x2029)));

        ScriptRun r;
        QVERIFY2(r.run(script, {{kPid, caption, 11, 22, 320, 80}}), qPrintable(r.error));
        const QJsonArray calls = r.calls();
        QCOMPARE(calls.size(), 1);
        QCOMPARE(calls.at(0).toArray().at(4).toString(),
                 caption + QStringLiteral(",11,22,320,80"));
    }

    // --------------------------------------------------------------- payload

    // 6. The ONE-STRING payload, parsed. The caption is taken from the LEFT of
    //    the last four fields, so a comma in it round-trips; a field that is
    //    not a number drops the report rather than becoming a 0 that would
    //    teleport a window to the screen corner.
    void theOneStringPayloadIsParsedOrDropped_data() {
        QTest::addColumn<QString>("payload");
        QTest::addColumn<bool>("ok");
        QTest::addColumn<QString>("caption");
        QTest::addColumn<int>("x");
        QTest::addColumn<int>("y");
        QTest::addColumn<int>("w");
        QTest::addColumn<int>("h");

        QTest::newRow("ordinary") << QStringLiteral("melo-plugin-a-main,10,20,320,80")
                                  << true << QStringLiteral("melo-plugin-a-main") << 10 << 20 << 320 << 80;
        QTest::newRow("negative") << QStringLiteral("cap,-5,-600,320,80")
                                  << true << QStringLiteral("cap") << -5 << -600 << 320 << 80;
        // KWin hands these over as JS numbers stringified; a fractional scale
        // can produce a decimal point where an int slot would have failed.
        QTest::newRow("decimals") << QStringLiteral("cap,810.0,242.5,275.0,116.0")
                                  << true << QStringLiteral("cap") << 810 << 242 << 275 << 116;
        QTest::newRow("comma in the caption") << QStringLiteral("a,b,1,2,3,4")
                                  << true << QStringLiteral("a,b") << 1 << 2 << 3 << 4;
        QTest::newRow("too few fields") << QStringLiteral("cap,1,2,3") << false << QString() << 0 << 0 << 0 << 0;
        QTest::newRow("empty") << QString() << false << QString() << 0 << 0 << 0 << 0;
        QTest::newRow("no caption") << QStringLiteral(",1,2,3,4") << false << QString() << 0 << 0 << 0 << 0;
        QTest::newRow("x is not a number") << QStringLiteral("cap,x,2,3,4") << false << QString() << 0 << 0 << 0 << 0;
        QTest::newRow("h is not a number") << QStringLiteral("cap,1,2,3,undefined") << false << QString() << 0 << 0 << 0 << 0;
        QTest::newRow("nothing but commas") << QStringLiteral(",,,,") << false << QString() << 0 << 0 << 0 << 0;
    }

    void theOneStringPayloadIsParsedOrDropped() {
        QFETCH(QString, payload);
        QFETCH(bool, ok);
        GeometryReceiver rx;
        QSignalSpy spy(&rx, &GeometryReceiver::windowReported);
        rx.ReportWindow(payload);
        QCOMPARE(spy.count(), ok ? 1 : 0);
        if (!ok) return;
        QFETCH(QString, caption);
        QFETCH(int, x); QFETCH(int, y); QFETCH(int, w); QFETCH(int, h);
        const QList<QVariant> a = spy.at(0);
        QCOMPARE(a.at(0).toString(), caption);
        QCOMPARE(a.at(1).toInt(), x);
        QCOMPARE(a.at(2).toInt(), y);
        QCOMPARE(a.at(3).toInt(), w);
        QCOMPARE(a.at(4).toInt(), h);
    }

    // 7. The main-window report is a DIFFERENT slot and must be unaffected:
    //    the per-window payload has five fields and so does that one.
    void theMainWindowReportStillParsesTheSameWay() {
        GeometryReceiver rx;
        QSignalSpy reported(&rx, &GeometryReceiver::reported);
        QSignalSpy perWindow(&rx, &GeometryReceiver::windowReported);
        QSignalSpy started(&rx, &GeometryReceiver::resizeStarted);
        rx.Report(QStringLiteral("810,242,275,116,1"));
        QCOMPARE(reported.count(), 1);
        QCOMPARE(reported.at(0), (QList<QVariant>{810, 242, 275, 116, true}));
        QCOMPARE(perWindow.count(), 0);
        rx.Report(QStringLiteral("start"));
        QCOMPARE(started.count(), 1);

        // A move is its own report. KWin raises one signal for both, so the
        // script says which — and only a resize freezes anything. The bare
        // "start" stays the resize so an older payload cannot silently become
        // a move.
        QSignalSpy moved(&rx, &GeometryReceiver::moveStarted);
        rx.Report(QStringLiteral("startMove"));
        QCOMPARE(moved.count(), 1);
        QCOMPARE(started.count(), 1);       // and it is NOT a resize
        QCOMPARE(reported.count(), 1);      // nor a geometry report
    }

    // 8. The whole landing pad, over a real session bus: the object is exported
    //    under com.melo.Geometry, ReportWindow takes ONE STRING, and a
    //    five-argument call — which is what callDBus would produce if the
    //    payload were split into numbers — is refused by DBus itself.
    void theReportArrivesOverDbusAsOneStringAndOnlyAsOneString() {
        if (!QDBusConnection::sessionBus().isConnected())
            QSKIP("no session bus");
        WindowController wc;
        QSignalSpy spy(&wc, &WindowController::windowGeometry);
        // The connection's own unique name: registerObject is per-CONNECTION,
        // so this reaches the same object as the pid-unique well-known name
        // whether or not that one could be registered.
        QDBusInterface self(QDBusConnection::sessionBus().baseService(),
                            QStringLiteral("/melo/geometry"),
                            QStringLiteral("com.melo.Geometry"),
                            QDBusConnection::sessionBus());
        QVERIFY(self.isValid());
        QDBusReply<void> one = self.call(QStringLiteral("ReportWindow"),
                                         QStringLiteral("melo-plugin-a-main,10,20,320,80"));
        QVERIFY2(one.isValid(), qPrintable(one.error().message()));
        QTRY_COMPARE(spy.count(), 1);
        QCOMPARE(spy.at(0).at(0).toString(), QStringLiteral("melo-plugin-a-main"));
        QCOMPARE(spy.at(0).at(1).toInt(), 10);
        QCOMPARE(spy.at(0).at(4).toInt(), 80);

        // Why the payload is one string: numbers as separate arguments do not
        // reach the slot at all.
        QDBusReply<void> many = self.call(QStringLiteral("ReportWindow"),
                                          QStringLiteral("melo-plugin-a-main"),
                                          10.0, 20.0, 320.0, 80.0);
        QVERIFY(!many.isValid());
        QCOMPARE(spy.count(), 1);
    }

    // ------------------------------------------------------------------ host

    // 9. The first report is adoption. The watcher reports once when it arms,
    //    and where the compositor put a window is not the user dragging it. A
    //    host that snapped on it would carry the docked group by the difference
    //    between melo's placement and the compositor's.
    void theFirstReportForAWindowDoesNotMoveTheGroup() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QCOMPARE(fx.window(QStringLiteral("main"))->position(), QPoint(0, 0));
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));

        report(&wc, cap("main"), 500, 300);
        QTest::qWait(300);   // longer than the 120ms settle: nothing must happen
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));
        // ...and the adopted position is what the plugin now reads back.
        QCOMPARE(fx.bridge->window().value(QStringLiteral("main"))
                     .value<QObject*>()->property("x").toInt(), 500);
    }

    // 10. A user drag of the primary, reported by the compositor, carries the
    //     two windows docked to it: one directly, one through the chain. On
    //     Wayland this report is the only notice melo gets.
    void aReportedUserDragCarriesTheDockedGroup() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);            // arm (adoption)
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        report(&wc, cap("main"), 500, 300);        // the drag
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
        // The dragged window itself is left where the user put it: it has no
        // snapTo, so there is nothing to be magnetic to.
        QCOMPARE(fx.bridge->window().value(QStringLiteral("main"))
                     .value<QObject*>()->property("y").toInt(), 300);
    }

    // 10f. A move is not a resize. A system move carries size configures, so
    //      quantisation is deferred during the grab and skipped when it ends.
    //      The move ends on its starting size exactly: physical -> logical ->
    //      physical drifts at a fractional scale. Only a resizable window can
    //      drift, so the playlist shows it.
    void aMoveNeverResizesTheWindowBeingMovedAtFractionalScale() {
        WindowController wc;
        PluginFixture fx;
        QString why;
        QVERIFY2(fx.buildShipped(&wc, &why), qPrintable(why));
        const double scale = 1.3;   // fractional
        fx.host->setScale(scale);

        fx.facade(QStringLiteral("eq"))->show();
        fx.facade(QStringLiteral("playlist"))->show();
        QTest::qWait(250);
        QWindow* pl = fx.window(QStringLiteral("playlist"));
        report(&wc, cap("playlist"), pl->x(), pl->y());
        QTest::qWait(250);

        // The fixture's playlist declaration, so the row can compute what
        // quantising at the end of the move would produce.
        QJsonObject plDecl;
        for (const QJsonValue& v : fx.uiBlock.value(QStringLiteral("windows")).toArray())
            if (v.toObject().value(QStringLiteral("id")).toString() == QLatin1String("playlist"))
                plDecl = v.toObject();
        QVERIFY2(!plDecl.isEmpty(), "the shipped manifest has no playlist window");
        auto quantisedAtScale = [&](const QSize& physical) {
            const QSize logical(qRound(physical.width() / scale),
                                qRound(physical.height() / scale));
            const QSize p = PluginWindowHost::quantiseSize(plDecl, logical);
            return QSize(qMax(1, qRound(p.width() * scale)),
                         qMax(1, qRound(p.height() * scale)));
        };

        const QSize settled = pl->size();
        // Big enough to cross a step of the grid: for a one-pixel configure,
        // quantising and keeping the start size agree, and the row could not
        // fail.
        const QSize nudged(settled.width(), settled.height() - 20);
        QVERIFY2(quantisedAtScale(nudged) != settled,
                 "the nudge does not cross a step — this row cannot fail");

        fx.host->startPluginWindowDrag(QStringLiteral("playlist"));
        pl->resize(nudged);
        QTest::qWait(50);
        QCOMPARE(pl->size(), nudged);   // the configure really landed

        report(&wc, cap("playlist"), pl->x() + 400, pl->y() + 250);
        QTest::qWait(300);              // past the reflow settle

        QCOMPARE(pl->size(), settled);
    }

    // 10d. The watcher reports on interactiveMoveResizeFinished, so the group
    //      moves at once; a settle timer would only add a pause and a jump.
    //      QCOMPARE, not QTRY: the group has to have moved in this call.
    void aFinishedWaylandDragCarriesTheGroupWithoutWaitingToSettle() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);

        report(&wc, cap("main"), 500, 300);
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
    }

    // 10e. KWin reports applySnap's placement a pixel off; treated as a drag,
    //      it snaps back inside the 10px magnet and jitters. The landing is
    //      adopted and the group ignores the one-pixel delta.
    void aCompositorEchoOfOurOwnPlacementDoesNotMoveTheGroup() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        report(&wc, cap("main"), 500, 300);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(500, 300 + kMainH + kEqH));

        report(&wc, cap("eq"), 501, 300 + kMainH);   // 1px off where we placed it
        QTest::qWait(300);                          // longer than settle, if any
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(501, 300 + kMainH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(500, 300 + kMainH + kEqH));
    }

    // 10f. The user taking a window we just placed. startDrag is what tells
    //      the host the next Finished is theirs, not a stale compositor
    //      report — without that, 10e's absorb would also drop a real grab of
    //      an attached window the moment after the group settled.
    void aUserDragOfAWindowWeJustPlacedStillCarriesTheGroup() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        report(&wc, cap("main"), 500, 300);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(500, 300 + kMainH + kEqH));

        fx.host->setActive(true, false);
        fx.facade(QStringLiteral("eq"))->startDrag();
        report(&wc, cap("eq"), 800, 400);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(800, 400));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(800, 400 + kEqH));
    }

    // 10c. `movedId_` and the settle timer are single, so a stale notification
    //      taken as a user move replaces the pending drag and the group stops
    //      following. placeInitial's geometry changes arrive after moving_
    //      unwinds, and no event loop drains them here.
    void aDragReportedBeforeMelosOwnMovesDrainIsNotLost() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        // No qWait: placeInitial's own change notifications are still queued.
        report(&wc, cap("main"), 0, 0);        // arm
        report(&wc, cap("main"), 500, 300);    // and the user drags, right now
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
    }

    // 10b. Each pass must rewrite every window's `lastPos`, or the next drag's
    //      delta is measured from two drags ago. Needs two drags of the same
    //      window.
    void aSecondDragMovesTheGroupByTheSecondDeltaOnly() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        report(&wc, cap("main"), 500, 300);
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));

        report(&wc, cap("main"), 510, 310);       // ten more pixels, not 510 more
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(510, 310 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(510, 310 + kMainH + kEqH));
    }

    // 11. Magnetism, the other half of "snapping": a window released
    //     NEAR its dock position is pulled flush, and one released far from it
    //     is not — and stops being docked, so it no longer follows.
    void aDragEndingNearTheDockSnapsFlushAndOneEndingFarDoesNot() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // Released 3,4 px off the dock: inside the 10px distance, so it snaps.
        report(&wc, cap("eq"), 3, kMainH + 4, 320, kEqH);
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        // Net movement was zero, so nothing docked to eq moved either.
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));

        // Released far away: no magnetism, so melo leaves it exactly where the
        // user dropped it and does not move it at all...
        report(&wc, cap("eq"), 700, 40, 320, kEqH);
        QTRY_COMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(700, 40 + kEqH));
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(700, 40));
        // ...and eq is no longer docked, so the next drag of main leaves it.
        report(&wc, cap("main"), 0, 200);
        QTest::qWait(300);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(700, 40));
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
    }

    // 12. A caption this host does not own moves nothing. The watcher is
    //     installed with this host's captions only, but the signal is the
    //     controller's and carries whatever it is told — including melo's own
    //     main window, which has a caption too.
    void aReportForACaptionTheHostDoesNotOwnChangesNothing() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        for (const QString& c : {QStringLiteral("melo"), QStringLiteral("melo-mini"),
                                 QStringLiteral("melo-plugin-snapper-nosuch"),
                                 QStringLiteral("melo-plugin-other-main"),
                                 QStringLiteral("MELO-PLUGIN-SNAPPER-MAIN"), QString()})
            report(&wc, c, 900, 900);
        QTest::qWait(300);
        QCOMPARE(fx.window(QStringLiteral("main"))->position(), QPoint(0, 0));
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));
    }

    // 13. KWin reports on interactiveMoveResizeFinished, which a resize or a
    //     zero-distance drag also fires. Neither may move the group, nor
    //     replace a real drag waiting on the settle (`movedId_` is one slot).
    void aReportThatRepeatsThePositionIsNotADrag() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // Five reports that say nothing new, on their own: nothing moves.
        for (int i = 0; i < 5; ++i) report(&wc, cap("main"), 0, 0, 320, kMainH + i);
        QTest::qWait(300);
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));

        // ...and one arriving while a real drag is waiting out the settle —
        // eq finishing a RESIZE, same position, taller — does not displace it.
        report(&wc, cap("main"), 500, 300);
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
        // eq finishing a RESIZE at the origin it now holds — same position,
        // taller. Must not undo the drag that just seated the group. (The
        // report carries current frameGeometry; the old origin would be a
        // different window.)
        report(&wc, cap("eq"), 500, 300 + kMainH, 320, kEqH + 7);
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
    }

    // 14. A snapTo CYCLE is rejected by the manifest validator, and this class
    //     survives one anyway. If the walk were recursive or unbounded this
    //     never returns and the ctest TIMEOUT is what reports it.
    void aSnapToCycleTerminates() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc, /*cyclic=*/true),
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        QElapsedTimer t;
        t.start();
        report(&wc, cap("main"), 400, 400);
        QTest::qWait(400);
        QVERIFY2(t.elapsed() < 4000, qPrintable(QStringLiteral("took %1ms").arg(t.elapsed())));
        // ...and it really did the work rather than bailing out early: the
        // group followed the drag, once each, through both links of the chain.
        QCOMPARE(fx.at(QStringLiteral("main")), QPoint(400, 400));
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(400, 400 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(400, 400 + kMainH + kEqH));
    }

    // 16. moveWindow's facade notification is deferred: it runs inside
    //     applySnap's walk over `wins_`, and plugin QML reached from there can
    //     rebuild the provider and destroy this host mid-iteration.
    void aFacadeNotificationNeverFiresInsideTheShellsOwnUpdate() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QSignalSpy spy(fx.facade(QStringLiteral("main")), &MeloUiWindow::changed);
        QVERIFY(spy.isValid());
        spy.clear();

        fx.host->setActive(true, false);
        // The state is already applied...
        QCOMPARE(fx.host->opacityEntries().at(0).toMap()
                     .value(QStringLiteral("opacity")).toDouble(), 1.0);
        // ...and the property is already readable at its new value, but the
        // SIGNAL has not run any plugin code yet.
        QCOMPARE(spy.count(), 0);
        QTRY_VERIFY(spy.count() > 0);
    }

    // 16b. A `changed()` handler that destroys the host (a plugin switching
    //      provider from a binding): the second queued delivery must find the
    //      host gone instead of walking a freed `wins_`. Freed memory stays
    //      readable, so only a sanitizer detects a missing QPointer guard:
    //
    //        cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug
    //              -DCMAKE_CXX_FLAGS="-fsanitize=address -g"
    //              -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"
    //
    //      Without ASan the assertions only check that the second handler does
    //      not run.
    void destroyingTheHostFromANotificationHandlerIsSurvivable() {
        WindowController wc;
        auto fx = std::make_unique<PluginFixture>();
        QVERIFY2(fx->build(&wc), qPrintable(fx->host ? fx->host->errorString()
                                                     : QStringLiteral("fixture setup failed")));
        // Two windows are notified in one batch; the FIRST one takes the host
        // down. Ownership is released so the handler's delete is the only one.
        PluginWindowHost* host = fx->host.release();
        int handled = 0;
        for (const QString& id : { QStringLiteral("main"), QStringLiteral("eq") })
            connect(fx->facade(id), &MeloUiWindow::changed, this, [&handled, &host] {
                if (++handled > 1) return;
                delete host;
                host = nullptr;
            });
        host->setActive(true, false);          // queues a notification per window
        QTRY_COMPARE(handled, 1);
        QTest::qWait(50);
        QCOMPARE(handled, 1);                  // the second delivery found it gone
        QVERIFY(host == nullptr);
        fx->ui.reset();
        fx->bridge.reset();
    }

    // 17. A shade toggle changes height, not position, so applySnap's delta
    //     walk does nothing and the 60px gap is beyond the 10px magnet; this
    //     re-seat is what makes snapTo apply to shade (docs/plugins.md).
    void shadingAWindowReSeatsTheGroupDockedBelowIt() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));

        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kShadeH);
        // Flush against the NEW bottom edge, and the chain below it follows.
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kShadeH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kShadeH + kEqH));

        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kMainH);
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH + kEqH));

        // ...and the group still drags as a unit from the re-seated positions:
        // the reflow left every lastPos where the window now is.
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("main"), 200, 300);
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(200, 300 + kMainH));
    }

    // 17b. A window docked to the SIDE must not be dragged downwards when its
    //      target shades. This is why the dock EDGE is recorded rather than a
    //      bare "docked" bool: under a drag every edge behaves the same.
    void aSideDockedWindowIsNotMovedByAShade() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // Re-dock eq on main's RIGHT edge by dropping it within snap distance
        // of that candidate: main is 320 wide at 0,0, so (320,0) is flush.
        report(&wc, cap("eq"), 316, 3, 320, kEqH);
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(320, 0));

        const QPoint plBefore = fx.window(QStringLiteral("pl"))->position();
        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kShadeH);
        // Flush on the right edge is the SAME point after the shade: the
        // target's width did not change, so eq must not move at all.
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(320, 0));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), plBefore);
    }

    // ------------------------------------------------------- show/hide reflow
    //
    // 17c-f. Showing or hiding a window changes the chain's extents, so the
    //        window below must move, like the shade gap. The skin's default
    //        layout hits it: main <- eq(initial: hidden) <- playlist, on the
    //        first click of PL.

    // 17c. Nothing is toggled: a window declared hidden spends no height, so
    //      the one below opens flush against the last visible window. Only
    //      placeInitial can do this; no show or hide exists to reflow from.
    void aWindowDeclaredHiddenSpendsNoHeightInTheChain() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc, /*cyclic=*/false, /*spectrum=*/nullptr, /*offGridPl=*/false,
                          /*zeroMins=*/false, {QStringLiteral("eq")}),
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        QCOMPARE(fx.facade(QStringLiteral("eq"))->visible(), false);
        // eq is still SOMEWHERE — it is a real window and a later show has to
        // put it back — and where it is, is flush under main.
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));
        // ...and pl sits on top of it, not below it.
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH));
    }

    // 17d. The toggle half, both ways. placeInitial cannot help here: the group
    //      opened correct and a later hide/show has to keep it so.
    void hidingAndShowingAWindowReSeatsTheGroupDockedBelowIt() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));

        fx.facade(QStringLiteral("eq"))->hide();
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));   // unmoved
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));   // collapsed onto it
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(), QPoint(0, kMainH));

        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));

        // The default order: everything hidden, then the user clicks PL first
        // and EQ second. The playlist must open against MAIN, and the equaliser
        // must then push it down rather than appear on top of it.
        fx.facade(QStringLiteral("eq"))->hide();
        fx.facade(QStringLiteral("pl"))->hide();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));
        fx.facade(QStringLiteral("pl"))->show();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));
        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));

        // ...and the group still drags as a unit from the re-seated positions:
        // the reflow left every lastPos where the window now is. Same tail as
        // the shade row, because the same bookkeeping is what could break.
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("main"), 200, 300);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(200, 300 + kMainH + kEqH));
    }

    // 17e. A window docked to the side collapses sideways, not downwards. The
    //      extent a hidden window stops spending is its own, on whichever axis
    //      the docked window is using — the same reason the dock EDGE is
    //      recorded rather than a bare bool.
    void aSideDockedWindowCollapsesOntoAHiddenTarget() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // Re-dock pl on eq's RIGHT edge: eq is 320 wide at (0,kMainH), so
        // (320,kMainH) is the flush candidate.
        report(&wc, cap("pl"), 316, kMainH + 3, 320, kPlH);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(320, kMainH));

        fx.facade(QStringLiteral("eq"))->hide();
        // Zero WIDTH, so pl comes to eq's left edge and does not move in y.
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));
        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(320, kMainH));
    }

    // 17f. setPluginWindowShown reflows from the toggled window's snapTo
    //      target, because the toggled window can itself move. Only above and
    //      left show it: dockPoint reads the docked window's own height there
    //      (`t.y() - size.height()`), so its flush position changes when shown.
    void aWindowDockedAboveItsTargetMovesForItsOwnVisibility() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // Re-dock pl ABOVE eq: eq sits at (0,kMainH), so a 60px pl is flush at
        // (0, kMainH - kPlH).
        report(&wc, cap("pl"), 3, kMainH - kPlH + 3, 320, kPlH);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH - kPlH));

        // Hidden, it spends nothing: its flush position is eq's top edge, and
        // anything docked above IT would come down by the same 60px.
        fx.facade(QStringLiteral("pl"))->hide();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH));
        // ...and shown again it is back where a 60px window flush above eq
        // goes. A reflow rooted at pl walks past pl and leaves it on eq's edge.
        fx.facade(QStringLiteral("pl"))->show();
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH - kPlH));
    }

    // 17g. Silencing the host (applyState gates on `active_ && wanted`) is not
    //      a chain change, or the group would re-stack on the way out and stay
    //      stacked on return. dockSize reads `wanted` alone.
    void leavingMiniModeDoesNotCollapseTheChain() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        fx.host->setActive(true, false);
        const QPoint eqAt = fx.at(QStringLiteral("eq")), plAt = fx.at(QStringLiteral("pl"));
        QCOMPARE(plAt, QPoint(0, kMainH + kEqH));

        fx.host->setActive(false, false);
        // Nothing to reflow: the layout is the same on both sides of the
        // silence, so a shade or a drag afterwards starts from where it was.
        fx.facade(QStringLiteral("main"))->toggleShade();
        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.at(QStringLiteral("eq")), eqAt);
        QCOMPARE(fx.at(QStringLiteral("pl")), plAt);

        fx.host->setActive(true, false);
        QCOMPARE(fx.at(QStringLiteral("eq")), eqAt);
        QCOMPARE(fx.at(QStringLiteral("pl")), plAt);
    }

    // ------------------------------------------------------ the fixture manifest

    // 17h. The sidecar validates the `ui` block in TypeScript and this reads it
    //      with QJsonValue::toInt(), so a fractional width can pass one and
    //      read as 0 in the other. This row and
    //      sidecar/src/plugins/ui-manifest.test.ts read the same file. Only the
    //      `qml` paths are substituted.
    void theShippedManifestIsTheOneTheShellReads() {
        WindowController wc;
        PluginFixture fx;
        QString why;
        QVERIFY2(fx.buildShipped(&wc, &why), qPrintable(why));

        // The declared geometry, as the host actually resized the windows —
        // this is the reading a fractional or out-of-range value destroys.
        QCOMPARE(fx.sizeOf(QStringLiteral("main")), QSize(275, 116));
        QCOMPARE(fx.sizeOf(QStringLiteral("eq")), QSize(275, 116));
        QCOMPARE(fx.sizeOf(QStringLiteral("playlist")), QSize(275, 232));
        // ...and the resize block behind the playlist's grip, likewise read
        // through toInt(). min == max on the horizontal axis is what makes a
        // skin whose artwork cannot tile sideways refuse to be stretched.
        const QWindow* pl = fx.window(QStringLiteral("playlist"));
        QCOMPARE(pl->minimumHeight(), 116);
        QCOMPARE(pl->minimumWidth(), 275);
        // A free axis advertises no maximum: any maximum makes the toplevel
        // size-constrained for the compositor, and the drag deforms.
        // QWINDOWSIZE_MAX is what QWindow treats as unset.
        QCOMPARE(pl->maximumWidth(), (1 << 24) - 1);
        QCOMPARE(pl->maximumHeight(), (1 << 24) - 1);

        // The chain, and its initial state.
        QCOMPARE(fx.facade(QStringLiteral("main"))->visible(), true);
        QCOMPARE(fx.facade(QStringLiteral("eq"))->visible(), false);
        QCOMPARE(fx.facade(QStringLiteral("playlist"))->visible(), false);

        // The manifest chains main <- eq(hidden) <- playlist, so the first
        // click of PL has to open the playlist flush under main, not 116px
        // below it where the hidden equaliser would be.
        QCOMPARE(fx.at(QStringLiteral("playlist")), QPoint(0, 116));
        fx.facade(QStringLiteral("playlist"))->show();
        QCOMPARE(fx.at(QStringLiteral("playlist")), QPoint(0, 116));
        // ...and EQ afterwards takes its 116px back, pushing the playlist down.
        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, 116));
        QCOMPARE(fx.at(QStringLiteral("playlist")), QPoint(0, 232));
        // ...and main's shade height, the last number in the block, is real.
        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), 14);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, 14));
        QCOMPARE(fx.at(QStringLiteral("playlist")), QPoint(0, 14 + 116));
    }

    // ------------------------------------------------------------ group model

    // A connected component of the dock graph is what will become one
    // QWindow, so the component set and the offsets
    // inside it have to be right before any window is built from them.
    void aDockedChainIsOneGroupWithOffsetsInDeclarationOrder() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        const auto groups = fx.host->windowGroups();
        QCOMPARE(groups.size(), 1);
        QCOMPARE(groups[0].ids, (QStringList{"main", "eq", "pl"}));
        QCOMPARE(groups[0].origin, QPoint(0, 0));
        QCOMPARE(groups[0].size, QSize(320, kMainH + kEqH + kPlH));
        QCOMPARE(groups[0].offset.value("main"), QPoint(0, 0));
        QCOMPARE(groups[0].offset.value("eq"), QPoint(0, kMainH));
        QCOMPARE(groups[0].offset.value("pl"), QPoint(0, kMainH + kEqH));
    }

    // Dragging a child away splits the graph: main alone, and the subtree that
    // travelled with it. This is the case that decides how many windows exist.
    void detachingAChildSplitsTheGroupAndKeepsItsOwnSubtree() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);
        report(&wc, cap("eq"), 700, 40);            // eq leaves, pl follows eq
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(700, 40 + kEqH));

        const auto groups = fx.host->windowGroups();
        QCOMPARE(groups.size(), 2);
        QCOMPARE(groups[0].ids, (QStringList{"main"}));
        QCOMPARE(groups[0].size, QSize(320, kMainH));
        QCOMPARE(groups[1].ids, (QStringList{"eq", "pl"}));
        QCOMPARE(groups[1].origin, QPoint(700, 40));
        QCOMPARE(groups[1].size, QSize(320, kEqH + kPlH));
        QCOMPARE(groups[1].offset.value("eq"), QPoint(0, 0));
        QCOMPARE(groups[1].offset.value("pl"), QPoint(0, kEqH));
    }

    // The same rule dockSize already applies, carried into the box: a hidden
    // panel stays a MEMBER — it is still attached and comes back where it
    // belongs — but it must not stretch the window its siblings live in.
    void aHiddenPanelStaysInTheGroupAndSpendsNoExtent() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        fx.facade(QStringLiteral("pl"))->hide();
        QTest::qWait(250);

        const auto groups = fx.host->windowGroups();
        QCOMPARE(groups.size(), 1);
        QVERIFY2(groups[0].ids.contains(QStringLiteral("pl")),
                 "a hidden panel left the group it is still attached to");
        QCOMPARE(groups[0].size, QSize(320, kMainH + kEqH));
    }

    // A docked group is one mapped window. An unmapped toplevel is not a snap
    // candidate, and a snap candidate welded flush to the window being dragged
    // makes the group drag step on the compositor's snap zone.
    void aDockedGroupIsOneMappedWindowSizedToTheBox() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QTest::qWait(250);

        // Expected to fail: applyGroups() exists but is not wired, because
        // more code than Win::size still reads a panel's geometry off its
        // QWindow, and wiring it before that is fixed fails seven other rows
        // here and hangs the suite. The row states the target.
        QEXPECT_FAIL("", "applyGroups() is not wired yet", Abort);

        int mapped = 0;
        for (const QString& id : {QStringLiteral("main"), QStringLiteral("eq"),
                                  QStringLiteral("pl")})
            if (fx.window(id)->isVisible()) ++mapped;
        QCOMPARE(mapped, 1);
        QVERIFY2(fx.window(QStringLiteral("main"))->isVisible(),
                 "the host is the first member in declaration order");
        // The window, deliberately: this row is about the box the group shares,
        // which is the one place window() and sizeOf() are meant to differ.
        QCOMPARE(fx.window(QStringLiteral("main"))->size(),
                 QSize(320, kMainH + kEqH + kPlH));
    }

    // The facades are the plugin's whole view of its own geometry and they
    // are documented as SCREEN coordinates. A group window must not change a
    // single number a skin reads.
    void groupingDoesNotChangeAnyGeometryTheFacadesReport() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QTest::qWait(250);

        struct Expect { const char* id; QPoint at; QSize size; };
        const Expect rows[] = {
            {"main", QPoint(0, 0),                 QSize(320, kMainH)},
            {"eq",   QPoint(0, kMainH),            QSize(320, kEqH)},
            {"pl",   QPoint(0, kMainH + kEqH),     QSize(320, kPlH)},
        };
        for (const Expect& e : rows) {
            MeloUiWindow* f = fx.facade(QString::fromLatin1(e.id));
            QVERIFY2(f, e.id);
            QCOMPARE(QPoint(f->x(), f->y()), e.at);
            QCOMPARE(QSize(f->width(), f->height()), e.size);
        }
    }

    // `docked` is the user's layout: dragging EQ off main frees that subtree,
    // and EQ's playlist follows EQ. Dismiss (hide all) and silence must not
    // re-seat the manifest's snapTo edges and pull the detached panel back.
    void aDetachedSubgroupSurvivesDismissAndSilence() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        report(&wc, cap("main"), 300, 200);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(300, 200 + kMainH + kEqH));
        // The child drag that disconnects the subtree.
        report(&wc, cap("eq"), 700, 40);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(700, 40 + kEqH));
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(700, 40));

        const QPoint mainAt = fx.at(QStringLiteral("main"));
        const QPoint eqAt = fx.at(QStringLiteral("eq"));
        const QPoint plAt = fx.at(QStringLiteral("pl"));

        // 1. The skin's close button, then back.
        fx.host->dismissWindows();
        QTest::qWait(200);
        fx.facade(QStringLiteral("main"))->show();
        fx.facade(QStringLiteral("eq"))->show();
        fx.facade(QStringLiteral("pl"))->show();
        QTest::qWait(300);
        QCOMPARE(fx.at(QStringLiteral("main")), mainAt);
        QCOMPARE(fx.at(QStringLiteral("eq")), eqAt);
        QCOMPARE(fx.at(QStringLiteral("pl")), plAt);

        // 2. Host silence and back, which is the other whole-group transition.
        fx.host->setActive(false, false);
        fx.host->setActive(true, false);
        QTest::qWait(300);
        QCOMPARE(fx.at(QStringLiteral("main")), mainAt);
        QCOMPARE(fx.at(QStringLiteral("eq")), eqAt);
        QCOMPARE(fx.at(QStringLiteral("pl")), plAt);
    }

    void pluginScaleChangesWindowsContentAndDockingAsOneGeometry() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QObject::connect(fx.bridge->appObj(), &MeloUiApp::scaleRequested, fx.host.get(),
                         &PluginWindowHost::setScale);
        fx.bridge->appObj()->setScale(1.25);

        QCOMPARE(fx.sizeOf(QStringLiteral("main")), QSize(400, 100));
        QCOMPARE(fx.sizeOf(QStringLiteral("eq")), QSize(400, 145));
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, 100));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, 245));

        auto* quickMain = qobject_cast<QQuickWindow*>(fx.window(QStringLiteral("main")));
        QVERIFY(quickMain);
        QQuickItem* gate = quickMain->contentItem()->childItems().value(0);
        QVERIFY(gate);
        QQuickItem* pluginRoot = gate->childItems().value(0);
        QVERIFY(pluginRoot);
        QCOMPARE(pluginRoot->scale(), 1.25);
        QCOMPARE(pluginRoot->size(), QSizeF(320, kMainH));

        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, 100);
        report(&wc, cap("pl"), 0, 245);
        QTest::qWait(200);
        report(&wc, cap("eq"), 12, 112);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(0, 100));

        fx.host->setActive(true, false);
        fx.facade(QStringLiteral("main"))->setShape(QVariantList{
            QVariantList{0, 0, 320, 0, 320, kMainH, 0, kMainH}
        });
        QCOMPARE(fx.window(QStringLiteral("main"))->mask(), QRegion(0, 0, 400, 100));

        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), 25);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, 25));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, 170));
    }

    // 17h. Winamp commands are show/hide and do not need compact.
    //      toggleEq is w.eq.show(); that has to paint in the full window.
    //      Compact is a first-party bar; it is not in this fixture, and it
    //      must not be a missing setActive(true) either.
    void shippedWinampWindowsPaintWithoutEnteringCompact() {
        WindowController wc;
        PluginFixture fx;
        QString why;
        QVERIFY2(fx.buildShipped(&wc, &why), qPrintable(why));
        // Do not call setActive: build() is sufficient.
        QCOMPARE(fx.facade(QStringLiteral("main"))->visible(), true);
        QCOMPARE(fx.facade(QStringLiteral("eq"))->visible(), false);
        QCOMPARE(int(fx.host->resizeGrabEdges(QStringLiteral("main"))), 0);
        // main has shade but no resize block — grabs stay 0. Opacity is the
        // paint proof: a silent host reports 0.
        bool mainOn = false;
        for (const QVariant& v : fx.host->opacityEntries()) {
            const QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("title")).toString().endsWith(QStringLiteral("-main")))
                mainOn = m.value(QStringLiteral("opacity")).toDouble() == 1.0;
        }
        QVERIFY2(mainOn, "shipped main window is silent after build — still gated on mini");

        fx.facade(QStringLiteral("eq"))->show();
        QCOMPARE(fx.facade(QStringLiteral("eq"))->visible(), true);
        bool eqOn = false;
        for (const QVariant& v : fx.host->opacityEntries()) {
            const QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("title")).toString().contains(QStringLiteral("-eq")))
                eqOn = m.value(QStringLiteral("opacity")).toDouble() == 1.0;
        }
        QVERIFY(eqOn);
    }

    // 18. Arm-time reports reflect what KWin knew when the script ran, and may
    //     land after melo's deferred placement. Adopting those puts windows on
    //     a different base, and the next drag splits the group by the placement
    //     error.
    void aFirstReportIsNotAdoptedForAWindowMeloHasAlreadyPlaced() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        // build() placed eq and pl. main was already at the base, so melo never
        // told the compositor anything about it — its report IS adopted.
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));

        // The arm-time batch, describing where the compositor had cascaded them
        // BEFORE melo's placement landed.
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 850, 509, 320, kEqH);
        report(&wc, cap("pl"), 850, 537, 320, kPlH);
        QTest::qWait(300);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));            // kept
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));     // kept
        QCOMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(0, kMainH));

        // ...so the first real drag carries the group by the drag's delta and
        // not by the placement error.
        report(&wc, cap("main"), 500, 300);
        QTRY_COMPARE(fx.window(QStringLiteral("eq"))->position(), QPoint(500, 300 + kMainH));
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(500, 300 + kMainH + kEqH));
    }

    // 19. watchWindowGeometry owns one shared installation; called from melo's
    //     QML (`WindowCtl`) with another caption set it uninstalls the plugin
    //     host's watcher silently. Public C++, not Q_INVOKABLE, like
    //     notifyChanged.
    void watchWindowGeometryIsNotReachableFromQml() {
        const QMetaObject* mo = &WindowController::staticMetaObject;
        QCOMPARE(mo->indexOfMethod("watchWindowGeometry(QStringList)"), -1);
        QCOMPARE(mo->indexOfMethod("setPluginWindowGlue(QVariantList)"), -1);
        // ...and the lookup really does find the invokables beside it, so this
        // cannot pass by asking the wrong question.
        QVERIFY(mo->indexOfMethod("reportMainGeometry()") >= 0);
        QVERIFY(mo->indexOfMethod("applyMainPosition(int,int)") >= 0);
        // The script generator is a static member: not a metaobject member at
        // all, so it is unreachable by the same route.
        QCOMPARE(mo->indexOfMethod("windowGeometryScript(QStringList,qint64,QString)"), -1);
        QCOMPARE(mo->indexOfMethod("pluginWindowGlueScript(QVariantList,qint64)"), -1);
    }

    // 15. The atomic swap: the opacity of every window this host owns is asked
    //     for as ONE set, which Main.qml folds into ONE KWin script execution.
    void theOpacitySetIsStillOneBatchForEveryWindow() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        fx.host->setActive(true, false);
        const QVariantList on = fx.host->opacityEntries();
        QCOMPARE(on.size(), 3);
        for (const QVariant& v : on) QCOMPARE(v.toMap().value(QStringLiteral("opacity")).toDouble(), 1.0);
        QStringList titles;
        for (const QVariant& v : on) titles << v.toMap().value(QStringLiteral("title")).toString();
        QCOMPARE(titles, fx.host->windowTitles());

        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("main"), 300, 300);
        QTest::qWait(300);
        // A drag changes positions, never the membership of the opacity batch.
        QCOMPARE(fx.host->opacityEntries().size(), 3);
        fx.host->setActive(false, false);
        const QVariantList off = fx.host->opacityEntries();
        QCOMPARE(off.size(), 3);
        for (const QVariant& v : off) QCOMPARE(v.toMap().value(QStringLiteral("opacity")).toDouble(), 0.0);
    }

    // 15b. Build turns the host on. Compact is not a paint gate. Wanted
    //      windows must paint and take a resize grab without anyone calling
    //      setActive(true) to “enter mini mode”.
    void aHostIsLiveAfterBuildWithoutAMiniToggle() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        const QVariantList ops = fx.host->opacityEntries();
        QCOMPARE(ops.size(), 3);
        for (const QVariant& v : ops)
            QCOMPARE(v.toMap().value(QStringLiteral("opacity")).toDouble(), 1.0);
        QCOMPARE(int(fx.host->resizeGrabEdges(QStringLiteral("eq"))),
                 int(Qt::BottomEdge));
        fx.host->setActive(false, false);
        QCOMPARE(int(fx.host->resizeGrabEdges(QStringLiteral("eq"))), 0);
        for (const QVariant& v : fx.host->opacityEntries())
            QCOMPARE(v.toMap().value(QStringLiteral("opacity")).toDouble(), 0.0);
    }

    // 16. The shell requests the FFT for the plugin (MeloUi.h withholds
    //     SpectrumSource), tied to the silence gate's `active_ && wanted` in
    //     both directions, so windows that paint nothing hold no FFT.
    //     Arbitration itself is tst_spectrumarbiter's.
    void theFftRequestFollowsPluginWindowVisibility() {
        WindowController wc;
        SpectrumSource spectrum;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc, /*cyclic=*/false, &spectrum),
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        // build() turns the host on. Wanted windows can paint, so the FFT is
        // held — compact did not have to ask.
        QCOMPARE(spectrum.owners().size(), 1);
        QVERIFY(spectrum.running());

        fx.host->setActive(false, false);
        QVERIFY2(!spectrum.running(), "silencing the host left the FFT on");
        QVERIFY(spectrum.owners().isEmpty());

        fx.host->setActive(true, false);
        QCOMPARE(spectrum.owners().size(), 1);
        QVERIFY(spectrum.running());
        QVERIFY(!spectrum.owners().contains(QStringLiteral("background")));

        // Hiding every window while the host is still active. Hidden content
        // is gated and paints nothing, so the analysis must be released even
        // though the host is active.
        for (const QString& id : {QStringLiteral("main"), QStringLiteral("eq"),
                                  QStringLiteral("pl")})
            fx.host->setPluginWindowShown(id, false);
        QVERIFY2(!spectrum.running(), "hidden plugin windows pinned the FFT on");

        // One window back = the analyser could be on screen again.
        fx.host->setPluginWindowShown(QStringLiteral("eq"), true);
        QVERIFY(spectrum.running());

        // Each show restates `true` under the host's one key; hiding all three
        // must still release, where a refcount would stay above zero.
        fx.host->setPluginWindowShown(QStringLiteral("main"), true);
        fx.host->setPluginWindowShown(QStringLiteral("pl"), true);
        QCOMPARE(spectrum.owners().size(), 1);
        for (const QString& id : {QStringLiteral("main"), QStringLiteral("eq"),
                                  QStringLiteral("pl")})
            fx.host->setPluginWindowShown(id, false);
        QVERIFY2(!spectrum.running(), "three shows and three hides left a hold — "
                                      "the request is being counted, not keyed");
        fx.host->setPluginWindowShown(QStringLiteral("main"), true);
        QVERIFY(spectrum.running());

        // Silencing the host releases it whatever the per-window state is.
        fx.host->setActive(false, false);
        QVERIFY2(!spectrum.running(), "silencing the host left the FFT on");
        QVERIFY(spectrum.owners().isEmpty());
    }

    // 16b. Owner keys are per host instance: under a shared key,
    //      setActive(false) on a second host would stop the FFT under the first
    //      host's windows. main.cpp holds one host at a time; this keeps that
    //      from mattering.
    void asecondHostCannotReleaseTheFirstHostsKey() {
        WindowController wc;
        SpectrumSource spectrum;

        PluginFixture first;
        QVERIFY2(first.build(&wc, /*cyclic=*/false, &spectrum),
                 qPrintable(first.host ? first.host->errorString()
                                       : QStringLiteral("fixture setup failed")));
        first.host->setActive(true, false);
        QVERIFY(spectrum.running());
        const QStringList held = spectrum.owners();
        QCOMPARE(held.size(), 1);

        // A second host is BUILT while the first is active. build() turns the
        // host on, so it takes its own key — a shared key would still show
        // one owner here.
        PluginFixture second;
        QVERIFY2(second.build(&wc, /*cyclic=*/false, &spectrum),
                 qPrintable(second.host ? second.host->errorString()
                                        : QStringLiteral("fixture setup failed")));
        QVERIFY2(spectrum.running(), "a second host's build() released the first "
                                     "host's hold — the key is shared");
        QCOMPARE(spectrum.owners().size(), 2);

        // ...and silencing it must not take the first's hold with it.
        second.host->setActive(false, false);
        QVERIFY2(spectrum.running(), "the second host's release took the first's too");
        QCOMPARE(spectrum.owners(), held);
        first.host->setActive(false, false);
        QVERIFY(!spectrum.running());
    }

    // 17. Background asks, host asks, background releases: the plugin's
    //     analysis must survive (a last-writer-wins bool fails here). Then the
    //     host is destroyed without setActive(false), as a provider swap does,
    //     and ~PluginWindowHost must release its key.
    void aDestroyedHostReleasesTheFftWithoutDisturbingTheBackground() {
        WindowController wc;
        SpectrumSource spectrum;
        spectrum.request(QStringLiteral("background"), true);   // melo's own vis bg

        auto fx = std::make_unique<PluginFixture>();
        QVERIFY2(fx->build(&wc, /*cyclic=*/false, &spectrum),
                 qPrintable(fx->host ? fx->host->errorString()
                                     : QStringLiteral("fixture setup failed")));
        fx->host->setActive(true, false);
        QCOMPARE(spectrum.owners().size(), 2);
        QVERIFY(spectrum.owners().contains(QStringLiteral("background")));

        // The user switches melo's background away from a vis type. The plugin
        // analyser is still on screen.
        spectrum.request(QStringLiteral("background"), false);
        QVERIFY2(spectrum.running(), "melo's background switched the FFT off under "
                                     "a plugin that still wants it");

        // Provider swapped away (main.cpp resets the host): destruction alone
        // has to release it.
        fx.reset();
        QVERIFY2(!spectrum.running(), "a destroyed host left the FFT running");
        QVERIFY(spectrum.owners().isEmpty());
    }

    // ---------------------------------------------------------------- resize
    //
    // The manifest's `resize` block: these rows hold the host to what the
    // field's table row in the docs says.

private:
    // A ui.windows[] entry, as the host reads one. Written out rather than
    // taken from the fixture so the arithmetic can be driven with numbers no
    // compositor would send.
    static QJsonObject mkDecl(int w, int h, const QString& axes,
                            int stepW, int stepH, int minW, int minH) {
        QJsonObject d{{QStringLiteral("id"), QStringLiteral("x")},
                      {QStringLiteral("width"), w}, {QStringLiteral("height"), h}};
        if (axes.isEmpty()) return d;              // no resize block at all
        QJsonObject r{{QStringLiteral("axes"), axes}};
        if (stepW > 0) r.insert(QStringLiteral("stepW"), stepW);
        if (stepH > 0) r.insert(QStringLiteral("stepH"), stepH);
        if (minW > 0) r.insert(QStringLiteral("minWidth"), minW);
        if (minH > 0) r.insert(QStringLiteral("minHeight"), minH);
        d.insert(QStringLiteral("resize"), r);
        return d;
    }

private slots:

    // 20. The arithmetic, on its own. Every row is a size the compositor can
    //     hand over and the size the manifest permits nearest to it.
    void theResizeBlockIsTheGridAWindowSnapsTo_data() {
        QTest::addColumn<QJsonObject>("decl");
        QTest::addColumn<QSize>("req");
        QTest::addColumn<QSize>("want");

        // The skin's playlist: 275 wide and fixed, 232 tall on a
        // 29-row grid anchored at 116.
        const QJsonObject pl = mkDecl(275, 232, QStringLiteral("v"), 0, 29, 0, 116);
        QTest::newRow("the declared size is already permitted") << pl << QSize(275, 232) << QSize(275, 232);
        QTest::newRow("a step up")     << pl << QSize(275, 261) << QSize(275, 261);
        QTest::newRow("just under a step") << pl << QSize(275, 246) << QSize(275, 232);
        QTest::newRow("just over the midpoint") << pl << QSize(275, 247) << QSize(275, 261);
        QTest::newRow("a whisker over") << pl << QSize(275, 233) << QSize(275, 232);
        QTest::newRow("a whisker under") << pl << QSize(275, 231) << QSize(275, 232);
        // The minimum is a FLOOR and the anchor both: nothing below it, and
        // every permitted height is a whole number of steps above it.
        QTest::newRow("under the minimum") << pl << QSize(275, 100) << QSize(275, 116);
        QTest::newRow("zero")     << pl << QSize(275, 0) << QSize(275, 116);
        QTest::newRow("negative") << pl << QSize(275, -400) << QSize(275, 116);
        // The pinned axis is the declared width, whatever arrived.
        QTest::newRow("a width on a v-only window") << pl << QSize(900, 232) << QSize(275, 232);
        QTest::newRow("a narrower width too") << pl << QSize(10, 232) << QSize(275, 232);

        // No resize block: both axes are the declared size, which is what makes
        // an ordinary plugin window fixed rather than merely unconstrained.
        const QJsonObject fixed = mkDecl(320, 80, QString(), 0, 0, 0, 0);
        QTest::newRow("no resize block") << fixed << QSize(900, 900) << QSize(320, 80);

        // Horizontal only, so the two axes cannot be passing each other's tests.
        const QJsonObject h = mkDecl(320, 80, QStringLiteral("h"), 25, 29, 320, 80);
        QTest::newRow("h: the width steps")  << h << QSize(355, 900) << QSize(345, 80);
        QTest::newRow("h: the height is pinned") << h << QSize(320, 900) << QSize(320, 80);

        // Both, with different steps on each.
        const QJsonObject vh = mkDecl(320, 80, QStringLiteral("vh"), 25, 29, 320, 80);
        QTest::newRow("vh: both move")  << vh << QSize(370, 140) << QSize(370, 138);

        // A free axis with NO step is continuous, and its minimum still holds.
        const QJsonObject nostep = mkDecl(320, 80, QStringLiteral("v"), 0, 0, 0, 100);
        QTest::newRow("no step: any height above the minimum") << nostep << QSize(320, 137) << QSize(320, 137);
        QTest::newRow("no step: the minimum still holds") << nostep << QSize(320, 4) << QSize(320, 100);

        // A minimum that is NOT a multiple of the step. This is the case that
        // says which end the grid is anchored at: anchored at zero, 100 would
        // not be a permitted height at all and the window could never take the
        // one size its manifest says it must.
        const QJsonObject offset = mkDecl(320, 100, QStringLiteral("v"), 0, 29, 0, 100);
        QTest::newRow("the minimum is itself permitted") << offset << QSize(320, 100) << QSize(320, 100);
        QTest::newRow("and the grid runs from it") << offset << QSize(320, 130) << QSize(320, 129);

        // An axes value nothing recognises is not a free axis. The validator
        // admits only v/h/vh; anything past it is a window melo cannot honour.
        QTest::newRow("an axes value the shell does not know")
            << mkDecl(320, 80, QStringLiteral("diagonal"), 25, 29, 0, 0) << QSize(900, 900) << QSize(320, 80);
    }

    void theResizeBlockIsTheGridAWindowSnapsTo() {
        QFETCH(QJsonObject, decl);
        QFETCH(QSize, req);
        QFETCH(QSize, want);
        QCOMPARE(PluginWindowHost::quantiseSize(decl, req), want);
        // ...and it is a FIXED POINT: the corrected size is itself permitted,
        // which is the whole of why correcting inside the resize handler
        // converges instead of ringing between two sizes forever.
        QCOMPARE(PluginWindowHost::quantiseSize(decl, want), want);
    }

    // 20b. `(req - base) + step/2` is int arithmetic and overflows near INT_MAX.
    //      No compositor sends that, but nothing restricts other callers.
    void anAbsurdSizeStaysOnTheGridInsteadOfOverflowing() {
        const QJsonObject pl = mkDecl(275, 232, QStringLiteral("v"), 0, 29, 0, 116);
        for (const int h : {1 << 20, 1 << 30, std::numeric_limits<int>::max()}) {
            const QSize got = PluginWindowHost::quantiseSize(pl, QSize(275, h));
            QVERIFY2(got.height() >= 116, qPrintable(QStringLiteral("h=%1 gave %2")
                                                         .arg(h).arg(got.height())));
            QCOMPARE((got.height() - 116) % 29, 0);
            // ...and one a window can take: QWindow refuses sizes past 2^24-1,
            // and the resize handler would re-ask on every event. The request
            // is bounded first.
            QVERIFY2(got.height() < (1 << 24),
                     qPrintable(QStringLiteral("h=%1 gave %2, which QWindow cannot take")
                                    .arg(h).arg(got.height())));
            QCOMPARE(PluginWindowHost::quantiseSize(pl, got), got);
        }
    }

    // 21. The same arithmetic through a real window. A compositor hands a client
    //     a size by resizing it — Qt has already applied it by the time the
    //     shell hears — so the correction is after the fact, and this is the
    //     path a user's drag of the grip actually takes.
    void aSizeTheCompositorOffersIsCorrectedToTheGrid() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QWindow* eq = fx.window(QStringLiteral("eq"));
        QCOMPARE(eq->height(), kEqH);

        eq->resize(320, kEqH + 20);                       // 136: not on the grid
        QTRY_COMPARE(eq->height(), kEqH + kStepH);        // 145 = 58 + 3*29
        eq->resize(320, kEqH - 21);                       // 95
        QTRY_COMPARE(eq->height(), kEqH - kStepH);        // 87
        // Below the declared minimum, which is a floor and not another step.
        eq->resize(320, 10);
        QTRY_COMPARE(eq->height(), kEqMinH);
        // ...and what the PLUGIN reads back is the corrected size, not the one
        // the compositor offered.
        QTRY_COMPARE(fx.facade(QStringLiteral("eq"))->height(), kEqMinH);
    }

    // 21a. A move is not a resize: size configures that ride along with
    //      startSystemMove (one xdg_toplevel configure carries both) must not
    //      be quantised, during the drag or at Finished. The starting size is
    //      put back exactly; 10f is the fractional-scale case.
    void aSizeConfigureThatRidesAlongWithAMoveNeverChangesTheSize() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("eq"), 0, kMainH);          // adoption, so Finish is a Finish
        fx.host->setActive(true, false);
        fx.facade(QStringLiteral("eq"))->startDrag();

        QWindow* eq = fx.window(QStringLiteral("eq"));
        QCOMPARE(eq->height(), kEqH);
        eq->resize(320, kEqH + 20);                 // 136: not on the grid
        QCoreApplication::processEvents();
        QCOMPARE(eq->height(), kEqH + 20);          // must stay off-grid during the move
        QTest::qWait(300);                          // longer than the reflow timer
        QCOMPARE(eq->height(), kEqH + 20);
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(0, kMainH + kEqH));         // and must not reflow off the old edge

        report(&wc, cap("eq"), 0, kMainH);          // Finished, same origin
        // Back to the size the grab started on, not the grid's 145.
        QTRY_COMPARE(eq->height(), kEqH);
        QTest::qWait(300);
        QCOMPARE(eq->height(), kEqH);
        // ...so nothing below it moved at any point.
        QCOMPARE(fx.window(QStringLiteral("pl"))->position(),
                 QPoint(0, kMainH + kEqH));
    }

    // 21b. The axis the manifest did not free. `axes: "v"` is the whole of what
    //      makes a 275-wide skin safe: its bottom band is two corners that add
    //      up to the window's width with nothing to tile between them, so a
    //      window one pixel wider draws a gap.
    void anAxisTheManifestDidNotFreeIsPutBack() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QWindow* eq = fx.window(QStringLiteral("eq"));
        eq->resize(600, kEqH);
        QTRY_COMPARE(eq->width(), 320);
        QCOMPARE(eq->height(), kEqH);
        // Both at once: the free axis still moves while the pinned one snaps
        // back, or a window could only ever be resized on its own.
        eq->resize(600, kEqH + kStepH);
        QTRY_COMPARE(eq->width(), 320);
        QCOMPARE(eq->height(), kEqH + kStepH);
    }

    // 21c. A window that declared no `resize` is fixed, and says so to the
    //      compositor rather than only correcting afterwards: min == max is
    //      what makes KWin's own resize gestures refuse it in the first place.
    void aWindowWithNoResizeBlockIsFixed() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QWindow* pl = fx.window(QStringLiteral("pl"));
        QCOMPARE(pl->minimumSize(), QSize(320, kPlH));
        QCOMPARE(pl->maximumSize(), QSize(320, kPlH));
        pl->resize(400, 400);
        QTRY_COMPARE(pl->size(), QSize(320, kPlH));

        // ...and a window that DID declare one is open on the free axis and
        // closed on the other, or the check above is passing for every window.
        QWindow* eq = fx.window(QStringLiteral("eq"));
        QCOMPARE(eq->minimumSize(), QSize(320, kEqMinH));
        QCOMPARE(eq->maximumSize().width(), 320);
        QVERIFY(eq->maximumSize().height() > kEqH * 10);
    }

    // 22. A window that grows must push the chain docked below it: applySnap
    //     sees no position delta, and a one-step growth is outside the 10px
    //     magnet.
    void growingAWindowReSeatsTheGroupDockedBelowIt() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));

        // eq grows by two steps. pl is flush against an edge that just moved.
        fx.window(QStringLiteral("eq"))->resize(320, kEqH + 2 * kStepH);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH + 2 * kStepH));
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH));   // it grew downwards

        // ...and shrinking brings it back up, which a re-seat that only ever
        // added would pass while leaving a gap on the way down.
        fx.window(QStringLiteral("eq"))->resize(320, kEqH);
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));

        // Through the chain, not one link: main's children are eq, and eq's are
        // pl. Resizing main has to carry both.
        fx.window(QStringLiteral("main"))->resize(320, kMainH + kStepH);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH + kStepH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kStepH + kEqH));

        // ...and the group still drags as a unit afterwards: the reflow left
        // every lastPos where the window now is.
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("main"), 400, 200);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(400, 200 + kMainH + kStepH));
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(400, 200 + kMainH + kStepH + kEqH));
    }

    // 22b. A window docked to the side is not moved by a height change, which
    //      is the same thing the dock EDGE buys for a shade (17b) reached from
    //      the other direction — and the direction that matters, because a
    //      resize can change the OTHER axis too.
    void aSideDockedWindowIsNotMovedByAResize() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // eq re-docks on main's RIGHT edge: main is 320 wide at 0,0.
        report(&wc, cap("eq"), 316, 3, 320, kEqH);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(320, 0));
        QTest::qWait(200);

        // main grows TALLER. A right-edge dock does not move for that.
        fx.window(QStringLiteral("main"))->resize(320, kMainH + kStepH);
        QTest::qWait(300);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(320, 0));

        // ...but a WIDER main does move it, or "docked on the right" is not
        // being used at all.
        fx.window(QStringLiteral("main"))->resize(320 + kStepW, kMainH + kStepH);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(320 + kStepW, 0));
    }

    // 22c. reflowDocked rewrites every lastPos, which applySnap measures a drag
    //      from, so a reflow first would null a waiting drag's delta. The
    //      resize and settle timers are independent, so this is reachable.
    void aReflowDoesNotSwallowADragWaitingOnItsSettle() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        report(&wc, cap("main"), 0, 0);
        report(&wc, cap("eq"), 0, kMainH);
        report(&wc, cap("pl"), 0, kMainH + kEqH);
        QTest::qWait(200);

        // A resize arms the reflow...
        fx.window(QStringLiteral("eq"))->resize(320, kEqH + kStepH);
        QTest::qWait(60);
        // ...and the user finishes a drag of main 60ms into its 120ms wait, so
        // the reflow's timeout lands between the drag report and the snap pass.
        report(&wc, cap("main"), 500, 300);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(500, 300 + kMainH));
        // ...and the reflow the drag deferred still happens, after it.
        QTRY_COMPARE(fx.at(QStringLiteral("pl")), QPoint(500, 300 + kMainH + kEqH + kStepH));
    }

    // 23. A shade height is not on the resize grid, and `main` declares both.
    //     The flag that exempts it has to be set BEFORE the shade resize, or
    //     the quantiser rounds 20 up to the resize minimum and a resizable
    //     window cannot shade at all. Nothing else in the suite pairs the two.
    void shadingAResizableWindowKeepsTheShadeHeight() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        // Grown first, so the height it comes back to is one the USER chose and
        // not the declared one — a restore that quietly used the manifest's
        // number would pass on an unresized window.
        fx.window(QStringLiteral("main"))->resize(320, kMainH + kStepH);
        QTRY_COMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH + kStepH));

        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kShadeH);
        QTest::qWait(200);
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kShadeH);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kShadeH));
        // And the limits shade with it. A window sitting at 20 while it still
        // advertises a minimum of 80 is one the compositor pushes straight back
        // up to 80 — the resize block's numbers have to stand aside for the
        // shade height, not merely be quantised around.
        QCOMPARE(fx.window(QStringLiteral("main"))->minimumSize(), QSize(320, kShadeH));
        QCOMPARE(fx.window(QStringLiteral("main"))->maximumSize(), QSize(320, kShadeH));

        fx.facade(QStringLiteral("main"))->toggleShade();
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kMainH + kStepH);
        QCOMPARE(fx.at(QStringLiteral("eq")), QPoint(0, kMainH + kStepH));
        // ...and back: the window is resizable again, from its own minimum.
        QCOMPARE(fx.window(QStringLiteral("main"))->minimumSize(), QSize(320, kMainH));
        QVERIFY(fx.window(QStringLiteral("main"))->maximumSize().height() > kMainH * 10);
    }

    // 24. A manifest that declares a size its own `resize` block forbids. The
    //     window would otherwise open off the grid — a part tile down each side
    //     of a tiled skin — and JUMP at the user's first drag of the grip.
    void aDeclaredSizeOffItsOwnGridOpensOnTheGrid() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc, /*cyclic=*/false, /*spectrum=*/nullptr, /*offGridPl=*/true),
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        // 60 is not 58 + k*29; 58 is.
        QCOMPARE(fx.sizeOf(QStringLiteral("pl")).height(), kEqMinH);
        // ...and it was placed from the corrected size, docked under eq.
        QCOMPARE(fx.at(QStringLiteral("pl")), QPoint(0, kMainH + kEqH));
        // The windows whose declared size IS permitted are untouched, or this
        // could be passing by correcting everything.
        QCOMPARE(fx.sizeOf(QStringLiteral("main")).height(), kMainH);
        QCOMPARE(fx.sizeOf(QStringLiteral("eq")).height(), kEqH);
    }

    // 24b. Grabbable edges are a pure function of the manifest's axes, so the
    //      compositor never offers a v-only window's right edge, which would
    //      rubber-band as the quantiser snapped the width back.
    void theGrabbableEdgesAreTheAxesTheManifestFreed_data() {
        QTest::addColumn<QJsonObject>("decl");
        QTest::addColumn<int>("edges");
        QTest::newRow("v")  << mkDecl(275, 232, QStringLiteral("v"), 0, 29, 0, 116)
                            << int(Qt::BottomEdge);
        QTest::newRow("h")  << mkDecl(320, 80, QStringLiteral("h"), 25, 0, 320, 0)
                            << int(Qt::RightEdge);
        QTest::newRow("vh") << mkDecl(320, 80, QStringLiteral("vh"), 25, 29, 0, 0)
                            << int(Qt::BottomEdge | Qt::RightEdge);
        // Nothing to grab. Both of these reach a plugin's own window.
        QTest::newRow("no resize block")
            << mkDecl(320, 80, QString(), 0, 0, 0, 0) << 0;
        QTest::newRow("an axes value the shell does not know")
            << mkDecl(320, 80, QStringLiteral("diagonal"), 25, 29, 0, 0) << 0;
    }

    void theGrabbableEdgesAreTheAxesTheManifestFreed() {
        QFETCH(QJsonObject, decl);
        QFETCH(int, edges);
        QCOMPARE(int(PluginWindowHost::resizeEdges(decl)), edges);
        // NEVER the top or the left, whatever was declared: a window grows away
        // from its top-left corner, which is the corner the docked chain is
        // seated from.
        QVERIFY(!(PluginWindowHost::resizeEdges(decl) & (Qt::TopEdge | Qt::LeftEdge)));
    }

    // 24c. The gates on a grab. Everything past resizeGrabEdges needs a real
    //      pointer (startSystemResize takes a grab), so this is the whole of
    //      what a suite can reach.
    void aGrabIsRefusedForAWindowThatCannotBeResizedNow() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        const QString main = QStringLiteral("main"), eq = QStringLiteral("eq"),
                      pl = QStringLiteral("pl");
        // 1. A silenced host. setActive(false) is teardown/tests, not compact.
        //    After build the host is live, so this call is what makes a grab
        //    resize something nobody can see.
        fx.host->setActive(false, false);
        QCOMPARE(int(fx.host->resizeGrabEdges(main)), 0);
        QCOMPARE(int(fx.host->resizeGrabEdges(eq)), 0);

        fx.host->setActive(true, false);
        QCOMPARE(int(fx.host->resizeGrabEdges(main)), int(Qt::BottomEdge | Qt::RightEdge));
        QCOMPARE(int(fx.host->resizeGrabEdges(eq)), int(Qt::BottomEdge));   // v only
        // 2. A window that declared no `resize`: nothing to grab, ever.
        QCOMPARE(int(fx.host->resizeGrabEdges(pl)), 0);

        // 3. Hidden, while the host is still active — same reason as (1).
        fx.host->setPluginWindowShown(eq, false);
        QCOMPARE(int(fx.host->resizeGrabEdges(eq)), 0);
        fx.host->setPluginWindowShown(eq, true);
        QCOMPARE(int(fx.host->resizeGrabEdges(eq)), int(Qt::BottomEdge));

        // 4. Shaded. The window is at its shade height, which is not a size the
        //    resize block permits, so a grab would produce one the next
        //    quantise pass throws away.
        fx.facade(main)->toggleShade();
        QCOMPARE(int(fx.host->resizeGrabEdges(main)), 0);
        fx.facade(main)->toggleShade();
        QCOMPARE(int(fx.host->resizeGrabEdges(main)), int(Qt::BottomEdge | Qt::RightEdge));

        // ...and an id this host does not own is not a grab either.
        QCOMPARE(int(fx.host->resizeGrabEdges(QStringLiteral("nosuch"))), 0);
    }

    // 24d. The compositor is told the numbers the quantiser enforces. Two
    //      readings of one manifest field is the compositor offering a size the
    //      client then snaps back — a fight, per frame, over a window the user
    //      is dragging. Checked at both ends of what is advertised.
    void theAdvertisedLimitsAreTheLimitsTheQuantiserEnforces() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc), qPrintable(fx.host ? fx.host->errorString()
                                                   : QStringLiteral("fixture setup failed")));
        for (const QString& id : {QStringLiteral("main"), QStringLiteral("eq"),
                                  QStringLiteral("pl")}) {
            QWindow* w = fx.window(id);
            QVERIFY(w);
            const QJsonObject decl = fx.declOf(id);
            const QSize lo = w->minimumSize(), hi = w->maximumSize();
            // The smallest size the compositor may offer is one the quantiser
            // leaves alone...
            QCOMPARE(PluginWindowHost::quantiseSize(decl, lo), lo);
            // ...and so is the largest: a free axis advertises no maximum, so
            // the ceiling is a pinned axis's single size, and an unset axis
            // uses its floor.
            constexpr int kUnset = (1 << 24) - 1;
            const QSize told(hi.width() == kUnset ? lo.width() : hi.width(),
                             hi.height() == kUnset ? lo.height() : hi.height());
            QCOMPARE(PluginWindowHost::quantiseSize(decl, told), told);
            // One pixel under the advertised floor comes back AT it, which is
            // what makes the first line an assertion about the FLOOR rather
            // than about any size that happens to sit on the grid.
            QCOMPARE(PluginWindowHost::quantiseSize(
                         decl, QSize(lo.width() - 1, lo.height() - 1)), lo);
        }
    }

    // 24e. An explicit zero minimum is "no minimum" to both the quantiser and
    //      applySizeLimits: a 1x1 floor lets the compositor shrink the window
    //      to nothing and the client snaps it back each frame. A separate test
    //      because both fixtures register the same captions.
    void aZeroMinimumIsNoMinimumToBothReadings() {
        WindowController wc;
        PluginFixture fx;
        QVERIFY2(fx.build(&wc, /*cyclic=*/false, /*spectrum=*/nullptr,
                          /*offGridPl=*/false, /*zeroMins=*/true),
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        const QJsonObject decl = fx.declOf(QStringLiteral("eq"));
        const QSize lo = fx.window(QStringLiteral("eq"))->minimumSize();
        QCOMPARE(lo, QSize(320, kEqH));                        // the declared size
        QCOMPARE(PluginWindowHost::quantiseSize(decl, lo), lo);
        QCOMPARE(PluginWindowHost::quantiseSize(decl, QSize(1, 1)), lo);
    }

    // 25. The facade has a startResize() gesture handoff and no setter: a
    //     resize(w, h) would be callable from a binding at frame rate, with no
    //     manifest maximum to clamp to (see MeloUiWindow::startResize).
    void theWindowFacadeAsksForAResizeAndNeverNamesOne() {
        const QMetaObject* mo = &MeloUiWindow::staticMetaObject;
        QVERIFY(mo->indexOfMethod("startResize()") >= 0);
        QVERIFY(mo->indexOfMethod("startDrag()") >= 0);       // the lookup works
        for (const char* sig : {"resize(int,int)", "setWidth(int)", "setHeight(int)",
                                "setSize(QSize)", "resize(QSize)"})
            QVERIFY2(mo->indexOfMethod(sig) == -1,
                     qPrintable(QStringLiteral("MeloUiWindow::%1 lets a plugin name a size")
                                    .arg(QLatin1String(sig))));
        // ...and the geometry properties are still read-only, which is the
        // other route to naming one.
        for (const char* name : {"x", "y", "width", "height"}) {
            const int i = mo->indexOfProperty(name);
            QVERIFY(i >= 0);
            QVERIFY2(!mo->property(i).isWritable(),
                     qPrintable(QStringLiteral("MeloUiWindow.%1 is writable")
                                    .arg(QLatin1String(name))));
        }
    }

    // 18. A host given no arbiter never reaches for one. tst_windowshape builds
    //     every one of its hosts that way, so this is the row that says the
    //     null is a supported configuration rather than a latent crash.
    void aHostWithNoArbiterIsInert() {
        WindowController wc;
        SpectrumSource spectrum;
        spectrum.request(QStringLiteral("background"), true);

        PluginFixture fx;
        QVERIFY2(fx.build(&wc),                       // no spectrum handed over
                 qPrintable(fx.host ? fx.host->errorString()
                                    : QStringLiteral("fixture setup failed")));
        fx.host->setActive(true, false);
        fx.host->setPluginWindowShown(QStringLiteral("main"), false);
        fx.host->setActive(false, false);
        // Untouched throughout: not one of those calls took or released a key.
        QCOMPARE(spectrum.owners(), QStringList{QStringLiteral("background")});
        QVERIFY(spectrum.running());
        spectrum.request(QStringLiteral("background"), false);
    }
};

int main(int argc, char** argv) {
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    TstWindowSnap tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "tst_windowsnap.moc"
