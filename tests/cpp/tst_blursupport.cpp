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
};

QTEST_APPLESS_MAIN(TstBlurSupport)
#include "tst_blursupport.moc"
