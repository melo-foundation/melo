#include <QtTest>
#include <QProcess>
#include <QCoreApplication>
#include <cstdio>
#include <QSignalSpy>
#include "QueueModel.h"
#include "Track.h"

// Two defects that only show at the edges of the queue.
class TstQueueModel : public QObject {
    Q_OBJECT
    static QList<Track> tracks(int n) {
        QList<Track> v;
        for (int i = 0; i < n; ++i)
            v << Track{QStringLiteral("id%1").arg(i), QStringLiteral("t%1").arg(i), {}, 0, {}, {}};
        return v;
    }

private slots:
    // currentIndex left equal to size() — one past the end — makes every
    // later "what plays next" compute against an index that is not a row and
    // answer -1 for ever, with playable rows still queued.
    void removingThePlayingLastRowLeavesTheIndexInRange() {
        QueueModel q;
        q.setQueue(tracks(3), 2);
        QCOMPARE(q.currentIndex(), 2);
        q.removeAt(2);
        QCOMPARE(q.count(), 2);
        QVERIFY2(q.currentIndex() < q.count(),
                 qPrintable(QStringLiteral("currentIndex %1 is past the end of a %2-row queue")
                                .arg(q.currentIndex()).arg(q.count())));
        QVERIFY(q.currentIndex() >= -1);
    }

    void removingTheOnlyRowLeavesNothingSelected() {
        QueueModel q;
        q.setQueue(tracks(1), 0);
        q.removeAt(0);
        QCOMPARE(q.count(), 0);
        QCOMPARE(q.currentIndex(), -1);
    }

    void removingBeforeTheCurrentRowShiftsIt() {
        QueueModel q;
        q.setQueue(tracks(4), 3);
        q.removeAt(0);
        QCOMPARE(q.currentIndex(), 2);
        QCOMPARE(q.count(), 3);
    }

    // An unseeded rand() shuffles the same queue into the same order in every
    // FRESH PROCESS, which is invisible from inside one process because rand()
    // does vary from call to call. So: re-exec ourselves and compare what a
    // cold start produces.
    void shuffleDiffersAcrossFreshProcesses() {
        QSet<QString> orders;
        for (int run = 0; run < 4; ++run) {
            QProcess p;
            p.start(QCoreApplication::applicationFilePath(), {"--shuffle-once"});
            QVERIFY2(p.waitForFinished(10000), "the child did not finish");
            const QString out = QString::fromLatin1(p.readAllStandardOutput()).trimmed();
            QVERIFY2(!out.isEmpty(), "the child printed no order");
            orders.insert(out);
        }
        QVERIFY2(orders.size() > 1,
                 "four cold starts shuffled the same queue into the same order — "
                 "the generator is unseeded");
    }

    void shuffleKeepsTheCurrentRowPutAndLosesNothing() {
        QueueModel q;
        q.setQueue(tracks(8), 2);
        const QString before = q.data(q.index(2), QueueModel::IdRole).toString();
        q.shuffleUpcoming();
        QCOMPARE(q.count(), 8);
        QCOMPARE(q.data(q.index(2), QueueModel::IdRole).toString(), before);
        QSet<QString> ids;
        for (int i = 0; i < q.count(); ++i)
            ids.insert(q.data(q.index(i), QueueModel::IdRole).toString());
        QCOMPARE(ids.size(), 8);
    }
};
// The child half of shuffleDiffersAcrossFreshProcesses: shuffle once from a
// cold start and print the order.
int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    for (int i = 1; i < argc; ++i) {
        if (QString::fromLatin1(argv[i]) != QStringLiteral("--shuffle-once")) continue;
        QueueModel q;
        QList<Track> v;
        for (int n = 0; n < 8; ++n)
            v << Track{QStringLiteral("id%1").arg(n), QStringLiteral("t%1").arg(n), {}, 0, {}, {}};
        q.setQueue(v, 0);
        q.shuffleUpcoming();
        QString order;
        for (int r = 0; r < q.count(); ++r)
            order += q.data(q.index(r), QueueModel::IdRole).toString() + ",";
        std::fputs(qPrintable(order + "\n"), stdout);
        return 0;
    }
    TstQueueModel tc;
    return QTest::qExec(&tc, argc, argv);
}
#include "tst_queuemodel.moc"
