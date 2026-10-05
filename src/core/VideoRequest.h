#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QVariant>

// The quality row's values; anything else is the default.
inline int videoMaxHeight(const QVariant& quality) {
    bool ok = false;
    const int h = quality.toInt(&ok);
    if (ok && (h == 360 || h == 480 || h == 720 || h == 1080)) return h;
    return 720;
}

inline QJsonObject videoRequestParams(const QString& videoId, const QVariant& quality,
                                      const QStringList& codecs) {
    return {{"videoId", videoId}, {"maxHeight", videoMaxHeight(quality)},
            {"codecs", QJsonArray::fromStringList(codecs)}};
}
