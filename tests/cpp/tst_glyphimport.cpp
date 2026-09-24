#include <QtTest>
#include <QJsonArray>
#include <QJsonObject>

#include "ThemeFormat.h"

// An SVG is a glyph once it is one square viewBox, one brush and at most nine
// subpaths. The importer folds shapes and translates (a viewBox origin
// included) into path data and refuses the rest by name, shown in the settings
// row.
class TestGlyphImport : public QObject {
    Q_OBJECT

    static QJsonObject run(const char* svg) {
        return ThemeFormat::importGlyphSvg(QByteArray(svg));
    }
    static QStringList pathsOf(const QJsonObject& r) {
        QStringList out;
        for (const QJsonValue& v : r["entry"].toObject()["paths"].toArray()) out << v.toString();
        return out;
    }

private slots:
    // the shape the table is already in: a viewBox, filled paths, no transform
    void aViewBoxAndItsPathsComeBackAsTheEntry() {
        const QJsonObject r = run(R"SVG(<svg viewBox="0 0 24 24">
              <path d="M6 3.5L20 12L6 20.5V3.5Z"/><path d="M2 2H4V4H2Z"/></svg>)SVG");
        QVERIFY2(r["ok"].toBool(), qPrintable(r["error"].toString()));
        const QJsonObject e = r["entry"].toObject();
        QCOMPARE(e["vb"].toDouble(), 24.0);
        QCOMPARE(e["ink"].toDouble(), 24.0);   // ink defaults to the box
        QCOMPARE(e["fill"].toBool(), true);    // no fill="none" anywhere
        QCOMPARE(pathsOf(r), QStringList({"M6 3.5L20 12L6 20.5V3.5Z", "M2 2H4V4H2Z"}));
    }

    // no viewBox, shapes instead of paths, and the stroke brush the root says
    void widthAndHeightStandInAndTheShapesFold() {
        const QJsonObject r = run(R"SVG(<svg width="16px" height="16px"
                fill="none" stroke="currentColor" stroke-width="2.5">
              <rect x="1" y="2" width="4" height="6"/>
              <circle cx="8" cy="8" r="3"/>
              <polyline points="1,1 2,2 3,1"/>
              <line x1="0" y1="0" x2="4" y2="5"/></svg>)SVG");
        QVERIFY2(r["ok"].toBool(), qPrintable(r["error"].toString()));
        const QJsonObject e = r["entry"].toObject();
        QCOMPARE(e["vb"].toDouble(), 16.0);
        QCOMPARE(e["fill"].toBool(), false);
        QCOMPARE(e["sw"].toDouble(), 2.5);
        QCOMPARE(pathsOf(r), QStringList({"M1 2H5V8H1Z",
                                          "M5 8A3 3 0 1 0 11 8A3 3 0 1 0 5 8Z",
                                          "M1 1L2 2L3 1",
                                          "M0 0L4 5"}));
    }

    // a group's translate and a viewBox origin are both a shift of the
    // coordinates; relative commands are already deltas and must not move
    void aTranslateIsFoldedIntoTheCoordinates() {
        const QJsonObject r = run(R"SVG(<svg viewBox="-2 0 24 24">
              <g transform="translate(1, 10)"><path d="M1 1H3l2 2V5Z"/></g></svg>)SVG");
        QVERIFY2(r["ok"].toBool(), qPrintable(r["error"].toString()));
        // x + 1 + 2 (the viewBox min), y + 10; the `l` pair is untouched
        QCOMPARE(pathsOf(r), QStringList({"M 4 11 H 6 l 2 2 V 15 Z"}));
        QCOMPARE(r["entry"].toObject()["vb"].toDouble(), 24.0);
    }

    void whatItCannotFoldItRefusesByName() {
        const QJsonObject rotated = run(R"SVG(<svg viewBox="0 0 24 24">
              <g transform="rotate(45)"><path d="M1 1H3Z"/></g></svg>)SVG");
        QCOMPARE(rotated["ok"].toBool(), false);
        QVERIFY2(rotated["error"].toString().contains(QStringLiteral("rotate(45)")),
                 qPrintable(rotated["error"].toString()));

        const QJsonObject empty = run(R"SVG(<svg viewBox="0 0 24 24"><defs/><title>x</title></svg>)SVG");
        QCOMPARE(empty["ok"].toBool(), false);
        QVERIFY(!empty["error"].toString().isEmpty());

        const QJsonObject boxless = run(R"SVG(<svg><path d="M1 1H3Z"/></svg>)SVG");
        QCOMPARE(boxless["ok"].toBool(), false);

        // Glyph.qml draws nine subpaths, so a tenth would vanish in silence
        QString many = QStringLiteral("<svg viewBox=\"0 0 24 24\">");
        for (int i = 0; i < 10; ++i) many += QStringLiteral("<path d=\"M1 1H3Z\"/>");
        const QJsonObject over = ThemeFormat::importGlyphSvg((many + "</svg>").toUtf8());
        QCOMPARE(over["ok"].toBool(), false);
        QVERIFY2(over["error"].toString().contains(QStringLiteral("9")),
                 qPrintable(over["error"].toString()));
    }
};

QTEST_MAIN(TestGlyphImport)
#include "tst_glyphimport.moc"
