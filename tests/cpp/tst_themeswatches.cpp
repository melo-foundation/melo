#include <QtTest>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include "SettingsStore.h"
#include "SidecarService.h"
#include "ThemeFormat.h"
#include "ThemeStore.h"

// ui.themeSwatches overrides a theme's stamped swatches, like paletteOverrides:
// it answers while set, Save writes it union the stamped ones, Discard restores
// the theme's own. A real ThemeStore over a temp MELO_CONFIG_DIR with the
// sidecar never started, so a settings write is the optimistic local apply.
class TestThemeSwatches : public QObject {
    Q_OBJECT

    QTemporaryDir dir_;
    SidecarService* sidecar_ = nullptr;
    SettingsStore* settings_ = nullptr;
    ThemeStore* store_ = nullptr;

    static QVariantMap swatch(const QString& id, const QString& name) {
        return QVariantMap{{"id", id}, {"name", name}, {"entry", QStringLiteral("#123456")}};
    }
    static QStringList idsOf(const QVariantList& l) {
        QStringList out;
        for (const QVariant& v : l) out << v.toMap().value("id").toString();
        return out;
    }
    static QStringList idsOf(const QJsonArray& a) {
        QStringList out;
        for (const QJsonValue& v : a) out << v.toObject().value("id").toString();
        return out;
    }

private slots:
    void initTestCase() {
        QVERIFY(dir_.isValid());
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        QVERIFY(QDir().mkpath(dir_.path() + "/themes"));
        // a user theme that already travels with one swatch
        const QJsonObject t{
            {"version", ThemeFormat::kThemeVersion}, {"id", "t1"}, {"name", "One"},
            {"builtIn", false},
            {"palette", QJsonObject{{"window", "#101010"}, {"card", "#202020"}}},
            {"settings", QJsonObject{}},
            {"swatches", QJsonArray{QJsonObject{{"id", "own1"}, {"name", "own"},
                                                {"entry", "#abcdef"}}}}};
        QFile f(dir_.path() + "/themes/t1.json");
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(QJsonDocument(t).toJson());
        f.close();

        sidecar_ = new SidecarService(this);
        settings_ = new SettingsStore(sidecar_, this);
        store_ = new ThemeStore(settings_, this);
        store_->setActive(QStringLiteral("t1"));
        QCOMPARE(store_->activeId(), QStringLiteral("t1"));
    }

    void theThemesOwnUntilOneIsSet() {
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("own1")});
        QCOMPARE(idsOf(store_->themeSwatches(QStringLiteral("t1"))),
                 QStringList{QStringLiteral("own1")});
    }

    void theOverrideAnswersInstead() {
        store_->setThemeSwatches({swatch("a", "added")});
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("a")});
        // and by id, for the active theme, the same answer
        QCOMPARE(idsOf(store_->themeSwatches(QStringLiteral("t1"))),
                 QStringList{QStringLiteral("a")});
        // an empty override is still an override: the theme's own do not
        // come back through a removal made on purpose
        store_->setThemeSwatches({});
        QCOMPARE(store_->themeSwatches().size(), 0);
        store_->setThemeSwatches({swatch("a", "added")});
    }

    void anotherThemesOwnAreUntouched() {
        // the override is the ACTIVE theme's; a built-in asked by id answers
        // with its own (none)
        QCOMPARE(store_->themeSwatches(QStringLiteral("dark-default")).size(), 0);
    }

    void saveWritesTheUnion() {
        // one on the profile's shelf, stamped onto a role: the other half of
        // what a saved theme travels with
        settings_->uiSet(QStringLiteral("swatches"), QVariantList{swatch("s1", "shelf")});
        store_->setPaletteColor(QStringLiteral("card"),
                                QVariantMap{{"colour", "#334455"}, {"from", "s1"}});
        store_->setThemeSwatches({swatch("a", "added")});

        const QString id = store_->saveThemeAs(QStringLiteral("Saved"), {});
        QVERIFY(!id.isEmpty());
        QFile f(dir_.path() + "/themes/" + id + ".json");
        QVERIFY2(f.open(QIODevice::ReadOnly), "the saved theme was not written");
        const QJsonObject saved = QJsonDocument::fromJson(f.readAll()).object();
        QStringList got = idsOf(saved["swatches"].toArray());
        got.sort();
        QCOMPARE(got, (QStringList{QStringLiteral("a"), QStringLiteral("s1")}));
        // the edited list won: the theme's own is not smuggled back in
        QVERIFY(!got.contains(QStringLiteral("own1")));
    }

    // a section knows whether it is the theme's, and can go back to it
    // without touching the others
    void aPartIsDirtyOnItsOwnAndGoesBackOnItsOwn() {
        store_->setActive(QStringLiteral("t1"));
        store_->discard();
        QVERIFY(!store_->partDirty(QStringLiteral("controls")));
        QVERIFY(!store_->partDirty(QStringLiteral("window")));
        // the theme lacks controls: an edit is measured against the default
        store_->setThemeSetting(QStringLiteral("buttonGap"), 7);
        QVERIFY(store_->partDirty(QStringLiteral("controls")));
        QVERIFY(!store_->partDirty(QStringLiteral("window")));
        store_->setThemeSetting(QStringLiteral("cornerStyle"), QStringLiteral("squared"));
        QVERIFY(store_->partDirty(QStringLiteral("window")));
        store_->discardPart(QStringLiteral("controls"));
        QVERIFY(!store_->partDirty(QStringLiteral("controls")));
        QCOMPARE(store_->settings().value(QStringLiteral("buttonGap")).toInt(), 2);
        QVERIFY2(store_->partDirty(QStringLiteral("window")), "the other part keeps its edit");
        store_->discardPart(QStringLiteral("window"));
        QVERIFY(!store_->partDirty(QStringLiteral("window")));
    }
    void theRolesASectionOwnsAreDirtyOnTheirOwn() {
        store_->setActive(QStringLiteral("t1"));
        store_->discard();
        QCOMPARE(store_->themeEntry(QStringLiteral("card")).toString(), QStringLiteral("#202020"));
        QVERIFY(!store_->themeEntry(QStringLiteral("toast")).isValid());
        store_->setPaletteColor(QStringLiteral("card"), QVariantMap{{"colour", "#445566"}});
        QVERIFY(store_->rolesDirty({QStringLiteral("card")}));
        QVERIFY(!store_->rolesDirty({QStringLiteral("text")}));
        QVERIFY(store_->rolesDirty({QStringLiteral("text")}, true));
        // the theme's own value written back is no edit
        store_->setPaletteColor(QStringLiteral("card"), QStringLiteral("#202020"));
        QVERIFY(!store_->rolesDirty({QStringLiteral("card")}));
        store_->setPaletteColor(QStringLiteral("card"), QVariantMap{{"colour", "#445566"}});
        store_->setPaletteColor(QStringLiteral("text"), QStringLiteral("#ffffff"));
        store_->discardRoles({QStringLiteral("card")});
        QVERIFY(!store_->rolesDirty({QStringLiteral("card")}));
        QVERIFY2(store_->rolesDirty({QStringLiteral("text")}), "the ink keeps its edit");
        QCOMPARE(store_->palette().value(QStringLiteral("card")).toString(), QStringLiteral("#202020"));
        store_->discardRoles({}, true);
        QVERIFY(!store_->dirty());
    }

    // the sidecar can answer an earlier write with a snapshot that still
    // carries the removed key
    void aRemovedOverrideStaysRemovedThroughAStaleReply() {
        store_->setActive(QStringLiteral("t1"));
        store_->discard();
        settings_->uiSet(QStringLiteral("buttonGap"), 7);
        QVERIFY(store_->partDirty(QStringLiteral("controls")));
        store_->discardPart(QStringLiteral("controls"));
        QVERIFY(!settings_->uiHas(QStringLiteral("buttonGap")));
        const QJsonObject stale{{"ui", QJsonObject{{"buttonGap", 7}, {"activeThemeId", "t1"}}}};
        settings_->apply(stale);
        QVERIFY2(!settings_->uiHas(QStringLiteral("buttonGap")), "the stale snapshot brought the override back");
        QVERIFY(!store_->partDirty(QStringLiteral("controls")));
    }

    // saving over the active theme writes the edits into its own file and
    // clears them; a built-in refuses
    void saveActiveWritesTheEditsIntoTheThemesFile() {
        store_->setActive(QStringLiteral("t1"));
        store_->setPaletteColor(QStringLiteral("card"), QVariantMap{{"colour", "#445566"}});
        // the theme's own swatch, re-set as an edit: the later cases read own1
        store_->setThemeSwatches({swatch("own1", "own")});
        QVERIFY(store_->dirty());
        QVERIFY(store_->saveActive());
        QVERIFY(!store_->dirty());
        QCOMPARE(store_->activeId(), QStringLiteral("t1"));
        QFile f(dir_.path() + "/themes/t1.json");
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QJsonObject saved = QJsonDocument::fromJson(f.readAll()).object();
        QCOMPARE(saved["palette"].toObject()["card"].toObject()["colour"].toString(), QStringLiteral("#445566"));
        QCOMPARE(idsOf(saved["swatches"].toArray()), QStringList{QStringLiteral("own1")});
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("own1")});
        QCOMPARE(store_->palette().value("card").toMap().value("colour").toString(), QStringLiteral("#445566"));
        store_->setActive(QStringLiteral("dark-default"));
        store_->setPaletteColor(QStringLiteral("card"), QVariantMap{{"colour", "#445566"}});
        QVERIFY(!store_->saveActive());
        QVERIFY(store_->dirty());
        store_->setActive(QStringLiteral("t1"));
    }

    void discardDropsTheOverride() {
        store_->setActive(QStringLiteral("t1"));
        store_->setThemeSwatches({swatch("b", "gone")});
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("b")});
        store_->discard();
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("own1")});
    }

    void pickingAnotherThemeDropsIt() {
        store_->setActive(QStringLiteral("t1"));
        store_->setThemeSwatches({swatch("c", "gone")});
        store_->setActive(QStringLiteral("dark-default"));
        QCOMPARE(store_->themeSwatches().size(), 0);
        store_->setActive(QStringLiteral("t1"));
        QCOMPARE(idsOf(store_->themeSwatches()), QStringList{QStringLiteral("own1")});
    }
};

QTEST_MAIN(TestThemeSwatches)
#include "tst_themeswatches.moc"
