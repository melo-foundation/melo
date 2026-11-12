#pragma once
#include <QRegularExpression>
#include <QString>

// The YouTube video a track stands for, for suggestions and its picture; empty
// when there is none. A plugin source's track has none, whatever its id. An
// imported file stands for the video it is linked to.
inline QString youtubeVideoOf(const QString& id, const QString& source, const QString& youtubeId) {
    if (!source.isEmpty() && source != QLatin1String("youtube")) return {};
    return id.startsWith(QLatin1String("local-")) ? youtubeId : id;
}

// The video a play reports to watch history: youtubeVideoOf, and only an
// 11-character video id.
inline QString reportedVideoId(const QString& id, const QString& source, const QString& youtubeId) {
    const QString v = youtubeVideoOf(id, source, youtubeId);
    static const QRegularExpression videoId(QStringLiteral("^[A-Za-z0-9_-]{11}$"));
    return videoId.match(v).hasMatch() ? v : QString();
}
