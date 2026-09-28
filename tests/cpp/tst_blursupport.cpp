#include <QtTest>
#include "BlurSupport.h"

// Which blur protocol melo speaks, and the region ext is sent, driven by the
// same registry and capability events a compositor would send.
class TstBlurSupport : public QObject {
    Q_OBJECT
private slots:
    void nothingBoundMeansNoBlur() {
        BlurSupport s;
        QCOMPARE(s.path(), BlurSupport::Path::None);
        QVERIFY(!s.blur());
        QVERIFY(!s.contrast());
    }

    // KWin 6.7: the global is there for good, the capability says whether
    // the Blur effect is loaded
    void extFollowsTheCapability() {
        BlurSupport s;
        s.extBound = true;
        QCOMPARE(s.path(), BlurSupport::Path::Ext);
        QVERIFY(!s.blur());
        s.extBlurCap = true;
        QVERIFY(s.blur());
        s.extBlurCap = false;
        QVERIFY(!s.blur());
        QCOMPARE(s.path(), BlurSupport::Path::Ext);
    }

    // KWin 6.6: blur exists while its global does
    void kdeFollowsTheGlobal() {
        BlurSupport s;
        s.kdeBlur = true;
        s.kdeContrast = true;
        QCOMPARE(s.path(), BlurSupport::Path::Kde);
        QVERIFY(s.blur());
        QVERIFY(s.contrast());
        s.kdeBlur = false;
        s.kdeContrast = false;
        QVERIFY(!s.blur());
        QVERIFY(!s.contrast());
    }

    // a compositor offering both gets ext, and no contrast rides along
    void extWinsOverKde() {
        BlurSupport s;
        s.kdeBlur = true;
        s.kdeContrast = true;
        s.extBound = true;
        QCOMPARE(s.path(), BlurSupport::Path::Ext);
        QVERIFY(!s.blur());   // no capability yet
        QVERIFY(!s.contrast());
        s.extBlurCap = true;
        QVERIFY(s.blur());
    }

    // KWin 6.4: contrast was an effect of its own
    void contrastWithoutKdeBlur() {
        BlurSupport s;
        s.kdeContrast = true;
        QVERIFY(!s.blur());
        QVERIFY(s.contrast());
    }

    void changesCompareUnequal() {
        BlurSupport a, b;
        QVERIFY(a == b);
        b.extBlurCap = true;
        QVERIFY(a != b);
    }

    // ext: a null region removes the blur, so "whole window" has to be a
    // real region, and one that still covers the window after any resize
    void wholeWindowIsARealRegionOnExt() {
        const QRegion r = extBlurRegion(QRegion());
        QVERIFY(!r.isEmpty());
        QCOMPARE(r.rectCount(), 1);
        QVERIFY(r.contains(QRect(0, 0, 16384, 16384)));
        const QRect b = r.boundingRect();
        // what goes on the wire is x, y, width, height as int32
        QVERIFY(qint64(b.x()) + b.width() <= std::numeric_limits<int>::max());
        QVERIFY(qint64(b.y()) + b.height() <= std::numeric_limits<int>::max());
    }

    void aShapedRegionIsSentAsIs() {
        QRegion shape(0, 0, 200, 100);
        shape -= QRegion(0, 0, 10, 10);
        QCOMPARE(extBlurRegion(shape), shape);
    }

    // X11: the whole window is a zero-length value
    void x11WholeWindowIsEmpty() {
        QVERIFY(x11BlurCardinals(QRegion(), 1.75).isEmpty());
    }

    void x11RectsAreScaledToDevicePixels() {
        const QList<quint32> c = x11BlurCardinals(QRegion(10, 20, 100, 50), 2.0);
        QCOMPARE(c, (QList<quint32>{20, 40, 200, 100}));
    }

    // 1.75: 3 * 1.75 = 5.25 and 7 * 1.75 = 12.25, so the edges round out to
    // 5 and 13 and two adjacent rects still share a column
    void x11FractionalEdgesRoundOutward() {
        QRegion r(3, 0, 4, 1);
        const QList<quint32> c = x11BlurCardinals(r, 1.75);
        QCOMPARE(c, (QList<quint32>{5, 0, 8, 2}));
        QRegion two(0, 0, 3, 10);
        two += QRegion(3, 10, 3, 10);
        const QList<quint32> d = x11BlurCardinals(two, 1.75);
        QCOMPARE(d.size(), 8);
        QVERIFY(d[0] + d[2] >= d[4]);
    }

    void x11OneQuadPerRect() {
        QRegion shape(0, 0, 200, 100);
        shape -= QRegion(0, 0, 10, 10);
        QCOMPARE(x11BlurCardinals(shape, 1.0).size(), shape.rectCount() * 4);
    }
};

QTEST_APPLESS_MAIN(TstBlurSupport)
#include "tst_blursupport.moc"
