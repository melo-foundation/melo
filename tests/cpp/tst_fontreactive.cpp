#include <QtTest>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QRegularExpression>

// Text sized through Theme.fs() follows font family and scale; a box sized with
// a literal pixel count does not, so "1:02:33" clips to "1:02". Theme.sp() is
// the literal's replacement. This reads the QML as text and fails on the two
// ways a box stops tracking the type it holds.
class TestFontReactive : public QObject {
    Q_OBJECT

    static QStringList qmlFiles() {
        QStringList out;
        QDirIterator it(QStringLiteral(MELO_SOURCE_DIR) + "/src/qml",
                        QStringList{"*.qml"}, QDir::Files,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) out << it.next();
        return out;
    }
    static QString read(const QString& path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll())
                                           : QString();
    }

private slots:
    // Every Text draws in the chosen family at the chosen size. One that names
    // neither inherits whatever the parent happened to be, which is the system
    // default for anything not nested under other text.
    void everyLabelUsesTheThemeFont() {
        // glyph-only decorations: a caret or a tick is an icon spelled with a
        // character, and has no business changing when the reading font does
        static const QRegularExpression glyph(
            QStringLiteral("text:\\s*\"[^A-Za-z0-9]{0,2}\""));
        QRegularExpression block(
            QStringLiteral("\\b(Text|TextInput|TextEdit)\\s*\\{"));
        QStringList bad;
        for (const QString& path : qmlFiles()) {
            if (path.contains(QStringLiteral("/style/"))) continue;
            const QString src = read(path);
            // a primitive that republishes its label's font (ScrollText, the
            // skeletons) IS the caller's font — it has no opinion of its own
            // to bind, and every caller supplies one
            if (src.contains(QStringLiteral("alias font"))) continue;
            auto it = block.globalMatch(src);
            while (it.hasNext()) {
                const auto m = it.next();
                int depth = 0, i = m.capturedEnd() - 1;
                const int start = i;
                for (; i < src.size(); ++i) {
                    if (src[i] == '{') ++depth;
                    else if (src[i] == '}' && --depth == 0) break;
                }
                const QString body = src.mid(start, i - start);
                if (body.contains(QStringLiteral("family"))) continue;
                // `font: other.font` adopts a font that is itself bound —
                // naming the family again would only be a second copy of it
                if (body.contains(QRegularExpression(
                        QStringLiteral("font\\s*:\\s*[A-Za-z_]"))))
                    continue;
                if (glyph.match(body).hasMatch()) continue;
                if (!body.contains(QStringLiteral("text")) &&
                    !body.contains(QStringLiteral("pixelSize"))) continue;
                bad << QFileInfo(path).fileName() + ": "
                       + body.left(60).simplified();
            }
        }
        QVERIFY2(bad.isEmpty(),
                 qPrintable("labels not bound to Theme.fontFamily:\n  "
                            + bad.join("\n  ")));
    }

    // A glyph size that is not fs() ignores the font-size setting outright.
    void everyGlyphSizeGoesThroughFs() {
        QRegularExpression px(
            QStringLiteral("pixelSize\\s*:\\s*(?!Theme\\.fs\\()([^\\n]*)"));
        QStringList bad;
        for (const QString& path : qmlFiles()) {
            if (path.contains(QStringLiteral("/style/"))) continue;
            const QString src = read(path);
            auto it = px.globalMatch(src);
            while (it.hasNext()) {
                const QString rest = it.next().captured(1).simplified();
                // a size derived from another size is already scaled
                if (rest.contains(QStringLiteral("Theme.fs"))) continue;
                if (rest.contains(QStringLiteral("font.pixelSize"))) continue;
                bad << QFileInfo(path).fileName() + ": pixelSize: " + rest;
            }
        }
        QVERIFY2(bad.isEmpty(),
                 qPrintable("glyph sizes that ignore fontScale:\n  "
                            + bad.join("\n  ")));
    }

    // The boxes: a Text given a literal width elides or overflows the moment
    // the type outgrows it. It must come from Theme.sp(), from implicitWidth,
    // or from something that itself tracks one of those.
    void noLiteralWidthOnALabel() {
        QRegularExpression block(QStringLiteral("\\b(Text|SkeletonValue"
                                                "|SkeletonText|ScrollText)\\s*\\{"));
        QRegularExpression litW(
            QStringLiteral("(?<![A-Za-z.])width\\s*:\\s*(\\d+)\\s*$"));
        QStringList bad;
        for (const QString& path : qmlFiles()) {
            if (path.contains(QStringLiteral("/style/"))) continue;
            const QString src = read(path);
            auto it = block.globalMatch(src);
            while (it.hasNext()) {
                const auto m = it.next();
                int depth = 0, i = m.capturedEnd() - 1;
                const int start = i;
                for (; i < src.size(); ++i) {
                    if (src[i] == '{') ++depth;
                    else if (src[i] == '}' && --depth == 0) break;
                }
                const QString body = src.mid(start, i - start);
                for (const QString& line : body.split('\n')) {
                    const auto w = litW.match(line.trimmed());
                    if (w.hasMatch())
                        bad << QFileInfo(path).fileName() + ": "
                               + m.captured(1) + " width: " + w.captured(1);
                }
            }
        }
        QVERIFY2(bad.isEmpty(),
                 qPrintable("text boxes frozen at one font's metrics:\n  "
                            + bad.join("\n  ")));
    }
};

QTEST_MAIN(TestFontReactive)
#include "tst_fontreactive.moc"
