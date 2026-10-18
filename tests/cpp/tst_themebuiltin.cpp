#include <QtTest>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include "SettingsStore.h"
#include "SidecarService.h"
#include "ThemeFormat.h"
#include "ThemeStore.h"

// builtIn marks the compiled-in themes and presets only: files in themes/
// never carry it, older files that do load and lose it, and a forged true
// never makes a user theme built in. A real ThemeStore over a temp MELO_CONFIG_DIR.
class TestThemeBuiltIn : public QObject {
    Q_OBJECT

    QTemporaryDir dir_;
    SidecarService* sidecar_ = nullptr;
    SettingsStore* settings_ = nullptr;
    ThemeStore* store_ = nullptr;

    QString themes() const { return dir_.path() + "/themes"; }
    static QJsonObject read(const QString& path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()).object() : QJsonObject{};
    }
    static void write(const QString& path, const QJsonObject& o) {
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(QJsonDocument(o).toJson());
    }
    static QJsonObject theme(const QString& id, const QJsonValue& builtIn) {
        QJsonObject t{{"version", ThemeFormat::kThemeVersion}, {"id", id}, {"name", id},
                      {"palette", QJsonObject{{"window", "#101010"}}}, {"settings", QJsonObject{}}};
        if (!builtIn.isUndefined()) t["builtIn"] = builtIn;
        return t;
    }
    QVariantMap listed(const QString& id) const {
        for (const QVariant& v : store_->themes())
            if (v.toMap().value("id").toString() == id) return v.toMap();
        return {};
    }

private slots:
    void initTestCase() {
        QVERIFY(dir_.isValid());
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        QVERIFY(QDir().mkpath(themes()));
        write(themes() + "/old.json", theme("old", false));
        write(themes() + "/forged.json", theme("forged", true));
        write(themes() + "/plain.json", theme("plain", QJsonValue::Undefined));
        sidecar_ = new SidecarService(this);
        settings_ = new SettingsStore(sidecar_, this);
        store_ = new ThemeStore(settings_, this);
    }

    void olderFilesLoadAndLoseIt() {
        for (const char* id : {"old", "forged", "plain"}) {
            const QVariantMap t = listed(QLatin1String(id));
            QVERIFY2(!t.isEmpty(), id);
            QVERIFY2(!t.value("builtIn").toBool(), id);
            const QJsonObject f = read(themes() + "/" + id + ".json");
            QCOMPARE(f["name"].toString(), QLatin1String(id));
            QVERIFY2(!f.contains("builtIn"), id);
        }
    }

    void aForgedOneIsStillAUserTheme() {
        store_->setActive(QStringLiteral("forged"));
        QVERIFY(!store_->activeBuiltIn());
        store_->deleteTheme(QStringLiteral("forged"));
        QVERIFY(listed(QStringLiteral("forged")).isEmpty());
        QVERIFY(!QFile::exists(themes() + "/forged.json"));
    }

    void saveAsWritesNone() {
        store_->setActive(QStringLiteral("old"));
        const QString id = store_->saveThemeAs(QStringLiteral("Saved"), {});
        QVERIFY(!id.isEmpty());
        const QJsonObject f = read(themes() + "/" + id + ".json");
        QCOMPARE(f["name"].toString(), QStringLiteral("Saved"));
        QVERIFY(!f.contains("builtIn"));
    }

    void exportsCarryNone() {
        QVERIFY(listed(QStringLiteral("dark-default")).value("builtIn").toBool());
        QVERIFY(store_->exportTheme(QStringLiteral("dark-default"), dir_.path() + "/dark-export.json"));
        QVERIFY(!read(dir_.path() + "/dark-export.json").contains("builtIn"));
        // a file from an older melo, with the key, imports as a user theme
        const QString path = dir_.path() + "/old-export.json";
        write(path, theme("exported", true));
        const QString id = store_->importTheme(path);
        QVERIFY(!id.isEmpty());
        QVERIFY(!listed(id).value("builtIn").toBool());
        QVERIFY(!read(themes() + "/" + id + ".json").contains("builtIn"));
    }

    // every built-in exports to a file that imports, system colours and all
    void builtInsRoundTrip() {
        int n = 0;
        for (const QVariant& v : store_->themes()) {
            const QVariantMap t = v.toMap();
            if (!t.value("builtIn").toBool()) continue;
            const QString id = t.value("id").toString();
            const QString path = dir_.path() + "/rt-" + id + ".json";
            QVERIFY2(store_->exportTheme(id, path), qPrintable(id));
            const QString back = store_->importTheme(path);
            QVERIFY2(!back.isEmpty(), qPrintable(id + ": " + store_->lastError()));
            QCOMPARE(read(themes() + "/" + back + ".json")["palette"], read(path)["palette"]);
            ++n;
        }
        QVERIFY(n >= 2);
    }

    void aWrongColourIsStillRefused() {
        const QString path = dir_.path() + "/bad.json";
        for (const char* c : {"nope", "system:", "systemaccent:nope"}) {
            QJsonObject t = theme("bad", QJsonValue::Undefined);
            t["palette"] = QJsonObject{{"window", QLatin1String(c)}};
            write(path, t);
            QVERIFY2(store_->importTheme(path).isEmpty(), c);
        }
    }

    void presetsWriteNone() {
        store_->setActive(QStringLiteral("old"));
        const QString path = dir_.path() + "/palette-export.json";
        QVERIFY(store_->exportCurrent(QStringLiteral("palette"), QStringLiteral("P"), path));
        QJsonObject p = read(path);
        QVERIFY(!p.contains("builtIn"));
        // a preset file from an older melo, with the key, imports the same
        p["builtIn"] = true;
        write(path, p);
        const QString id = store_->importPreset(path);
        QVERIFY(!id.isEmpty());
        QVERIFY(!read(dir_.path() + "/presets/palette/" + id + ".json").contains("builtIn"));
    }
};

QTEST_MAIN(TestThemeBuiltIn)
#include "tst_themebuiltin.moc"
