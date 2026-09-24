#pragma once
#include <QObject>
#include <QJsonObject>
#include <QMap>
#include <QHash>

class SidecarService;

// Typed mirror of the sidecar's v2 settings. Loaded once on sidecar-ready;
// set() patches via RPC and updates local state on reply. UI-only keys live
// in the opaque `ui` object (uiGet/uiSet) owned by the Qt side.
class SettingsStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
    // same path SidecarService::initialize() sends as "dataDir"
    // (meloConfigDir() in paths.h)
    Q_PROPERTY(QString dataDir READ dataDir CONSTANT)
    Q_PROPERTY(QString cookieSource READ cookieSource WRITE setCookieSource NOTIFY changed)
    Q_PROPERTY(QString downloadPath READ downloadPath NOTIFY changed)
    Q_PROPERTY(int prefetchPercent READ prefetchPercent WRITE setPrefetchPercent NOTIFY changed)
    Q_PROPERTY(double crossfadeSeconds READ crossfadeSeconds WRITE setCrossfadeSeconds NOTIFY changed)
    Q_PROPERTY(bool silenceSkip READ silenceSkip WRITE setSilenceSkip NOTIFY changed)
    Q_PROPERTY(bool sendPlayback READ sendPlayback WRITE setSendPlayback NOTIFY changed)
    Q_PROPERTY(QString homeSource READ homeSource WRITE setHomeSource NOTIFY changed)
    Q_PROPERTY(QString cookieProfile READ cookieProfile WRITE setCookieProfile NOTIFY changed)
    Q_PROPERTY(QString browser READ browser WRITE setBrowser NOTIFY changed)
    Q_PROPERTY(QString lastfmApiKey READ lastfmApiKey WRITE setLastfmApiKey NOTIFY changed)
    Q_PROPERTY(QString metadataAutoEnrich READ metadataAutoEnrich WRITE setMetadataAutoEnrich NOTIFY changed)
    // which services tagging may contact; on unless switched off
    Q_PROPERTY(bool tagLastfm READ tagLastfm WRITE setTagLastfm NOTIFY changed)
    Q_PROPERTY(bool tagMusicBrainz READ tagMusicBrainz WRITE setTagMusicBrainz NOTIFY changed)
    Q_PROPERTY(bool tagDeezer READ tagDeezer WRITE setTagDeezer NOTIFY changed)
    Q_PROPERTY(QString ytdlpChannel READ ytdlpChannel WRITE setYtdlpChannel NOTIFY changed)
    Q_PROPERTY(bool lyricsAutoCaptions READ lyricsAutoCaptions WRITE setLyricsAutoCaptions NOTIFY changed)
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY changed)
    Q_PROPERTY(QString region READ region WRITE setRegion NOTIFY changed)

public:
    // Takes a sidecar snapshot as the truth, with writes still in flight put
    // back on top. Public so a test can hand one in.
    void apply(const QJsonObject& fresh);
    explicit SettingsStore(SidecarService* sidecar, QObject* parent = nullptr);

    bool loaded() const { return loaded_; }
    QString dataDir() const;
    QString cookieSource() const { return s_["cookieSource"].toString(); }
    QString downloadPath() const { return s_["downloadPath"].toString(); }
    int prefetchPercent() const { return s_["prefetchPercent"].toInt(50); }
    double crossfadeSeconds() const { return s_["crossfadeSeconds"].toDouble(); }
    bool silenceSkip() const { return s_["silenceSkip"].toBool(); }
    bool sendPlayback() const { return s_["sendPlayback"].toBool(true); }
    QString homeSource() const { return s_["homeSource"].toString(); }
    QString cookieProfile() const { return s_["cookieProfile"].toString(); }
    QString browser() const { return s_["browser"].toString(); }
    QString lastfmApiKey() const { return s_["lastfmApiKey"].toString(); }
    QString metadataAutoEnrich() const { return s_["metadataAutoEnrich"].toString(); }
    bool tagLastfm() const { return s_["tagLastfm"].toBool(true); }
    bool tagMusicBrainz() const { return s_["tagMusicBrainz"].toBool(true); }
    bool tagDeezer() const { return s_["tagDeezer"].toBool(true); }
    QString language() const { return s_["language"].toString(); }   // hl; "" = system
    QString region() const { return s_["region"].toString(); }       // gl; "" = system
    QString ytdlpChannel() const {
        const QString v = s_["ytdlpChannel"].toString();
        return v.isEmpty() ? QStringLiteral("stable") : v;   // pre-existing configs
    }

    void setCookieSource(const QString& v) { patch({{"cookieSource", v}}); }
    void setCrossfadeSeconds(double v) { patch({{"crossfadeSeconds", v}}); }
    void setSilenceSkip(bool v) { patch({{"silenceSkip", v}}); }
    void setPrefetchPercent(int v) { patch({{"prefetchPercent", v}}); }
    void setSendPlayback(bool v) { patch({{"sendPlayback", v}}); }
    void setHomeSource(const QString& v) { patch({{"homeSource", v}}); }
    void setCookieProfile(const QString& v) { patch({{"cookieProfile", v}}); }
    void setBrowser(const QString& v) { patch({{"browser", v}}); }
    void setLastfmApiKey(const QString& v) { patch({{"lastfmApiKey", v}}); }
    void setMetadataAutoEnrich(const QString& v) { patch({{"metadataAutoEnrich", v}}); }
    void setTagLastfm(bool v) { patch({{"tagLastfm", v}}); }
    void setTagMusicBrainz(bool v) { patch({{"tagMusicBrainz", v}}); }
    void setTagDeezer(bool v) { patch({{"tagDeezer", v}}); }
    void setYtdlpChannel(const QString& v) { patch({{"ytdlpChannel", v}}); }
    bool lyricsAutoCaptions() const { return s_["lyricsAutoCaptions"].toBool(); }
    void setLyricsAutoCaptions(bool v) { patch({{"lyricsAutoCaptions", v}}); }
    void setLanguage(const QString& v) { patch({{"language", v}}); }
    void setRegion(const QString& v) { patch({{"region", v}}); }

    Q_INVOKABLE QVariant uiGet(const QString& key, const QVariant& fallback = {}) const;
    Q_INVOKABLE void uiSet(const QString& key, const QVariant& value);
    Q_INVOKABLE void uiSetMany(const QVariantMap& values);   // single RPC patch
    void uiApply(const QVariantMap& values, const QStringList& remove);
    bool uiHas(const QString& key) const;

    Q_INVOKABLE void refresh();   // settings/get -> replace local mirror

signals:
    void loadedChanged();
    void changed();

private:
    void patch(const QJsonObject& p, const QStringList& holdUi = {}, const QStringList& removeUi = {});
    // UI keys written here and not yet confirmed. Every reply replaces the
    // whole mirror with what the sidecar had when it answered, which may
    // predate a write of ours; these are held on top so an edit does not
    // revert when another round trip comes back.
    QMap<QString, QJsonValue> pendingUi_;   // a map, not a QJsonObject: an object drops an Undefined, which is what a held removal is
    // Which write each held key belongs to, so an older reply cannot release
    // a key a newer write still holds and put its older snapshot over the
    // newer value.
    QHash<QString, quint64> pendingSeq_;
    quint64 writeSeq_ = 0;

    SidecarService* sidecar_;
    QJsonObject s_;
    bool loaded_ = false;
};
