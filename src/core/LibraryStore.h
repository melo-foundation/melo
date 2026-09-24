#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QTimer>
#include <QVariantList>

#include "JsonRowModel.h"

class SidecarService;
class SettingsStore;

// Qt mirror of the sidecar library (library.v2.json): tracks + playlists +
// derived album groups, with view-side sort/filter. Refreshes on
// library/changed; tracks in-flight downloads via job/done.
class LibraryStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject* tracks READ tracks CONSTANT)
    Q_PROPERTY(QObject* playlists READ playlists CONSTANT)
    Q_PROPERTY(QObject* albums READ albums CONSTANT)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY countsChanged)
    Q_PROPERTY(int downloadedCount READ downloadedCount NOTIFY countsChanged)
    Q_PROPERTY(QString sortKey READ sortKey WRITE setSortKey NOTIFY viewChanged)
    Q_PROPERTY(bool sortAsc READ sortAsc WRITE setSortAsc NOTIFY viewChanged)
    Q_PROPERTY(QString filter READ filter WRITE setFilter NOTIFY viewChanged)

public:
    LibraryStore(SidecarService* sidecar, SettingsStore* settings, QObject* parent = nullptr);

    QObject* tracks() { return tracks_; }
    QObject* playlists() { return playlists_; }
    QObject* albums() { return albums_; }
    int totalCount() const { return rawTracks_.size(); }
    int downloadedCount() const;
    QString sortKey() const { return sortKey_; }
    bool sortAsc() const { return sortAsc_; }
    QString filter() const { return filter_; }
    void setSortKey(const QString& k);
    void setSortAsc(bool v);
    void setFilter(const QString& f);

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void addTrack(const QVariantMap& track, bool download);
    Q_INVOKABLE void removeTrack(const QString& id, bool deleteFile);
    Q_INVOKABLE void download(const QString& id);
    Q_INVOKABLE void downloadAll(const QStringList& ids);
    Q_INVOKABLE bool isInLibrary(const QString& id) const;
    Q_INVOKABLE bool isDownloaded(const QString& id) const;
    Q_INVOKABLE bool hasPlaylist(const QString& playlistId) const;
    Q_INVOKABLE QVariantMap playlistMeta(const QString& playlistId) const;
    Q_INVOKABLE void createPlaylist(const QString& title, const QString& trackId = {});
    Q_INVOKABLE void removePlaylist(const QString& playlistId);
    Q_INVOKABLE void renamePlaylist(const QString& playlistId, const QString& title);
    Q_INVOKABLE void addTrackToPlaylist(const QString& playlistId, const QVariantMap& track);
    Q_INVOKABLE void removeTrackFromPlaylist(const QString& playlistId, const QString& trackId);

    // SearchResult-shaped arrays for Player.playQueue()
    Q_INVOKABLE QVariantList playAllTracks(bool shuffle) const;
    // one entry as the player takes it (edited title and artist, art), or {}
    Q_INVOKABLE QVariantMap playable(const QString& id) const;
    Q_INVOKABLE QVariantList playlistTracks(const QString& playlistId) const;
    Q_INVOKABLE QVariantList albumTracks(const QString& album) const;

signals:
    void countsChanged();
    void viewChanged();

private:
    void rebuild();
    // Debounces the filter: each pass re-sorts the whole library on the GUI
    // thread and resets the model, which drops the list's scroll position.
    // Only the last keystroke's result is ever seen.
    QTimer filterDebounce_;
    QString artUrl(const QJsonObject& t) const;
    static QString displayTitle(const QJsonObject& t);
    static QString displayArtist(const QJsonObject& t);
    QVariantMap toPlayable(const QJsonObject& t) const;

    SidecarService* sidecar_;
    SettingsStore* settings_;
    QJsonArray rawTracks_;
    QJsonArray rawPlaylists_;
    QString sortKey_ = QStringLiteral("addedAt");
    bool sortAsc_ = false;
    QString filter_;
    QString settingsSig_;   // last-seen library-relevant settings
    QSet<QString> downloading_;
    JsonRowModel* tracks_;
    JsonRowModel* playlists_;
    JsonRowModel* albums_;
};
