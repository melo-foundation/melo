#pragma once
#include <QString>
#include <QJsonObject>
#include <QMetaType>

// Value type for a playable track; the shape PlayerState, the queue and
// suggestions share ({id,title,channel,duration,thumbnail}).
struct Track {
    Q_GADGET
    Q_PROPERTY(QString id MEMBER id)
    Q_PROPERTY(QString title MEMBER title)
    Q_PROPERTY(QString channel MEMBER channel)
    Q_PROPERTY(double duration MEMBER duration)
    Q_PROPERTY(QString thumbnail MEMBER thumbnail)
    Q_PROPERTY(QString source MEMBER source)   // "" | "youtube" | plugin source id
    Q_PROPERTY(QString youtubeId MEMBER youtubeId)   // an imported file's linked video
public:
    QString id;         // videoId (or local: prefixed id for imported files)
    QString title;
    QString channel;
    double duration = 0;
    QString thumbnail;
    QString source;
    QString youtubeId;  // local imports only: the video its plays report as

    bool isValid() const { return !id.isEmpty(); }

    static Track fromJson(const QJsonObject& o) {
        Track t;
        t.id = o["id"].toString();
        t.title = o["title"].toString();
        t.channel = o["channel"].toString();
        t.duration = o["duration"].toDouble();
        t.thumbnail = o["thumbnail"].toString();
        t.source = o.value("source").toString();
        t.youtubeId = o.value("youtubeId").toString();
        return t;
    }
    QJsonObject toJson() const {
        QJsonObject o{{"id", id}, {"title", title}, {"channel", channel},
                      {"duration", duration}, {"thumbnail", thumbnail}};
        if (!source.isEmpty()) o["source"] = source;
        if (!youtubeId.isEmpty()) o["youtubeId"] = youtubeId;
        return o;
    }
    bool operator==(const Track& o) const { return id == o.id; }
};
Q_DECLARE_METATYPE(Track)
