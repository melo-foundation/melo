#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

#include "LibraryStore.h"
#include "SettingsStore.h"
#include "SidecarService.h"

// LibraryStore over a library/get reply handed in directly, the sidecar never
// started: sort clicks, the album cards a sort keeps, and id lookups.
class TstLibraryStore : public QObject {
    Q_OBJECT

    QTemporaryDir dir_;
    SidecarService* sidecar_ = nullptr;
    SettingsStore* settings_ = nullptr;

    static QJsonObject track(const QString& id, const QString& title, const QString& album,
                             double addedAt, bool downloaded = false) {
        QJsonObject md{{"cleanTitle", title}, {"artist", "Artist " + title.left(1)}};
        if (!album.isEmpty()) md["album"] = album;
        return {{"id", id}, {"title", title}, {"channel", "ch"}, {"duration", 200},
                {"thumbnail", "https://example.invalid/" + id + ".jpg"},
                {"downloaded", downloaded}, {"addedAt", addedAt}, {"metadata", md}};
    }
    static QJsonObject playlist(const QString& id, const QStringList& trackIds) {
        return {{"playlistId", id}, {"title", id}, {"thumbnail", ""},
                {"trackIds", QJsonArray::fromStringList(trackIds)}};
    }
    // three albums whose order differs between the date and the title sort
    static QJsonObject smallLibrary() {
        return {{"tracks", QJsonArray{
                    track("t1", "Charlie", "Gamma", 1),
                    track("t2", "Alpha", "Beta", 2, true),
                    track("t3", "Bravo", "Alef", 3),
                    track("t4", "Delta", "", 4)}},
                {"playlists", QJsonArray{playlist("p1", {"t3", "gone", "t1"})}}};
    }
    static QStringList albumOrder(LibraryStore& s) {
        auto* m = qobject_cast<JsonRowModel*>(s.albums());
        QStringList out;
        for (int i = 0; i < m->count(); ++i) out << m->get(i)["album"].toString();
        return out;
    }

private slots:
    void initTestCase() {
        QVERIFY(dir_.isValid());
        qputenv("MELO_CONFIG_DIR", dir_.path().toLocal8Bit());
        sidecar_ = new SidecarService(this);
        settings_ = new SettingsStore(sidecar_, this);
    }

    // The sort bar sets key and direction together: one rebuild, one model reset.
    void setSortRebuildsOnce() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary(smallLibrary());
        QSignalSpy resets(s.tracks(), SIGNAL(modelAboutToBeReset()));
        QSignalSpy view(&s, &LibraryStore::viewChanged);

        s.setSort(QStringLiteral("title"), true);

        QCOMPARE(resets.count(), 1);
        QCOMPARE(view.count(), 1);
        QCOMPARE(s.sortKey(), QStringLiteral("title"));
        QCOMPARE(s.sortAsc(), true);
        auto* m = qobject_cast<JsonRowModel*>(s.tracks());
        QCOMPARE(m->get(0)["trackId"].toString(), QStringLiteral("t2"));
    }

    void setSortSameValueIsNoOp() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary(smallLibrary());
        QSignalSpy resets(s.tracks(), SIGNAL(modelAboutToBeReset()));
        QSignalSpy view(&s, &LibraryStore::viewChanged);
        s.setSort(s.sortKey(), s.sortAsc());
        QCOMPARE(resets.count(), 0);
        QCOMPARE(view.count(), 0);
    }

    // A sort reorders the album cards in place: no reset, so no card is rebuilt.
    void sortKeepsAlbumRows() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary(smallLibrary());
        // default: newest first
        QCOMPARE(albumOrder(s), (QStringList{"Alef", "Beta", "Gamma"}));
        QSignalSpy resets(s.albums(), SIGNAL(modelAboutToBeReset()));
        QSignalSpy layouts(s.albums(), SIGNAL(layoutChanged(QList<QPersistentModelIndex>,QAbstractItemModel::LayoutChangeHint)));

        s.setSort(QStringLiteral("title"), true);

        QCOMPARE(resets.count(), 0);
        QCOMPARE(layouts.count(), 1);
        QCOMPARE(layouts.first().at(1).value<QAbstractItemModel::LayoutChangeHint>(),
                 QAbstractItemModel::VerticalSortHint);
        QCOMPARE(albumOrder(s), (QStringList{"Beta", "Alef", "Gamma"}));
    }

    void playlistTracksFollowPlaylistOrder() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary(smallLibrary());
        const QVariantList pts = s.playlistTracks(QStringLiteral("p1"));
        QCOMPARE(pts.size(), 2);   // "gone" is not in the library
        QCOMPARE(pts[0].toMap()["id"].toString(), QStringLiteral("t3"));
        QCOMPARE(pts[1].toMap()["id"].toString(), QStringLiteral("t1"));
        QVERIFY(s.playlistTracks(QStringLiteral("nope")).isEmpty());
    }

    // Lookups answer from the reply most recently applied.
    void lookupsFollowTheLatestLibrary() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary(smallLibrary());
        QVERIFY(s.isInLibrary(QStringLiteral("t2")));
        QVERIFY(s.isDownloaded(QStringLiteral("t2")));
        QVERIFY(!s.isDownloaded(QStringLiteral("t1")));
        QCOMPARE(s.playable(QStringLiteral("t3"))["title"].toString(), QStringLiteral("Bravo"));
        QVERIFY(!s.isInLibrary(QStringLiteral("zz")));
        QVERIFY(s.playable(QStringLiteral("zz")).isEmpty());

        s.applyLibrary({{"tracks", QJsonArray{track("t9", "Echo", "", 9)}},
                        {"playlists", QJsonArray{playlist("p1", {"t9", "t2"})}}});
        QVERIFY(!s.isInLibrary(QStringLiteral("t2")));
        QVERIFY(s.isInLibrary(QStringLiteral("t9")));
        QCOMPARE(s.playable(QStringLiteral("t9"))["title"].toString(), QStringLiteral("Echo"));
        const QVariantList pts = s.playlistTracks(QStringLiteral("p1"));
        QCOMPARE(pts.size(), 1);
        QCOMPARE(pts[0].toMap()["id"].toString(), QStringLiteral("t9"));
    }

    // Duplicate ids: the first entry answers.
    void duplicateIdAnswersFirst() {
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary({{"tracks", QJsonArray{track("d", "First", "", 1),
                                              track("d", "Second", "", 2, true)}},
                        {"playlists", QJsonArray{}}});
        QCOMPARE(s.playable(QStringLiteral("d"))["title"].toString(), QStringLiteral("First"));
        QVERIFY(!s.isDownloaded(QStringLiteral("d")));
    }

    // A 5,000-track playlist in a 20,000-track library opens on a click.
    void bigPlaylistIsFast() {
        QJsonArray ts;
        QStringList ids;
        for (int i = 0; i < 20000; ++i) {
            const QString id = QStringLiteral("id%1").arg(i, 6, 10, QLatin1Char('0'));
            ts.append(track(id, "T" + id, "", i));
            if (i % 4 == 0) ids << id;
        }
        std::reverse(ids.begin(), ids.end());   // the worst case for a front-to-back scan
        LibraryStore s(sidecar_, settings_);
        s.applyLibrary({{"tracks", ts}, {"playlists", QJsonArray{playlist("big", ids)}}});

        QElapsedTimer t;
        t.start();
        const QVariantList pts = s.playlistTracks(QStringLiteral("big"));
        const qint64 ms = t.elapsed();
        QCOMPARE(pts.size(), 5000);
        QCOMPARE(pts.first().toMap()["id"].toString(), ids.first());
        QVERIFY2(ms < 1000, qPrintable(QStringLiteral("playlistTracks took %1 ms").arg(ms)));
    }
};

QTEST_MAIN(TstLibraryStore)
#include "tst_librarystore.moc"
