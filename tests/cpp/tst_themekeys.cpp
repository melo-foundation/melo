#include <QtTest>
#include <QDir>
#include <QFile>
#include <QDirIterator>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSet>

// A theme setting written from QML but missing from ThemeStore's
// kAppearanceKeys is silently dropped and its control never latches. Both sides
// are read as text: the array is file-static and the QML is data.
class TestThemeKeys : public QObject {
    Q_OBJECT

private slots:
    void everyKeyQmlWritesIsAllowed() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);

        QFile store(root + "/src/core/ThemeStore.cpp");
        QVERIFY2(store.open(QIODevice::ReadOnly), "ThemeStore.cpp not readable");
        const QString src = QString::fromUtf8(store.readAll());
        const int from = src.indexOf(QStringLiteral("kAppearanceKeys[] = {"));
        QVERIFY2(from > 0, "kAppearanceKeys not found");
        const int to = src.indexOf(QStringLiteral("};"), from);
        QVERIFY(to > from);

        QSet<QString> allowed;
        QRegularExpression quoted(QStringLiteral("\"([A-Za-z0-9_]+)\""));
        auto it = quoted.globalMatch(src.mid(from, to - from));
        while (it.hasNext()) allowed.insert(it.next().captured(1));
        QVERIFY(allowed.size() > 10);

        QRegularExpression call(
            QStringLiteral("setThemeSetting\\s*\\(\\s*\"([A-Za-z0-9_]+)\""));
        QStringList missing;
        QDirIterator qml(root + "/src/qml", QStringList{"*.qml"},
                         QDir::Files, QDirIterator::Subdirectories);
        while (qml.hasNext()) {
            const QString path = qml.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QString text = QString::fromUtf8(f.readAll());
            auto m = call.globalMatch(text);
            while (m.hasNext()) {
                const QString key = m.next().captured(1);
                if (!allowed.contains(key))
                    missing += key + " (" + QFileInfo(path).fileName() + ")";
            }
        }
        if (!missing.isEmpty())
            QFAIL(qPrintable("written from QML but not in kAppearanceKeys, so it "
                             "will never take effect: " + missing.join(", ")));
    }

    static QStringList quotedIn(const QString& text, const QString& from, QChar to) {
        const int f = text.indexOf(from);
        if (f < 0) return {};
        const int t = text.indexOf(to, f + from.size());
        QStringList out;
        const QRegularExpression q(QStringLiteral("\\\"([A-Za-z0-9_]+)\\\""));
        auto m = q.globalMatch(text.mid(f, t - f));
        while (m.hasNext()) out << m.next().captured(1);
        return out;
    }
    // The part list is in two files; a part in one and not the other is
    // saved and never applied.
    void partKindsAgreeAcrossTheTwoFiles() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        QFile f(root + "/src/core/ThemeStore.cpp");
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QStringList store = quotedIn(QString::fromUtf8(f.readAll()), QStringLiteral("kThemeParts[] = {"), QLatin1Char('}'));
        QFile g(root + "/src/core/ThemeFormat.cpp");
        QVERIFY(g.open(QIODevice::ReadOnly));
        const QStringList format = quotedIn(QString::fromUtf8(g.readAll()), QStringLiteral("QStringList partKinds() {"), QLatin1Char('}'));
        QVERIFY2(format.size() >= 10, qPrintable("partKinds parsed as " + format.join(",")));
        QCOMPARE(store, format);
    }

    // Every surface role is blendable and the role list agrees across
    // ThemeFormat.cpp, Theme.qml and SettingsWindow (which reads
    // Theme.surfaceRoles). A mismatch is a swatch nothing draws or a surface
    // nobody can theme.
    void surfaceRolesAgreeAcrossTheThreeFiles() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        auto read = [&root](const char* rel) {
            QFile f(root + QLatin1String(rel));
            if (!f.open(QIODevice::ReadOnly)) return QString();
            return QString::fromUtf8(f.readAll());
        };
        const QStringList store = quotedIn(read("/src/core/ThemeFormat.cpp"),
                                           QStringLiteral("kSurfaceRoles[] = {"), QLatin1Char('}'));
        const QStringList theme = quotedIn(read("/src/qml/style/Theme.qml"),
                                           QStringLiteral("surfaceRoles: ["), QLatin1Char(']'));
        QVERIFY2(store.size() >= 13, qPrintable("kSurfaceRoles parsed as " + store.join(",")));
        QCOMPARE(theme, store);
        const QString sw = read("/src/qml/components/SettingsWindow.qml");
        QVERIFY2(sw.contains(QStringLiteral("blendableKeys: Theme.surfaceRoles.concat(Theme.inkRoles)")),
                 "SettingsWindow keeps its own list of blendable keys instead of "
                 "reading Theme.surfaceRoles");
        // and every role has a colour property in Theme, for the plain readers
        const QString tq = read("/src/qml/style/Theme.qml");
        for (const QString& r : store)
            QVERIFY2(tq.contains(QStringLiteral("readonly property color %1: roleColour(\"%1\")").arg(r)),
                     qPrintable("Theme.qml has no colour property for role " + r));
    }

    // A palette entry is a colour string or an object. The v2 string
    // "blend:multiply:adaptive:h,l,s" is a value Qt.color() cannot read, and
    // an aborted colour binding takes down every section that shows it, so
    // nothing in QML may build one.
    void nothingConstructsTheOldBlendString() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        QStringList offenders;
        QDirIterator qml(root + "/src/qml", QStringList{"*.qml"},
                         QDir::Files, QDirIterator::Subdirectories);
        while (qml.hasNext()) {
            const QString path = qml.next();
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly)) continue;
            const QString text = QString::fromUtf8(f.readAll());
            // only concatenation of a "blend:" literal counts, so a comment
            // may still mention one
            if (text.contains(QStringLiteral("\"blend:\" +")))
                offenders << QFileInfo(path).fileName();
        }
        if (!offenders.isEmpty())
            QFAIL(qPrintable("builds a v2 blend string, which is not a colour and "
                             "not a v3 entry: " + offenders.join(", ")));
    }

    // Every appearance key is in exactly one part. The parts are what presets
    // apply and what a theme selection copies; a key in none of them is a
    // setting no preset can carry, and a key in two is applied twice.
    void everyAppearanceKeyIsInExactlyOnePart() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        QFile f(root + "/src/core/ThemeStore.cpp");
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QString src = QString::fromUtf8(f.readAll());
        const QStringList all = quotedIn(src, QStringLiteral("kAppearanceKeys[] = {"), QLatin1Char('}'));
        QMap<QString, int> seen;
        for (const char* table : {"kWindowKeys[] = {", "kTypeKeys[] = {", "kSurfacesKeys[] = {",
                                  "kTransparencyKeys[] = {", "kBehaviourKeys[] = {",
                                  "kBackgroundKeys[] = {", "kSizeKeys[] = {", "kControlsKeys[] = {", "kInsetsKeys[] = {",
                                  "kGlyphsKeys[] = {",
                                  "kPlayerKeys[] = {"})
            for (const QString& k : quotedIn(src, QLatin1String(table), QLatin1Char('}'))) seen[k]++;
        QStringList none, twice;
        for (const QString& k : all) {
            if (!seen.contains(k)) none << k;
            else if (seen[k] > 1) twice << k;
        }
        for (auto it = seen.begin(); it != seen.end(); ++it)
            if (!all.contains(it.key())) none << (it.key() + " (in a part but not appearance)");
        if (!none.isEmpty()) QFAIL(qPrintable("in no part: " + none.join(", ")));
        if (!twice.isEmpty()) QFAIL(qPrintable("in two parts: " + twice.join(", ")));
    }

    // A scheme sets every scheme key, for the same reason a size preset does
    // (below).
    void everySchemeNamesEverySchemeKey() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        QFile f(root + "/src/core/ThemeStore.cpp");
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QString src = QString::fromUtf8(f.readAll());
        const QStringList keys = quotedIn(src, QStringLiteral("kSchemeKeys[] = {"), QLatin1Char('}'));
        QCOMPARE(keys.size(), 5);
        for (const char* fn : {"schemeSolid()", "schemeGlass()", "schemeTransparent()"}) {
            const int at = src.indexOf(QLatin1String(fn) + QStringLiteral(" {"));
            QVERIFY2(at > 0, fn);
            const QString body = src.mid(at, src.indexOf(QStringLiteral("}\n}"), at) - at);
            for (const QString& k : keys)
                QVERIFY2(body.contains(QLatin1Char('"') + k + QLatin1Char('"')),
                         qPrintable(QString::fromLatin1(fn) + " does not set " + k));
        }
    }

    // The blend modes live in a table in BlendItem.cpp and in an array in
    // ColorPicker.qml, and nothing links them: a mode added to one and not the
    // other is a chip that draws nothing or a mode nobody can reach.
    void everyBlendModeOfferedIsOneThatRenders() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);

        QFile cf(root + "/src/ui/BlendItem.cpp");
        QVERIFY2(cf.open(QIODevice::ReadOnly), "BlendItem.cpp not readable");
        const QString cpp = QString::fromUtf8(cf.readAll());
        const int tf = cpp.indexOf(QStringLiteral("kModes[] = {"));
        QVERIFY2(tf > 0, "kModes table not found");
        const int tt = cpp.indexOf(QStringLiteral("};"), tf);
        QVERIFY(tt > tf);
        QSet<QString> implemented;
        {
            const QRegularExpression q(QStringLiteral("\\{\"([a-z]+)\""));
            auto m = q.globalMatch(cpp.mid(tf, tt - tf));
            while (m.hasNext()) implemented.insert(m.next().captured(1));
        }
        QVERIFY2(implemented.contains(QStringLiteral("invert")),
                 qPrintable("parsed kModes as: " + QStringList(implemented.begin(),
                                                              implemented.end()).join(",")));

        QFile qf(root + "/src/qml/components/ColorPicker.qml");
        QVERIFY2(qf.open(QIODevice::ReadOnly), "ColorPicker.qml not readable");
        const QString qml = QString::fromUtf8(qf.readAll());
        const int af = qml.indexOf(QStringLiteral("blendModes: ["));
        QVERIFY2(af > 0, "blendModes array not found");
        const int at = qml.indexOf(QLatin1Char(']'), af);
        QVERIFY(at > af);
        QStringList offered;
        {
            const QRegularExpression q(QStringLiteral("\"([a-z]+)\""));
            auto m = q.globalMatch(qml.mid(af, at - af));
            while (m.hasNext()) offered << m.next().captured(1);
        }
        QVERIFY2(!offered.isEmpty(), "blendModes parsed as empty");

        // The picker has two rows. The blend row is hardware factors and must
        // match BlendItem exactly. The source row is where the colour comes
        // from; its "adaptive" is the shader in HueLum.qml, not a factor, so a
        // copy in blendModes would draw nothing.
        const int sf = qml.indexOf(QStringLiteral("sourceModes: ["));
        QVERIFY2(sf > 0, "sourceModes array not found");
        const int st = qml.indexOf(QLatin1Char(']'), sf);
        QVERIFY(st > sf);
        QStringList sources;
        {
            const QRegularExpression q(QStringLiteral("\"([a-z]+)\""));
            auto m = q.globalMatch(qml.mid(sf, st - sf));
            while (m.hasNext()) sources << m.next().captured(1);
        }
        QVERIFY2(sources.contains(QStringLiteral("colour")),
                 "the source row has to keep a plain-colour option");
        QVERIFY2(sources.contains(QStringLiteral("adaptive")),
                 "the source row no longer offers adaptive");
        QVERIFY2(!offered.contains(QStringLiteral("adaptive")),
                 "adaptive is in the blend row, where it is not a hardware "
                 "factor and would draw nothing");
        QFile hf(root + "/src/qml/components/HueLum.qml");
        QVERIFY2(hf.open(QIODevice::ReadOnly),
                 "HueLum.qml not readable, but the picker offers adaptive");

        // adaptive replaced invert in the picker, but themes on disk still say
        // "blend:invert" and BlendItem still has to render them.
        const QSet<QString> keptForOldThemes{QStringLiteral("invert")};

        QStringList notReal;
        for (const QString& o : offered)
            if (!implemented.contains(o)) notReal << o;
        if (!notReal.isEmpty())
            QFAIL(qPrintable("the picker offers blend modes BlendItem does not implement, so "
                             "they draw nothing: " + notReal.join(", ")));

        QStringList unreachable;
        for (const QString& i : implemented)
            if (!offered.contains(i) && !keptForOldThemes.contains(i)) unreachable << i;
        if (!unreachable.isEmpty())
            QFAIL(qPrintable("BlendItem implements blend modes the picker never offers, so "
                             "nobody can reach them: " + unreachable.join(", ")));
    }

    // A size preset sets every size key: a skipped key keeps its hand-set
    // value, and matchingPreset can no longer tell which preset is active. Read
    // as text so the failure names the forgotten key.
    void everySizePresetNamesEverySizeKey() {
        const QString root = QStringLiteral(MELO_SOURCE_DIR);
        QFile store(root + "/src/core/ThemeStore.cpp");
        QVERIFY2(store.open(QIODevice::ReadOnly), "ThemeStore.cpp not readable");
        const QString src = QString::fromUtf8(store.readAll());

        const int kf = src.indexOf(QStringLiteral("kSizeKeys[] = {"));
        QVERIFY2(kf > 0, "kSizeKeys not found");
        const int kt = src.indexOf(QStringLiteral("};"), kf);
        QVERIFY(kt > kf);
        QStringList keys;
        {
            const QRegularExpression q(QStringLiteral("\"([A-Za-z0-9_]+)\""));
            auto m = q.globalMatch(src.mid(kf, kt - kf));
            while (m.hasNext()) keys << m.next().captured(1);
        }
        QVERIFY2(keys.size() >= 6, qPrintable("kSizeKeys parsed as " + keys.join(",")));

        // the one place the built-in sizes are constructed
        const int af = src.indexOf(QStringLiteral("add(QStringLiteral(\"size\")"));
        QVERIFY2(af > 0, "the built-in size presets were not found");
        const int at = src.indexOf(QStringLiteral("});"), af);
        QVERIFY(at > af);
        const QString body = src.mid(af, at - af);

        QStringList missed;
        for (const QString& k : keys)
            if (!body.contains(QLatin1Char('"') + k + QLatin1Char('"')))
                missed << k;
        if (!missed.isEmpty())
            QFAIL(qPrintable("the built-in size presets do not set " + missed.join(", ")
                             + " — a size preset that leaves a lever behind is not "
                               "reproducible, and matchingPreset cannot report it honestly"));
    }
};

QTEST_MAIN(TestThemeKeys)
#include "tst_themekeys.moc"
