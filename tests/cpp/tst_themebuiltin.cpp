#include <QtTest>
#include <QColor>
#include <QDir>
#include <cmath>
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

    // The error look (ErrorPanel) reads on every built-in: its words on the
    // dialog face made opaque, its buttons' words on their faces over it, the
    // main button's on the accent, the alert glyph in danger.
    void errorLookReadsOnEveryBuiltIn() {
        const auto colourOf = [](const QVariant& v, const auto& self) -> QColor {
            if (v.typeId() == QMetaType::QString) {
                const QString s = v.toString();
                const int colon = s.lastIndexOf(QLatin1Char(':'));
                return QColor(colon >= 0 ? s.mid(colon + 1) : s);
            }
            const QVariantMap m = v.toMap();
            if (m.contains("layers")) return self(m.value("layers").toList().value(0), self);
            return self(m.value("colour"), self);
        };
        const auto lum = [](const QColor& c) {
            const auto lin = [](double x) { return x <= 0.04045 ? x / 12.92 : std::pow((x + 0.055) / 1.055, 2.4); };
            return lin(c.redF()) * 0.2126 + lin(c.greenF()) * 0.7152 + lin(c.blueF()) * 0.0722;
        };
        const auto contrast = [&](const QColor& a, const QColor& b) {
            const double x = lum(a), y = lum(b);
            return (qMax(x, y) + 0.05) / (qMin(x, y) + 0.05);
        };
        const auto over = [](const QColor& top, const QColor& under) {
            const double a = top.alphaF();
            return QColor::fromRgbF(top.redF() * a + under.redF() * (1 - a), top.greenF() * a + under.greenF() * (1 - a),
                                    top.blueF() * a + under.blueF() * (1 - a));
        };
        int checked = 0;
        for (const QVariant& tv : store_->themes()) {
            const QVariantMap t = tv.toMap();
            if (!t.value("builtIn").toBool()) continue;
            store_->setActive(t.value("id").toString());
            const QVariantMap p = store_->palette();
            const QString name = t.value("name").toString();
            QColor face = colourOf(p.value("dialog"), colourOf); face.setAlphaF(1);
            const QColor text = colourOf(p.value("text"), colourOf);
            const QColor button = over(colourOf(p.value("button"), colourOf), face);
            const QColor accent = over(colourOf(p.value("accent"), colourOf), face);
            // errorui.js inkOn and glyphOn, the rules ErrorPanel draws with
            const QColor white("#ffffff"), dark = QColor::fromRgbF(0.08, 0.08, 0.08);
            const QColor onAccent = contrast(white, accent) >= 4.5 || contrast(white, accent) >= contrast(dark, accent) ? white : dark;
            const QColor danger0 = p.contains("danger") ? colourOf(p.value("danger"), colourOf) : QColor("#e05252");
            QColor danger = danger0;
            const double toward = lum(face) > 0.18 ? 0 : 1;
            for (int i = 1; i <= 10 && contrast(danger, face) < 3; ++i) {
                const double k = i / 10.0;
                danger = QColor::fromRgbF(danger0.redF() + (toward - danger0.redF()) * k,
                                          danger0.greenF() + (toward - danger0.greenF()) * k,
                                          danger0.blueF() + (toward - danger0.blueF()) * k);
            }
            const auto need = [&](const char* what, double v, double min) {
                QVERIFY2(v >= min, qPrintable(QString("%1: %2 %3 < %4").arg(name, what).arg(v, 0, 'f', 2).arg(min)));
            };
            need("text on face", contrast(text, face), 4.5);
            need("text on button", contrast(text, button), 4.5);
            need("main button", contrast(onAccent, accent), 4.5);
            need("alert glyph", contrast(danger, face), 3.0);
            ++checked;
        }
        QVERIFY(checked >= 10);
    }
};

QTEST_MAIN(TestThemeBuiltIn)
#include "tst_themebuiltin.moc"
