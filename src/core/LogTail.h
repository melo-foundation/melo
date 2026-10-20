#pragma once
#include <QFile>
#include <QString>
#include <QStringList>

// The last `n` lines of melo's log in `dir` (melo.log, then melo.log.1 when the
// current file is shorter), oldest first. Header-only: SettingsStore's report
// uses it, and SettingsStore is in a dozen test targets.
inline QStringList meloLogTail(const QString& dir, int n) {
    QStringList out;
    for (const QString& name : {QStringLiteral("melo.log"), QStringLiteral("melo.log.1")}) {
        if (out.size() >= n) break;
        QFile f(dir + QLatin1Char('/') + name);
        if (!f.open(QIODevice::ReadOnly)) continue;
        // a tail of 500 lines fits well inside the last 256 KB
        const qint64 want = 256 * 1024;
        if (f.size() > want) f.seek(f.size() - want);
        QStringList lines = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
        if (f.size() > want && !lines.isEmpty()) lines.removeFirst();   // cut mid-line
        if (!lines.isEmpty() && lines.last().isEmpty()) lines.removeLast();
        const int take = qMin<int>(n - out.size(), lines.size());
        out = lines.mid(lines.size() - take) + out;
    }
    return out;
}
