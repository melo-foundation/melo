#include <QtTest>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QVariantMap>
#include <gst/gst.h>
#include <memory>

#include "AudioEngine.h"
#include "MeloUi.h"
#include "PcmQueue.h"
#include "PlaybackCoordinator.h"
#include "PlayerState.h"
#include "QueueModel.h"
#include "SettingsStore.h"
#include "SidecarService.h"
#include "SuggestionsModel.h"

// Stand-in for SettingsStore's uiGet/uiSet. Settings is NOT the subject here —
// the point of stubbing it is to count writes, because "melo's window must not
// re-persist on a refresh it did not initiate" is an assertion about who calls
// uiSet, and the real store would send that to a sidecar that is not running.
class SettingsSpy : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QVariant uiGet(const QString& key, const QVariant& def) const {
        return store_.value(key, def);
    }
    // QML hands over a QJSValue; unwrap it, or the stored variants compare
    // unequal to themselves and "the preset was not overwritten" is untestable.
    Q_INVOKABLE void uiSet(const QString& key, const QVariant& value) {
        store_.insert(key, value.canConvert<QJSValue>()
                               ? value.value<QJSValue>().toVariant() : value);
        ++writes;
    }
    int writes = 0;
    QVariantMap store_;
};

// Theme reads palette/settings off this and falls back to defaults; EqWindow
// connects to themeChanged. Present so the QML runs the same shape it does in
// the app rather than logging a missing-target warning.
class ThemeBackendStub : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap palette READ palette NOTIFY themeChanged)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY themeChanged)
public:
    QVariantMap palette() const { return {}; }
    QVariantMap settings() const { return {}; }
signals:
    void themeChanged();
};

// EqWindow calls these from applyGlass(); it wants a live compositor otherwise.
class WindowCtlStub : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void setBlurRadius(int) {}
    Q_INVOKABLE void setBlurBehind(QObject*, bool) {}
};

// The write direction of the EQ desync: a plugin moves a band and melo's own
// EQ window must follow. Everything between the plugin and the window is REAL
// here — MeloUiEq, PlaybackCoordinator, AudioEngine and the actual
// src/qml/components/EqWindow.qml file — so this exercises the shipped chain.
class TestEqSync : public QObject {
    Q_OBJECT

    PcmQueue queue_;
    std::unique_ptr<AudioEngine> engine_;
    SidecarService sidecar_;                  // constructed only; never start()ed
    PlayerState state_;
    QueueModel qmodel_;
    SuggestionsModel suggestions_;
    std::unique_ptr<SettingsStore> settings_;
    std::unique_ptr<PlaybackCoordinator> coord_;
    std::unique_ptr<MeloUiEq> pluginEq_;      // what a skin holds as MeloUi.eq

    QQmlEngine qml_;
    SettingsSpy settingsSpy_;
    WindowCtlStub windowCtl_;
    ThemeBackendStub themeBackend_;
    std::unique_ptr<QQmlComponent> comp_;
    QObject* win_ = nullptr;

    QVariantList windowBands() const { return win_->property("bands").toList(); }

private slots:
    void initTestCase() {
        qputenv("MELO_FAKE_SINK", "1");
        gst_init(nullptr, nullptr);

        engine_ = std::make_unique<AudioEngine>(queue_);
        settings_ = std::make_unique<SettingsStore>(&sidecar_);
        coord_ = std::make_unique<PlaybackCoordinator>(engine_.get(), &sidecar_, &state_,
                                                       &qmodel_, &suggestions_, settings_.get());
        pluginEq_ = std::make_unique<MeloUiEq>(coord_.get());

        qml_.rootContext()->setContextProperty("Player", coord_.get());
        qml_.rootContext()->setContextProperty("Settings", &settingsSpy_);
        qml_.rootContext()->setContextProperty("WindowCtl", &windowCtl_);
        qml_.rootContext()->setContextProperty("ThemeBackend", &themeBackend_);

        comp_ = std::make_unique<QQmlComponent>(
            &qml_, QUrl::fromLocalFile(QStringLiteral(MELO_QML_DIR "/components/EqWindow.qml")));
        QVERIFY2(!comp_->isError(), qPrintable(comp_->errorString()));
        win_ = comp_->create();
        QVERIFY2(win_, qPrintable(comp_->errorString()));
    }

    void cleanupTestCase() {
        delete win_;
        pluginEq_.reset();
        coord_.reset();
        settings_.reset();
        engine_.reset();
    }

    // The user picks a preset in melo's EQ window: it persists, and the engine
    // takes the curve. This is the state the next test must not damage.
    void userEditPersistsAndReachesTheEngine() {
        win_->setProperty("eqEnabled", true);
        win_->setProperty("preset", QStringLiteral("bass-boost"));
        win_->setProperty("bands", QVariantList{ 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 });
        QVERIFY(QMetaObject::invokeMethod(win_, "commit"));

        QCOMPARE(settingsSpy_.writes, 1);
        QCOMPARE(engine_->eqBands()[0], 6.0);
        QCOMPARE(engine_->eqBands()[3], 2.0);
        // ...and the window's own commit echoing back must not rename the preset
        QCOMPARE(win_->property("preset").toString(), QStringLiteral("bass-boost"));
    }

    // Drive a band through the plugin surface — MeloUi.eq.setBand, which no
    // part of EqWindow.qml knows about — and melo's window must show it rather
    // than keep drawing bass-boost while the audio is something else. It must
    // ALSO leave the user's saved preset alone.
    void aPluginWriteReachesMelosEqWindowWithoutRepersisting() {
        const int writesBefore = settingsSpy_.writes;
        const QVariant savedBefore = settingsSpy_.store_.value("eqConfig");
        QVERIFY(savedBefore.isValid());

        pluginEq_->setBand(3, -9.0);          // the plugin path, start to finish

        QCOMPARE(engine_->eqBands()[3], -9.0);              // engine took it
        QCOMPARE(windowBands().at(3).toDouble(), -9.0);     // window followed
        QCOMPARE(windowBands().at(0).toDouble(), 6.0);      // rest of the curve intact
        // No longer the preset it was named after, and the window says so.
        QCOMPARE(win_->property("preset").toString(), QStringLiteral("custom"));

        // The user's saved preset is untouched: no write happened at all, and
        // what is on disk is still the bass-boost curve they chose.
        QCOMPARE(settingsSpy_.writes, writesBefore);
        QCOMPARE(settingsSpy_.store_.value("eqConfig"), savedBefore);
        const QVariantList saved = savedBefore.toMap().value("bands").toList();
        QCOMPARE(saved.at(3).toDouble(), 2.0);              // NOT the plugin's -9
    }

    // The read direction through the real facade, which the engine-level test
    // could not reach: a write made in melo's EQ window shows up on MeloUi.eq.
    void melosEqWindowIsVisibleToAPlugin() {
        QVERIFY(QMetaObject::invokeMethod(win_, "setBand", Q_ARG(QVariant, 7),
                                          Q_ARG(QVariant, 4.5)));
        QCOMPARE(pluginEq_->bands().at(7).toDouble(), 4.5);
        // and the preamp, which only the plugin surface can reach
        pluginEq_->setPreamp(-3.0);
        QCOMPARE(pluginEq_->preamp(), -3.0);
        QCOMPARE(coord_->preamp(), -3.0);
    }

    // EQ off means the engine deliberately holds flat while the window keeps
    // drawing the user's curve greyed out. A refresh that ignored that would
    // erase the curve, and the next user edit would persist the erasure.
    void refreshDoesNotFlattenTheCurveWhileTheEqIsOff() {
        win_->setProperty("eqEnabled", false);
        win_->setProperty("bands", QVariantList{ 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 });
        QVERIFY(QMetaObject::invokeMethod(win_, "commit"));   // writes flat to the engine

        for (double db : engine_->eqBands()) QCOMPARE(db, 0.0);
        QCOMPARE(windowBands().at(0).toDouble(), 6.0);        // curve survives

        pluginEq_->setBand(1, 11.0);
        QCOMPARE(windowBands().at(0).toDouble(), 6.0);        // window still ignores it
        // "Off" means melo's window is not applying ITS curve, not that the
        // equalizer is locked: a plugin still reaches the audio here, as
        // docs/plugins.md promises.
        QCOMPARE(engine_->eqBands()[1], 11.0);
    }

    // A hand-edited or legacy-imported eqConfig can hold a band the engine
    // cannot. It reads back CLAMPED, and an exact diff would read that as
    // "someone else moved the curve" and rename the user's saved preset to
    // Custom — a worse outcome than the mismatch it is reacting to.
    void presetSurvivesAnOutOfRangeStoredBand() {
        QVariantMap cfg;
        cfg.insert("bands", QVariantList{ 30, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        cfg.insert("enabled", true);
        cfg.insert("preset", QStringLiteral("rock"));
        settingsSpy_.store_.insert("eqConfig", cfg);
        const int writesBefore = settingsSpy_.writes;

        coord_->applyEqConfig(cfg);                 // what Main.qml does at startup
        QCOMPARE(engine_->eqBands()[0], 12.0);      // the engine clamped it

        QVERIFY(QMetaObject::invokeMethod(win_, "open"));

        QCOMPARE(win_->property("preset").toString(), QStringLiteral("rock"));
        QCOMPARE(settingsSpy_.writes, writesBefore);
    }
};
QTEST_MAIN(TestEqSync)
#include "tst_eqsync.moc"
