#include <QtTest>
#include <QJsonObject>
#include <QJsonArray>
#include "ThemeFormat.h"

// The theme format's pure pieces: the role lists, the opacityScale fold the
// built-ins go through, and how a theme's parts are taken and resolved.
class TestThemeFormat : public QObject {
    Q_OBJECT

private slots:
    // A role's opacity is absolute, so opacityScale is multiplied into every
    // non-floating surface role once.
    void opacityScaleFoldsIntoTheMap() {
        const QJsonObject in{{"opacityScale", 0.5},
                             {"opacity", QJsonObject{{"window", 1.0}, {"card", 0.6},
                                                     {"panel", 1.0}, {"text", 1.0}}}};
        const QJsonObject s = ThemeFormat::foldOpacityScale(in);
        const QJsonObject op = s["opacity"].toObject();
        QCOMPARE(op["window"].toDouble(), 0.5);
        QCOMPARE(op["card"].toDouble(), 0.3);
        QCOMPARE(op["panel"].toDouble(), 1.0);   // floating: over content, never scaled
        QCOMPARE(op["text"].toDouble(), 1.0);    // ink is not a surface
        QCOMPARE(s["opacityScale"].toDouble(), 0.5);   // what the master slider shows
    }

    // partsPatch: a part taken comes from the theme, cleared where the theme
    // is silent; a part kept is written down from the current settings.
    void partsTakenComeFromTheThemeAndPartsKeptStay() {
        const QJsonObject theme{{"windowRadius", 12}, {"fontWeight", 500}};
        const QJsonObject current{{"windowRadius", 4}, {"cornerStyle", "rounded"}, {"fontWeight", 400}, {"font", "Inter"}};
        const QJsonObject pp = ThemeFormat::partsPatch(theme, current, {"windowRadius", "cornerStyle"}, {"fontWeight", "font"});
        const QJsonObject patch = pp["patch"].toObject();
        QCOMPARE(patch["windowRadius"].toInt(), 12);         // taken, from the theme
        QVERIFY(!patch.contains("cornerStyle"));              // taken, the theme is silent: cleared
        QCOMPARE(pp["clear"].toArray().size(), 1);
        QCOMPARE(pp["clear"].toArray()[0].toString(), QStringLiteral("cornerStyle"));
        QCOMPARE(patch["fontWeight"].toInt(), 400);          // kept: what is, not the theme's 500
        QCOMPARE(patch["font"].toString(), QStringLiteral("Inter"));
    }
    void takingEveryPartIsTheWholeTheme() {
        const QJsonObject theme{{"a", 1}, {"b", 2}};
        const QJsonObject pp = ThemeFormat::partsPatch(theme, QJsonObject{{"a", 9}, {"c", 3}}, {"a", "b", "c"}, {});
        QCOMPARE(pp["patch"].toObject()["a"].toInt(), 1);
        QCOMPARE(pp["patch"].toObject()["b"].toInt(), 2);
        QCOMPARE(pp["clear"].toArray()[0].toString(), QStringLiteral("c"));
    }
    // A theme has the parts it sets, plus those it points at in another theme.
    void aThemeHasThePartsItSetsOrPointsAt() {
        QMap<QString, QStringList> keys{{"window", {"windowRadius", "cornerStyle"}}, {"type", {"font", "fontWeight"}},
                                        {"background", {"background"}}, {"palette", {}}};
        const QJsonObject rose{{"id", "rose"}, {"palette", QJsonObject{{"accent", "#f08"}}},
                               {"settings", QJsonObject{{"font", "Inter"}}}};
        const QJsonObject mine{{"id", "mine"}, {"palette", QJsonObject{}},
                               {"settings", QJsonObject{{"windowRadius", 12}}},
                               {"parts", QJsonObject{{"type", "rose"}, {"palette", "rose"}, {"background", "rose"}}}};
        auto lookup = [&](const QString& id) { return id == QLatin1String("rose") ? rose : QJsonObject{}; };
        QCOMPARE(ThemeFormat::partsOf(rose, keys, lookup), (QStringList{"palette", "type"}));
        // mine: window of its own, type and palette through rose, background pointed at a part rose lacks
        QCOMPARE(ThemeFormat::partsOf(mine, keys, lookup), (QStringList{"palette", "window", "type"}));
        const QJsonObject rs = ThemeFormat::resolvedSettings(mine, keys, lookup);
        QCOMPARE(rs["windowRadius"].toInt(), 12);
        QCOMPARE(rs["font"].toString(), QStringLiteral("Inter"));
        QCOMPARE(ThemeFormat::resolvedPalette(mine, lookup)["accent"].toString(), QStringLiteral("#f08"));
        // a pointer to a theme that is gone: the part is absent
        const QJsonObject lost{{"id", "lost"}, {"palette", QJsonObject{}}, {"parts", QJsonObject{{"type", "nope"}}}};
        QVERIFY(ThemeFormat::partsOf(lost, keys, lookup).isEmpty());
    }
    void theRoleListIsTheFormats() {
        const QStringList roles = ThemeFormat::surfaceRoles();
        QCOMPARE(roles.size(), 27);
        for (const QString& r : roles) QVERIFY(ThemeFormat::isSurfaceRole(r));
        QVERIFY(!ThemeFormat::isSurfaceRole(QStringLiteral("text")));
        for (const char* f : {"panel", "dialog", "menu", "toast", "tooltip"})
            QVERIFY(ThemeFormat::isFloatingRole(QLatin1String(f)));
        QVERIFY(!ThemeFormat::isFloatingRole(QStringLiteral("card")));
    }
};

QTEST_GUILESS_MAIN(TestThemeFormat)
#include "tst_themeformat.moc"
