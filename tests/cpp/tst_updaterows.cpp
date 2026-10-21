#include <QtTest>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>

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
public:
    bool supported = false;
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
        settings_.ui.clear();
        engine_->rootContext()->setContextProperty("Settings", &settings_);
        engine_->rootContext()->setContextProperty("sidecar", &sidecar_);
        engine_->rootContext()->setContextProperty("ThemeBackend", &themes_);
        engine_->rootContext()->setContextProperty("Updater", &updater_);
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
        if (!appImage) return;
        QVERIFY(o->property("checkUpdates").toBool());   // on unless switched off
        QObject* toggle = nullptr;
        for (QObject* c : row->findChildren<QObject*>())
            if (c->metaObject()->indexOfSignal("toggled(bool)") >= 0) { toggle = c; break; }
        QVERIFY(toggle);
        QMetaObject::invokeMethod(toggle, "toggled", Q_ARG(bool, false));
        QCOMPARE(settings_.ui.value("checkUpdates"), QVariant(false));
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
