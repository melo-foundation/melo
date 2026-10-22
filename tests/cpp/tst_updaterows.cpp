#include <QtTest>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTcpServer>
#include <QTcpSocket>
#include "AppImageInfo.h"

// Check for updates is offered only where melo can update itself: an AppImage.
// The settings row and the first-run item are hidden for packages and source
// builds, and both store the switch as `checkUpdates`.

class FakeSettings : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString cookieSource MEMBER cookieSource NOTIFY changed)
    Q_PROPERTY(QString cookieProfile MEMBER cookieProfile NOTIFY changed)
    Q_PROPERTY(QString browser MEMBER browser NOTIFY changed)
    Q_PROPERTY(QString streamCookieSource MEMBER streamCookieSource NOTIFY changed)
    Q_PROPERTY(QString metadataAutoEnrich MEMBER metadataAutoEnrich NOTIFY changed)
    Q_PROPERTY(bool tagLastfm MEMBER tagLastfm NOTIFY changed)
    Q_PROPERTY(QString lastfmApiKey MEMBER lastfmApiKey NOTIFY changed)
    Q_PROPERTY(QString dataDir MEMBER dataDir NOTIFY changed)
    Q_PROPERTY(QString homeSource MEMBER homeSource NOTIFY changed)
    Q_PROPERTY(QString language MEMBER language NOTIFY changed)
    Q_PROPERTY(QString region MEMBER region NOTIFY changed)
    Q_PROPERTY(double crossfadeSeconds MEMBER crossfadeSeconds NOTIFY changed)
    Q_PROPERTY(bool discordStatus MEMBER off NOTIFY changed)
    Q_PROPERTY(bool sendPlayback MEMBER on NOTIFY changed)
    Q_PROPERTY(bool silenceSkip MEMBER on NOTIFY changed)
    Q_PROPERTY(bool tagDeezer MEMBER on NOTIFY changed)
    Q_PROPERTY(bool tagMusicBrainz MEMBER on NOTIFY changed)
    Q_PROPERTY(bool tagYoutubeMusic MEMBER on NOTIFY changed)
    Q_PROPERTY(QVariantMap ui MEMBER ui NOTIFY changed)
public:
    QString homeSource = "youtube", language, region;
    double crossfadeSeconds = 0;
    bool on = true, off = false;
    QVariantMap ui;
    QString cookieSource = "guest", cookieProfile = "Default", browser = "firefox";
    QString streamCookieSource = "same", metadataAutoEnrich = "new", lastfmApiKey, dataDir = "/nonexistent";
    bool tagLastfm = false;
    Q_INVOKABLE QVariant uiGet(const QString& k, const QVariant& fallback = {}) const { return ui.value(k, fallback); }
    Q_INVOKABLE void uiSet(const QString& k, const QVariant& v) { ui[k] = v; }
signals:
    void changed();
};

class FakeThemes : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap settings MEMBER settings NOTIFY changed)
public:
    QVariantMap settings;
    Q_INVOKABLE QString matchingPreset(const QString&) const { return {}; }
    Q_INVOKABLE QVariantList presets(const QString&) const { return {}; }
    Q_INVOKABLE void applyPreset(const QString&, const QString&) {}
    Q_INVOKABLE void setThemeSetting(const QString&, const QVariant&) {}
signals:
    void changed();
};

class FakeSidecar : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    QQmlEngine* engine = nullptr;
    bool ready() const { return true; }
    Q_INVOKABLE void rpc(const QString&, const QVariantMap&, QJSValue cb) {
        if (cb.isCallable())
            cb.call({engine->toScriptValue(QVariantMap{{"ok", true}, {"result", QVariantMap{}}})});
    }
signals:
    void readyChanged();
};

class FakeUpdater : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool supported MEMBER supported CONSTANT)
    Q_PROPERTY(QString state MEMBER state NOTIFY changed)
    Q_PROPERTY(QString version MEMBER version NOTIFY changed)
    Q_PROPERTY(bool canUpdate MEMBER canUpdate NOTIFY changed)
    Q_PROPERTY(bool checking MEMBER checking NOTIFY changed)
    Q_PROPERTY(QString checkResult MEMBER checkResult NOTIFY changed)
    Q_PROPERTY(QVariantList notes MEMBER notes NOTIFY changed)
    Q_PROPERTY(qint64 fetched MEMBER fetched NOTIFY changed)
    Q_PROPERTY(qint64 total MEMBER total NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
public:
    qint64 fetched = 0, total = 0;
    QString error;
    Q_INVOKABLE void retry() { asked << "retry"; }
    bool supported = false, canUpdate = true, checking = false;
    QString state, version, checkResult;
    QVariantList notes;
    QStringList asked;
    Q_INVOKABLE void checkNow() { asked << "checkNow"; }
    Q_INVOKABLE void update() { asked << "update"; }
    Q_INVOKABLE void restart() { asked << "restart"; }
    Q_INVOKABLE void skip() { asked << "skip"; }
    Q_INVOKABLE void later() { asked << "later"; }
signals:
    void changed();
};

// counts every connection: a page that loads nothing makes none
class Watch : public QObject {
public:
    QTcpServer tcp;
    int hits = 0;
    Watch() {
        tcp.listen(QHostAddress::LocalHost);
        connect(&tcp, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket* s = tcp.nextPendingConnection()) { ++hits; s->deleteLater(); }
        });
    }
    QString url(const char* path) const { return QStringLiteral("http://127.0.0.1:%1/%2").arg(tcp.serverPort()).arg(path); }
};

class TstUpdateRows : public QObject {
    Q_OBJECT

    std::unique_ptr<QQmlEngine> engine_;
    FakeSettings settings_;
    FakeSidecar sidecar_;
    FakeThemes themes_;
    FakeUpdater updater_;

    QObject* make(const QByteArray& qml) {
        QQmlComponent c(engine_.get());
        c.setData(qml, QUrl::fromLocalFile(QStringLiteral(MELO_SOURCE_DIR "/src/qml/tst_inline.qml")));
        QObject* o = c.create();
        if (!o) qWarning() << c.errors();
        return o;
    }
    void setUp(bool appImage) {
        engine_ = std::make_unique<QQmlEngine>();
        sidecar_.engine = engine_.get();
        updater_.supported = appImage;
        updater_.asked.clear();
        updater_.state.clear();
        updater_.notes.clear();
        settings_.ui.clear();
        engine_->rootContext()->setContextProperty("Settings", &settings_);
        engine_->rootContext()->setContextProperty("sidecar", &sidecar_);
        engine_->rootContext()->setContextProperty("ThemeBackend", &themes_);
        engine_->rootContext()->setContextProperty("Updater", &updater_);
    }
    // by objectName through the item tree: a Repeater's delegates are not QObject children
    static QQuickItem* findItem(QQuickItem* it, const QString& name) {
        if (!it) return nullptr;
        if (it->objectName() == name) return it;
        for (QQuickItem* c : it->childItems())
            if (QQuickItem* f = findItem(c, name)) return f;
        return nullptr;
    }
    static QQuickItem* findIn(QObject* window, const QString& name) {
        auto* w = qobject_cast<QQuickWindow*>(window);
        return w ? findItem(w->contentItem(), name) : nullptr;
    }
    // the item's own visible flag, not its window's
    static bool shown(QObject* item) {
        auto* q = qobject_cast<QQuickItem*>(item);
        return q && q->isVisible();
    }

    QtMessageHandler prev_ = nullptr;

private slots:
    // the windows load against stubs; their look is not under test
    void initTestCase() {
        prev_ = qInstallMessageHandler([](QtMsgType t, const QMessageLogContext&, const QString& m) {
            if (t != QtWarningMsg) std::fprintf(stderr, "%s\n", qPrintable(m));
        });
    }
    void cleanupTestCase() { qInstallMessageHandler(prev_); }
    void cleanup() { engine_.reset(); }

    void settingsRow_data() {
        QTest::addColumn<bool>("appImage");
        QTest::newRow("AppImage") << true;
        QTest::newRow("package") << false;
    }
    void settingsRow() {
        QFETCH(bool, appImage);
        setUp(appImage);
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nSettingsWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open", Q_ARG(QVariant, QVariant(QStringLiteral("general"))));
        QTest::qWait(50);
        QObject* row = o->findChild<QObject*>("checkUpdatesRow");
        QVERIFY(row);
        QCOMPARE(shown(row), appImage);
        QCOMPARE(shown(o->findChild<QObject*>("updatesRow")), appImage);
        if (!appImage) return;
        QVERIFY(o->property("checkUpdates").toBool());   // on unless switched off
        QObject* toggle = nullptr;
        for (QObject* c : row->findChildren<QObject*>())
            if (c->metaObject()->indexOfSignal("toggled(bool)") >= 0) { toggle = c; break; }
        QVERIFY(toggle);
        QMetaObject::invokeMethod(toggle, "toggled", Q_ARG(bool, false));
        QCOMPARE(settings_.ui.value("checkUpdates"), QVariant(false));
        QObject* updates = o->findChild<QObject*>("updatesRow");
        QVERIFY(updates && shown(updates));
        QObject* now = o->findChild<QObject*>("checkUpdatesNow");
        QVERIFY(now);
        QVERIFY(shown(now));
        QCOMPARE(now->property("label").toString(), QString("Check now"));
        QMetaObject::invokeMethod(now, "clicked");
        QCOMPARE(updater_.asked, QStringList { "checkNow" });
        // the Updates row's value is the check's live state, then the offer
        updater_.checking = true; emit updater_.changed();
        QCOMPARE(updates->property("desc").toString(), QString("Checking…"));
        updater_.checking = false; updater_.checkResult = "current"; emit updater_.changed();
        QCOMPARE(updates->property("desc").toString(), QString("Up to date"));
        QObject* notes = o->findChild<QObject*>("updateNotesBtn");
        QObject* restart = o->findChild<QObject*>("updateRestartBtn");
        QVERIFY(notes && restart);
        QVERIFY(!shown(notes) && !shown(restart));
        QSignalSpy wants(o.get(), SIGNAL(updateNotesRequested()));
        updater_.checkResult = "available"; updater_.state = "available"; updater_.version = "Alpha 5";
        updater_.notes << QVariantMap { { "label", "Alpha 5" }, { "date", "2026-11-02" }, { "body", "- a change" } };
        emit updater_.changed();
        QCOMPARE(updates->property("desc").toString(), QString("Alpha 5 available"));
        QVERIFY(shown(notes));
        QMetaObject::invokeMethod(notes, "clicked");
        QCOMPARE(wants.size(), 1);
        updater_.state = "ready"; emit updater_.changed();
        QCOMPARE(updates->property("desc").toString(), QString("Alpha 5 ready"));
        QVERIFY(shown(restart));
        QVERIFY(!shown(now));
        QMetaObject::invokeMethod(restart, "clicked");
        QCOMPARE(updater_.asked.last(), QString("restart"));
    }

    // What's new: a section per release, newest first, and the three answers
    void whatsNew() {
        setUp(true);
        updater_.state = "available";
        updater_.version = "Alpha 5";
        for (const char* l : { "Alpha 5", "Alpha 4.1", "Alpha 4" })
            updater_.notes << QVariantMap { { "label", l }, { "date", "2026-11-02" }, { "body", "- a change" } };
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nUpdateNotesWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open");
        QTest::qWait(50);
        QCOMPARE(o->property("heading").toString(), QString("Update"));
        QStringList heads;
        for (int i = 0; i < 3; ++i) {
            QObject* h = findIn(o.get(), QStringLiteral("notesHeading_%1").arg(i));
            QVERIFY(h);
            heads << h->property("text").toString();
        }
        QCOMPARE(heads, (QStringList { "Alpha 5", "Alpha 4.1", "Alpha 4" }));
        QVERIFY(!findIn(o.get(), "notesHeading_3"));
        QObject* main = findIn(o.get(), "updateMain");
        QVERIFY(main && shown(main));
        QCOMPARE(main->property("label").toString(), QString("Update"));
        QMetaObject::invokeMethod(findIn(o.get(), "updateSkip"), "clicked");
        QCOMPARE(updater_.asked, QStringList { "skip" });
        QVERIFY(!o->property("visible").toBool());
        QMetaObject::invokeMethod(o.get(), "open");
        QMetaObject::invokeMethod(findIn(o.get(), "updateLater"), "clicked");
        QMetaObject::invokeMethod(o.get(), "open");
        QMetaObject::invokeMethod(main, "clicked");
        QCOMPARE(updater_.asked, (QStringList { "skip", "later", "update" }));
        // an unwritable folder: no Update, the rest stay
        updater_.canUpdate = false; emit updater_.changed();
        QVERIFY(!shown(main));
        QVERIFY(shown(findIn(o.get(), "updateSkip")));
    }

    // the window carries the download, Restart and a failure; closing it is Later
    // only while it offers
    void windowCarriesTheUpdate() {
        setUp(true);
        updater_.state = "available";
        updater_.version = "Alpha 5";
        updater_.notes << QVariantMap { { "label", "Alpha 5" }, { "date", "2026-11-02" }, { "body", "- a change" } };
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nUpdateNotesWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open");
        QTest::qWait(50);
        QObject* main = findIn(o.get(), "updateMain");
        QObject* status = findIn(o.get(), "updateStatus");
        QVERIFY(main && status);
        QMetaObject::invokeMethod(main, "clicked");
        QCOMPARE(updater_.asked, QStringList { "update" });
        QVERIFY(o->property("visible").toBool());   // Update keeps it open, for the progress

        updater_.state = "downloading"; updater_.fetched = 1572864; updater_.total = 4194304; emit updater_.changed();
        QCOMPARE(status->property("text").toString(), QString("1.5 / 4.0 MB"));
        QVERIFY(!shown(main));
        QVERIFY(!shown(findIn(o.get(), "updateSkip")));
        QMetaObject::invokeMethod(o.get(), "closeRequested");
        QVERIFY(!o->property("visible").toBool());
        QCOMPARE(updater_.asked, QStringList { "update" });   // closing mid-download is not Later

        QMetaObject::invokeMethod(o.get(), "open");
        updater_.state = "failed"; updater_.error = "The update couldn't be downloaded."; emit updater_.changed();
        QCOMPARE(status->property("text").toString(), updater_.error);
        QCOMPARE(main->property("label").toString(), QString("Try again"));
        QMetaObject::invokeMethod(main, "clicked");
        QCOMPARE(updater_.asked, (QStringList { "update", "retry" }));

        updater_.state = "ready"; emit updater_.changed();
        QCOMPARE(main->property("label").toString(), QString("Restart"));
        QCOMPARE(status->property("text").toString(), QString());
        QMetaObject::invokeMethod(main, "clicked");
        QCOMPARE(updater_.asked.last(), QString("restart"));

        updater_.state = "available"; emit updater_.changed();
        QMetaObject::invokeMethod(o.get(), "open");
        QMetaObject::invokeMethod(o.get(), "closeRequested");
        QCOMPARE(updater_.asked.last(), QString("later"));
    }

    // The notes as the updater hands them over load nothing; the same Markdown
    // unfiltered would fetch its images.
    void notesLoadNoRemoteContent() {
        setUp(true);
        Watch watch;
        const QString raw = QStringLiteral("# Notes\n\n![shot](%1)\n\n<img src=\"%2\">\n")
                                .arg(watch.url("a.png"), watch.url("b.png"));
        auto render = [&](const QString& md) {
            std::unique_ptr<QQuickWindow> w(new QQuickWindow);
            QQmlComponent c(engine_.get());
            c.setData("import QtQuick\nText { textFormat: Text.MarkdownText; width: 300 }", QUrl());
            std::unique_ptr<QQuickItem> t(qobject_cast<QQuickItem*>(c.create()));
            if (!t) return;
            t->setParentItem(w->contentItem());
            t->setProperty("text", md);
            w->resize(320, 240);
            w->show();
            QTest::qWait(400);
        };
        render(appimage::safeMarkdown(raw));
        QCOMPARE(watch.hits, 0);
        render(raw);
        if (watch.hits == 0) QSKIP("this Qt fetches no Markdown images at all; the filtered case passed");
        QVERIFY(watch.hits > 0);
    }

    void onboardingItem_data() { settingsRow_data(); }
    void onboardingItem() {
        QFETCH(bool, appImage);
        setUp(appImage);
        settings_.ui["checkUpdates"] = false;
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nOnboardingWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open");
        QTest::qWait(50);
        QObject* item = o->findChild<QObject*>("obCheckUpdates");
        QVERIFY(item);
        QCOMPARE(shown(item), appImage);
        QCOMPARE(o->property("checkUpdates").toBool(), false);   // the stored choice
    }
};

QTEST_MAIN(TstUpdateRows)
#include "tst_updaterows.moc"
