#include <QtTest>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>

// Which browser stores melo reads, and when: none at start or when setup
// opens, every installed one once an account menu opens. A read of a Chromium
// store can raise a keyring prompt, so a first run with defaults reads none.

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
    Q_INVOKABLE QVariant uiGet(const QString&, const QVariant& fallback = {}) const { return fallback; }
    Q_INVOKABLE void uiSet(const QString&, const QVariant&) {}
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

// Answers the account calls at once and records every cookies/status asked.
class FakeSidecar : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
public:
    QQmlEngine* engine = nullptr;
    QStringList statusAsked;   // "browser:<id>" or "guest:<profile>"
    QStringList freshAsked;    // the asks that re-read the browser's store
    bool ready() const { return true; }
    Q_INVOKABLE void rpc(const QString& method, const QVariantMap& params, QJSValue cb) {
        QVariantMap result;
        if (method == "cookies/browsers") result["browsers"] = QStringList{"firefox", "chrome"};
        else if (method == "cookies/profiles") result["profiles"] = QStringList{"Default"};
        else if (method == "cookies/status") {
            const bool browser = params.value("source").toString() == "browser";
            statusAsked << (browser ? "browser:" + params.value("browser").toString()
                                    : "guest:" + params.value("profile").toString());
            if (params.value("fresh").toBool()) freshAsked << statusAsked.last();
            result["signedIn"] = false;
        } else if (method == "settings/locales") {
            result["locales"] = QVariantList{}; result["regions"] = QVariantList{};
        }
        if (cb.isCallable())
            cb.call({engine->toScriptValue(QVariantMap{{"ok", true}, {"result", result}})});
    }
    QStringList browsersAsked() const {
        QStringList out;
        for (const QString& s : statusAsked) if (s.startsWith("browser:")) out << s;
        return out;
    }
signals:
    void readyChanged();
};

class TstAccountReads : public QObject {
    Q_OBJECT

    std::unique_ptr<QQmlEngine> engine_;
    FakeSettings settings_;
    FakeSidecar sidecar_;
    FakeThemes themes_;

    QObject* make(const QByteArray& qml) {
        QQmlComponent c(engine_.get());
        c.setData(qml, QUrl::fromLocalFile(QStringLiteral(MELO_SOURCE_DIR "/src/qml/tst_inline.qml")));
        QObject* o = c.create();
        if (!o) qWarning() << c.errors();
        return o;
    }

private slots:
    void init() {
        engine_ = std::make_unique<QQmlEngine>();
        sidecar_.engine = engine_.get();
        sidecar_.statusAsked.clear();
        sidecar_.freshAsked.clear();
        settings_.cookieSource = "guest";
        engine_->rootContext()->setContextProperty("Settings", &settings_);
        engine_->rootContext()->setContextProperty("sidecar", &sidecar_);
        engine_->rootContext()->setContextProperty("ThemeBackend", &themes_);
    }
    void cleanup() { engine_.reset(); }

    void startReadsNoBrowser() {
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \".\"\nQtObject { property var e: AccountStore.entries }"));
        QVERIFY(o);
        QTRY_VERIFY(sidecar_.statusAsked.contains("guest:Default"));
        QCOMPARE(sidecar_.browsersAsked(), QStringList{});
    }

    void browserInUseIsRead() {
        settings_.cookieSource = "browser";
        settings_.browser = "chrome";
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \".\"\nQtObject { property var e: AccountStore.entries }"));
        QVERIFY(o);
        QTRY_VERIFY(sidecar_.browsersAsked().contains("browser:chrome"));
        QVERIFY(!sidecar_.browsersAsked().contains("browser:firefox"));
    }

    void accountMenuReadsEveryBrowser() {
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \".\"\nQtObject { function menu() { AccountStore.refresh(true) } }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "menu");
        QTRY_VERIFY(sidecar_.browsersAsked().contains("browser:firefox"));
        QVERIFY(sidecar_.browsersAsked().contains("browser:chrome"));
    }

    // the window loads against stubs; its look is not under test
    void setupOpensWithoutReadingBrowsers() {
        const QtMessageHandler prev = qInstallMessageHandler([](QtMsgType t, const QMessageLogContext&, const QString& m) {
            if (t != QtWarningMsg) std::fprintf(stderr, "%s\n", qPrintable(m));
        });
        auto restore = qScopeGuard([prev] { qInstallMessageHandler(prev); });
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nOnboardingWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open");
        QTest::qWait(50);
        QVERIFY(sidecar_.statusAsked.contains("guest:Default"));
        QCOMPARE(sidecar_.browsersAsked(), QStringList{});
    }

    // Settings opens without reading a browser; its Account/Profile dropdown reads them all
    void settingsReadsBrowsersOnlyFromTheAccountDropdown() {
        const QtMessageHandler prev = qInstallMessageHandler([](QtMsgType t, const QMessageLogContext&, const QString& m) {
            if (t != QtWarningMsg) std::fprintf(stderr, "%s\n", qPrintable(m));
        });
        auto restore = qScopeGuard([prev] { qInstallMessageHandler(prev); });
        std::unique_ptr<QObject> o(make("import QtQuick\nimport \"components\"\nSettingsWindow { }"));
        QVERIFY(o);
        QMetaObject::invokeMethod(o.get(), "open", Q_ARG(QVariant, QVariant(QStringLiteral("personalization"))));
        QTest::qWait(50);
        QCOMPARE(o->property("tab").toString(), QString("personalization"));
        QVERIFY(sidecar_.statusAsked.contains("guest:Default"));
        QCOMPARE(sidecar_.browsersAsked(), QStringList{});
        QObject* select = o->findChild<QObject*>("accountSelect");
        QVERIFY(select);
        QMetaObject::invokeMethod(select, "clicked");
        QTRY_VERIFY(sidecar_.browsersAsked().contains("browser:firefox"));
        QVERIFY(sidecar_.browsersAsked().contains("browser:chrome"));
    }

    // Browser mode: setup and Settings re-read no
    // store; the browser in use answers from the sidecar's one read
    void browserModeReReadsOnlyFromTheAccountMenu() {
        const QtMessageHandler prev = qInstallMessageHandler([](QtMsgType t, const QMessageLogContext&, const QString& m) {
            if (t != QtWarningMsg) std::fprintf(stderr, "%s\n", qPrintable(m));
        });
        auto restore = qScopeGuard([prev] { qInstallMessageHandler(prev); });
        settings_.cookieSource = "browser";
        settings_.browser = "chrome";
        std::unique_ptr<QObject> setup(make("import QtQuick\nimport \"components\"\nOnboardingWindow { }"));
        std::unique_ptr<QObject> win(make("import QtQuick\nimport \"components\"\nSettingsWindow { }"));
        QVERIFY(setup && win);
        QMetaObject::invokeMethod(setup.get(), "open");
        QMetaObject::invokeMethod(win.get(), "open", Q_ARG(QVariant, QVariant(QStringLiteral("personalization"))));
        QTest::qWait(50);
        QTRY_VERIFY(sidecar_.browsersAsked().contains("browser:chrome"));
        QVERIFY(!sidecar_.browsersAsked().contains("browser:firefox"));
        QCOMPARE(sidecar_.freshAsked, QStringList{});
        QObject* select = win->findChild<QObject*>("accountSelect");
        QVERIFY(select);
        QMetaObject::invokeMethod(select, "clicked");
        QTRY_VERIFY(sidecar_.freshAsked.contains("browser:chrome"));
        QVERIFY(sidecar_.freshAsked.contains("browser:firefox"));
    }
};

QTEST_MAIN(TstAccountReads)
#include "tst_accountreads.moc"
