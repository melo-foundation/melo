#include "LibraryStore.h"

#include <QJsonDocument>
#include <QRandomGenerator>
#include <QUrl>
#include <algorithm>

#include "../rpc/SidecarService.h"
#include "../rpc/RpcClient.h"
#include "SettingsStore.h"

static const QStringList kTrackRoles = {
    "trackId", "title", "channel", "duration", "thumbnail",
    "downloaded", "downloading", "album", "addedAt"
};
static const QStringList kPlaylistRoles = {
    "playlistId", "title", "thumbnail", "trackCount"
};
static const QStringList kAlbumRoles = {
    "album", "artist", "trackCount", "art"
};

LibraryStore::LibraryStore(SidecarService* sidecar, SettingsStore* settings, QObject* parent)
    : QObject(parent), sidecar_(sidecar), settings_(settings),
      tracks_(new JsonRowModel(kTrackRoles, this)),
      playlists_(new JsonRowModel(kPlaylistRoles, this)),
      albums_(new JsonRowModel(kAlbumRoles, this)) {
    connect(sidecar_, &SidecarService::readyChanged, this, [this] { refresh(); });
    connect(sidecar_, &SidecarService::libraryChanged, this, [this] { refresh(); });
    connect(sidecar_, &SidecarService::jobDone, this,
            [this](const QString&, bool, const QJsonObject& result) {
        const QString id = result["videoId"].toString();
        if (!id.isEmpty() && downloading_.remove(id)) rebuild();
    });
    // Art URLs depend on downloadPath/artPriority — but rebuild() RESETS the
    // models (ListView scroll jumps to top), and SettingsStore::changed fires
    // for EVERY setting write (window position saves on drag, sliders...).
    // Only rebuild when the settings the library actually renders changed.
    connect(settings_, &SettingsStore::changed, this, [this] {
        const QString sig = settings_->downloadPath() + QLatin1Char('|')
                            + settings_->uiGet("artPriority", "album").toString();
        if (sig == settingsSig_) return;
        settingsSig_ = sig;
        rebuild();
    });

    filterDebounce_.setSingleShot(true);
    filterDebounce_.setInterval(120);
    connect(&filterDebounce_, &QTimer::timeout, this, &LibraryStore::rebuild);
}

int LibraryStore::downloadedCount() const {
    int n = 0;
    for (const auto& v : rawTracks_)
        if (v.toObject()["downloaded"].toBool()) ++n;
    return n;
}

void LibraryStore::setSortKey(const QString& k) {
    if (k == sortKey_) return;
    sortKey_ = k; emit viewChanged(); rebuild();
}
void LibraryStore::setSortAsc(bool v) {
    if (v == sortAsc_) return;
    sortAsc_ = v; emit viewChanged(); rebuild();
}
void LibraryStore::setFilter(const QString& f) {
    if (f == filter_) return;
    // viewChanged NOW (the text field is showing what was typed); the list
    // catches up when the typing pauses. Sorting is immediate — that is one
    // click, not a stream.
    filter_ = f; emit viewChanged();
    filterDebounce_.start();
}

void LibraryStore::refresh() {
    auto* c = sidecar_->call("library/get");
    connect(c, &RpcCall::finished, this, [this](const QJsonValue& r) {
        const QJsonObject o = r.toObject();
        rawTracks_ = o["tracks"].toArray();
        rawPlaylists_ = o["playlists"].toArray();
        emit countsChanged();
        rebuild();
    });
}

QString LibraryStore::displayTitle(const QJsonObject& t) {
    const QString clean = t["metadata"].toObject()["cleanTitle"].toString();
    return clean.isEmpty() ? t["title"].toString() : clean;
}

QString LibraryStore::displayArtist(const QJsonObject& t) {
    const QString artist = t["metadata"].toObject()["artist"].toString();
    return artist.isEmpty() ? t["channel"].toString() : artist;
}

// art priority: custom > album > thumbnail
QString LibraryStore::artUrl(const QJsonObject& t) const {
    const QString dl = settings_->downloadPath();
    const QJsonObject md = t["metadata"].toObject();
    auto local = [&dl](const QString& sub, const QString& f) {
        return QUrl::fromLocalFile(dl + "/" + sub + "/" + f).toString();
    };
    if (!dl.isEmpty()) {
        if (!md["customArtFile"].toString().isEmpty())
            return local("albumart", md["customArtFile"].toString());
        if (!md["albumArtFile"].toString().isEmpty())
            return local("albumart", md["albumArtFile"].toString());
    }
    if (!md["albumArt"].toString().isEmpty()) return md["albumArt"].toString();
    if (!dl.isEmpty() && !t["thumbnailFile"].toString().isEmpty())
        return local("thumbs", t["thumbnailFile"].toString());
    return t["thumbnail"].toString();
}

QVariantMap LibraryStore::toPlayable(const QJsonObject& t) const {
    return { { "id", t["id"].toString() },
             { "title", displayTitle(t) },
             { "channel", displayArtist(t) },
             { "duration", t["duration"].toDouble() },
             { "thumbnail", artUrl(t) },
             { "youtubeId", t["youtubeId"].toString() },
             { "downloaded", t["downloaded"].toBool() } };   // extra key; ignored by playQueue
}

QVariantMap LibraryStore::playable(const QString& id) const {
    for (const auto& v : rawTracks_) {
        const QJsonObject t = v.toObject();
        if (t["id"].toString() == id) return toPlayable(t);
    }
    return {};
}

void LibraryStore::rebuild() {
    // ---- tracks: filter, then sort ----
    // displayTitle/displayArtist each walk a nested QJsonObject and build a
    // QString; per comparison that is 2n log n constructions. Extract once per
    // track, sort the extracted rows, emit them.
    struct Row {
        QJsonObject t;
        QString title;
        QString artist;
        QString album;
        double duration;
        double addedAt;
    };
    QList<Row> ts;
    ts.reserve(rawTracks_.size());
    const QString needle = filter_.toLower();
    for (const auto& v : rawTracks_) {
        const QJsonObject t = v.toObject();
        Row r{ t, displayTitle(t), displayArtist(t),
               t["metadata"].toObject()["album"].toString(),
               t["duration"].toDouble(), t["addedAt"].toDouble() };
        if (!needle.isEmpty()) {
            const QString hay = (r.title + " " + r.artist + " " + r.album).toLower();
            if (!hay.contains(needle)) continue;
        }
        ts.append(std::move(r));
    }
    const QString key = sortKey_;
    const bool asc = sortAsc_;
    std::stable_sort(ts.begin(), ts.end(), [&](const Row& a, const Row& b) {
        int cmp = 0;
        if (key == "title")
            cmp = QString::compare(a.title, b.title, Qt::CaseInsensitive);
        else if (key == "channel")
            cmp = QString::compare(a.artist, b.artist, Qt::CaseInsensitive);
        else if (key == "duration")
            cmp = a.duration < b.duration ? -1 : a.duration > b.duration ? 1 : 0;
        else   // addedAt
            cmp = a.addedAt < b.addedAt ? -1 : a.addedAt > b.addedAt ? 1 : 0;
        return asc ? cmp < 0 : cmp > 0;
    });

    QVariantList trackRows;
    trackRows.reserve(ts.size());
    for (const auto& r : ts) {
        trackRows.append(QVariantMap{
            { "trackId", r.t["id"].toString() },
            { "title", r.title },
            { "channel", r.artist },
            { "duration", r.duration },
            { "thumbnail", artUrl(r.t) },
            { "downloaded", r.t["downloaded"].toBool() },
            { "downloading", downloading_.contains(r.t["id"].toString()) },
            { "album", r.album },
            { "addedAt", r.addedAt },
        });
    }
    tracks_->reset(trackRows);

    // ---- playlists (filtered by title like tracks/albums) ----
    QVariantList plRows;
    for (const auto& v : rawPlaylists_) {
        const QJsonObject p = v.toObject();
        if (!needle.isEmpty() && !p["title"].toString().toLower().contains(needle)) continue;
        plRows.append(QVariantMap{
            { "playlistId", p["playlistId"].toString() },
            { "title", p["title"].toString() },
            { "thumbnail", p["thumbnail"].toString() },
            { "trackCount", p["trackIds"].toArray().size() },
        });
    }
    playlists_->reset(plRows);

    // ---- albums: group filtered+sorted tracks by metadata.album ----
    QStringList order;
    QHash<QString, QList<const Row*>> groups;
    for (const auto& r : ts) {
        if (r.album.isEmpty()) continue;
        if (!groups.contains(r.album)) order.append(r.album);
        groups[r.album].append(&r);
    }
    QVariantList albumRows;
    albumRows.reserve(order.size());
    for (const QString& album : order) {
        const auto& g = groups[album];
        albumRows.append(QVariantMap{
            { "album", album },
            { "artist", g.first()->artist },
            { "trackCount", g.size() },
            { "art", artUrl(g.first()->t) },
        });
    }
    albums_->reset(albumRows);
}

void LibraryStore::addTrack(const QVariantMap& track, bool download) {
    const QString id = track["id"].toString();
    if (download && !id.isEmpty()) { downloading_.insert(id); }
    auto* c = sidecar_->call("library/addTrack",
        {{"track", QJsonObject::fromVariantMap(track)}, {"download", download}});
    connect(c, &RpcCall::failed, this, [this, id](int, const QString&) {
        downloading_.remove(id); rebuild();
    });
}

void LibraryStore::removeTrack(const QString& id, bool deleteFile) {
    sidecar_->call("library/removeTrack", {{"videoId", id}, {"deleteFile", deleteFile}});
}

void LibraryStore::download(const QString& id) {
    downloading_.insert(id);
    rebuild();
    auto* c = sidecar_->call("library/downloadTrack", {{"videoId", id}});
    connect(c, &RpcCall::failed, this, [this, id](int, const QString&) {
        downloading_.remove(id); rebuild();
    });
}

void LibraryStore::downloadAll(const QStringList& ids) {
    if (ids.isEmpty()) return;
    for (const QString& id : ids) downloading_.insert(id);
    rebuild();
    QJsonArray arr;
    for (const QString& id : ids) arr.append(id);
    sidecar_->call("library/downloadAll", {{"trackIds", arr}});
}

bool LibraryStore::isInLibrary(const QString& id) const {
    for (const auto& v : rawTracks_)
        if (v.toObject()["id"].toString() == id) return true;
    return false;
}

bool LibraryStore::hasPlaylist(const QString& playlistId) const {
    for (const auto& v : rawPlaylists_)
        if (v.toObject()["playlistId"].toString() == playlistId) return true;
    return false;
}

QVariantMap LibraryStore::playlistMeta(const QString& playlistId) const {
    for (const auto& v : rawPlaylists_) {
        const QJsonObject p = v.toObject();
        if (p["playlistId"].toString() == playlistId)
            return { { "title", p["title"].toString() },
                     { "thumbnail", p["thumbnail"].toString() } };
    }
    return {};
}

bool LibraryStore::isDownloaded(const QString& id) const {
    for (const auto& v : rawTracks_) {
        const QJsonObject t = v.toObject();
        if (t["id"].toString() == id) return t["downloaded"].toBool();
    }
    return false;
}

void LibraryStore::createPlaylist(const QString& title, const QString& trackId) {
    QJsonObject p{{"title", title}};
    if (!trackId.isEmpty()) p["trackId"] = trackId;
    sidecar_->call("library/createPlaylist", p);
}

void LibraryStore::removePlaylist(const QString& playlistId) {
    sidecar_->call("library/removePlaylist", {{"playlistId", playlistId}});
}

void LibraryStore::renamePlaylist(const QString& playlistId, const QString& title) {
    sidecar_->call("library/renamePlaylist", {{"playlistId", playlistId}, {"title", title}});
}

void LibraryStore::addTrackToPlaylist(const QString& playlistId, const QVariantMap& track) {
    sidecar_->call("library/addTrackToPlaylist",
        {{"playlistId", playlistId}, {"track", QJsonObject::fromVariantMap(track)}});
}

void LibraryStore::removeTrackFromPlaylist(const QString& playlistId, const QString& trackId) {
    sidecar_->call("library/removeTrackFromPlaylist",
        {{"playlistId", playlistId}, {"trackId", trackId}});
}

QVariantList LibraryStore::playAllTracks(bool shuffle) const {
    // current view order (rebuild() sort), full unfiltered library if no filter
    QList<QJsonObject> ts;
    for (const auto& v : rawTracks_) ts.append(v.toObject());
    QVariantList out;
    for (const auto& t : ts) out.append(toPlayable(t));
    if (shuffle) {
        for (int i = out.size() - 1; i > 0; --i)
            out.swapItemsAt(i, QRandomGenerator::global()->bounded(i + 1));
    }
    return out;
}

QVariantList LibraryStore::playlistTracks(const QString& playlistId) const {
    QVariantList out;
    for (const auto& pv : rawPlaylists_) {
        const QJsonObject p = pv.toObject();
        if (p["playlistId"].toString() != playlistId) continue;
        for (const auto& idv : p["trackIds"].toArray()) {
            const QString id = idv.toString();
            for (const auto& tv : rawTracks_) {
                const QJsonObject t = tv.toObject();
                if (t["id"].toString() == id) { out.append(toPlayable(t)); break; }
            }
        }
        break;
    }
    return out;
}

QVariantList LibraryStore::albumTracks(const QString& album) const {
    QVariantList out;
    for (const auto& v : rawTracks_) {
        const QJsonObject t = v.toObject();
        if (t["metadata"].toObject()["album"].toString() == album)
            out.append(toPlayable(t));
    }
    return out;
}
