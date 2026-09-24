#include <QtTest>
#include <QQuickWindow>

#include "WindowShapeItem.h"

// The window's shape as geometry: the SVG path reader, the nine-slice
// stretch that keeps a shape's corners their own size on any window, and the
// input region it writes (left alone while the window is click-through).
class TestWindowShape : public QObject {
    Q_OBJECT

    static QVariantMap corners(const char* style, qreal size) {
        QVariantList cs;
        for (int i = 0; i < 4; ++i)
            cs << QVariantMap{{"style", QString::fromLatin1(style)}, {"size", size}};
        return QVariantMap{{"corners", cs}};
    }
    // an item in a window, completed as QML would, at the window's size
    struct Rig {
        QQuickWindow win;
        WindowShapeItem* item;
        Rig(int w, int h, const QVariant& spec) {
            win.resize(w, h);
            item = new WindowShapeItem(win.contentItem());
            item->setSize(QSizeF(w, h));
            item->setSpec(spec);
            // as the QML engine completes a component
            static_cast<QQmlParserStatus*>(item)->classBegin();
            static_cast<QQmlParserStatus*>(item)->componentComplete();
        }
    };

private slots:
    void readsAbsoluteAndRelativeCommands() {
        bool ok = false;
        const QPainterPath p = WindowShapeItem::parseSvgPath(QStringLiteral("M0 0 L10 0 l0 10 H0 z"), &ok);
        QVERIFY(ok);
        QCOMPARE(p.boundingRect(), QRectF(0, 0, 10, 10));
    }
    void readsPackedNumbersAndArcs() {
        bool ok = false;
        // numbers run together, and an arc's flags with no separator
        const QPainterPath p = WindowShapeItem::parseSvgPath(QStringLiteral("M0 5a5 5 0 016-5 4 4 0 0 1 4 5l-.5.5z"), &ok);
        QVERIFY(ok);
        QVERIFY(p.boundingRect().top() < 1.0);
        // the second arc, radius 4 round (6.13, 4.00), bulges to x = 10.13
        QVERIFY2(qAbs(p.boundingRect().right() - 10.13) < 0.05, qPrintable(QString::number(p.boundingRect().right())));
    }
    void refusesWhatDoesNotParse() {
        bool ok = true;
        WindowShapeItem::parseSvgPath(QStringLiteral("M0 0 L10"), &ok);
        QVERIFY(!ok);
    }
    void roundCornersKeepTheirSizeOnAnyWindow() {
        Rig r(400, 200, corners("round", 12));
        const QPainterPath o = r.item->outlineAt(400, 200);
        QVERIFY(o.contains(QPointF(200, 100)));
        QVERIFY(!o.contains(QPointF(1, 1)));
        QVERIFY(!o.contains(QPointF(399, 199)));
        QVERIFY(o.contains(QPointF(12, 1)));   // the corner ends where its radius does
    }
    void aCutCornerIsStraight() {
        Rig r(100, 100, corners("cut", 8));
        const QPainterPath o = r.item->outlineAt(100, 100);
        QVERIFY(!o.contains(QPointF(3, 3)));    // outside the line x + y = 8
        QVERIFY(o.contains(QPointF(5, 5)));
    }
    void aPathStretchesOnlyItsMiddle() {
        // a notch 40..80 along the top, inside the left slice of 85
        const QVariantMap spec{{"path", "M0 0 H40 L50 10 H70 L80 0 H120 V60 H0 Z"},
                               {"box", QVariantList{120, 60}}, {"slice", QVariantList{85, 15, 15, 15}}};
        Rig r(500, 300, spec);
        const QPainterPath o = r.item->outlineAt(500, 300);
        QVERIFY(!o.contains(QPointF(60, 5)));    // the notch, where it was drawn
        QVERIFY(o.contains(QPointF(300, 5)));    // the stretched top edge
        QVERIFY(o.contains(QPointF(495, 295)));
    }
    void theInputRegionIsTheShape() {
        Rig r(200, 100, corners("round", 16));
        const QRegion m = r.win.mask();
        QVERIFY(!m.isEmpty());
        QVERIFY(!m.contains(QPoint(0, 0)));
        QVERIFY(m.contains(QPoint(100, 50)));
        QCOMPARE(r.win.property("meloShape").value<QRegion>(), m);
    }
    void aClickThroughWindowKeepsItsOwnMask() {
        Rig r(200, 100, QVariant());
        const QRegion off(-100, -100, 1, 1);
        r.win.setProperty("meloInputOff", true);
        r.win.setMask(off);
        r.item->setSpec(corners("round", 16));
        QCOMPARE(r.win.mask(), off);
        // ...and the shape is there for when input comes back
        QVERIFY(!r.win.property("meloShape").value<QRegion>().contains(QPoint(0, 0)));
    }
    void aShapeSqueezesIntoAWindowShorterThanItsEdges() {
        // the mini player: 90 tall, where the shape's fixed top and bottom
        // edges are 70 each
        const QVariantMap spec{{"path", "M0 0 H200 V150 L190 160 H20 L10 150 V0 Z"},
                               {"box", QVariantList{200, 160}}, {"slice", QVariantList{70, 70, 70, 70}}};
        Rig r(390, 90, spec);
        const QPainterPath o = r.item->outlineAt(390, 90);
        QVERIFY(o.contains(QPointF(195, 45)));
        QVERIFY2(!o.contains(QPointF(2, 88)), "the bottom left corner is cut");
        QVERIFY2(!o.contains(QPointF(388, 88)), "...and the bottom right one");
        const QRegion m = r.win.mask();
        QVERIFY2(!m.contains(QPoint(2, 88)), "and the input region agrees");
    }
    // The border and the mask share one edge: the distance the border reads
    // is zero on the mask's outline at any window size, including for a shape
    // with a feature in its stretching middle.
    void theBorderReadsTheEdgeTheMaskDraws_data() {
        QTest::addColumn<QString>("path");
        QTest::addColumn<QVariantList>("slice");
        // a wedge bitten out of the left side, in the stretching middle
        QTest::newRow("a wedge in the middle")
            << QStringLiteral("M0 0 H200 V160 H0 V120 L30 80 L0 40 Z") << QVariantList{40, 30, 40, 30};
        // ...and the shipped theme's own, cut at every corner and both sides
        QTest::newRow("Jigsaw")
            << QStringLiteral("M0 40 L40 0 H160 L200 40 V110 L176 134 V150 L190 160 "
                              "H60 a6 6 0 0 0 -12 0 a6 6 0 0 0 -12 0 H24 L0 136 V96 L26 76 L0 56 Z")
            << QVariantList{90, 44, 90, 40};
    }
    void theBorderReadsTheEdgeTheMaskDraws() {
        QFETCH(QString, path);
        QFETCH(QVariantList, slice);
        const QVariantMap spec{{"path", path}, {"box", QVariantList{200, 160}}, {"slice", slice}};
        for (const QSize& size : {QSize(400, 650), QSize(800, 660), QSize(900, 300), QSize(390, 68)}) {
            Rig r(size.width(), size.height(), spec);
            const QPainterPath o = r.item->outlineAt(size.width(), size.height());
            QVERIFY(!o.isEmpty());
            // what the mask fills, the border reads as
            // inside; what it does not, the border reads as outside. Points
            // within a pixel of the edge are nobody's, and skipped.
            int checked = 0, disagreed = 0;
            QString worst;
            for (int gy = 0; gy < 60; ++gy)
                for (int gx = 0; gx < 60; ++gx) {
                    const QPointF at((gx + 0.5) * size.width() / 60.0, (gy + 0.5) * size.height() / 60.0);
                    const qreal d = r.item->distanceAt(at.x(), at.y());
                    if (qAbs(d) < 1.5) continue;
                    ++checked;
                    const bool kept = r.item->maskAt(at.x(), at.y());
                    if (kept == (d > 0)) continue;
                    ++disagreed;
                    if (worst.isEmpty())
                        worst = QStringLiteral("%1x%2: at %3,%4 the mask keeps %5 and the border reads %6")
                                .arg(size.width()).arg(size.height()).arg(at.x()).arg(at.y())
                                .arg(kept ? "it" : "nothing").arg(d);
                }
            QVERIFY(checked > 1000);
            QVERIFY2(disagreed == 0, qPrintable(worst));
        }
    }
    // The grab ring runs along the shape's edge and says which way that edge
    // faces, which tells a drag whether it is a side or a corner.
    void theGrabRingFollowsTheEdge() {
        const QVariantMap spec{{"path", QStringLiteral("M0 40 L40 0 H160 L200 40 V110 L176 134 V150 L190 160 "
                                                       "H60 a6 6 0 0 0 -12 0 a6 6 0 0 0 -12 0 H24 L0 136 V96 L26 76 L0 56 Z")},
                               {"box", QVariantList{200, 160}}, {"slice", QVariantList{90, 44, 90, 40}},
                               {"fit", QStringLiteral("crop")}};
        Rig r(800, 660, spec);
        QObject* ring = r.item->property("edgeRing").value<QObject*>();
        QVERIFY(ring);
        const QPainterPath o = r.item->outlineAt(800, 660);
        int on = 0, off = 0;
        for (int i = 0; i <= 200; ++i) {
            const QPointF at = o.pointAtPercent(i / 200.0);
            const QPointF n = r.item->edgeNormalAt(at.x(), at.y());
            if (n.isNull()) continue;
            // three pixels in from the edge, along its own normal
            const QPointF in = at - n * 3;
            bool got = false;
            QMetaObject::invokeMethod(ring, "contains", Q_RETURN_ARG(bool, got), Q_ARG(QPointF, in));
            if (got) ++on; else ++off;
            // ...and well inside, it is not the ring's business
            const QPointF deep = at - n * 40;
            bool deepGot = true;
            QMetaObject::invokeMethod(ring, "contains", Q_RETURN_ARG(bool, deepGot), Q_ARG(QPointF, deep));
            QVERIFY(!deepGot || r.item->distanceAt(deep.x(), deep.y()) <= r.item->grabRing());
        }
        QVERIFY2(off * 20 < on, qPrintable(QStringLiteral("%1 of %2 points on the edge had no grab").arg(off).arg(on + off)));
        // the sides face the way they should
        QVERIFY(r.item->edgeNormalAt(2, 330).x() < -0.8);       // left
        QVERIFY(r.item->edgeNormalAt(798, 330).x() > 0.8);      // right
        QVERIFY(r.item->edgeNormalAt(400, 658).y() > 0.8);      // foot
    }
    void noShapeIsTheWholeWindow() {
        Rig r(200, 100, corners("square", 0));
        QVERIFY(!r.item->hasShape());
        QVERIFY(r.win.mask().isEmpty());
    }
};

QTEST_MAIN(TestWindowShape)
#include "tst_windowmask.moc"
