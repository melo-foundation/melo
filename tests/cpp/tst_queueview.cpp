// MeloUiQueueView, the object `MeloUi.queue.model` hands a plugin and the last
// guard between a plugin and a writable queue. Covers content fidelity (a
// missed hand-written forward desyncs the plugin's playlist silently) and
// containment (a proxy would leak a writable route to QueueModel, see
// MeloUiQueueView.h). MeloUiQueue's `model` returns this same object, so the
// QML half asserts against it directly.
#include "MeloUiQueueView.h"
#include "QueueModel.h"
#include "SuggestionsModel.h"

#include <QAbstractItemModelTester>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QSignalSpy>
#include <QTest>

// A plugin ListView stand-in: holds a snapshot and re-reads only when the
// mirror signals, so a dropped forward shows as a stale snapshot. Structural
// followers resync on structural signals only, because a dataChanged resync
// masks missing ones: QueueModel::move() always emits currentIndexChanged,
// which the mirror turns into dataChanged, hiding a deleted rowsMoved forward
// (and setQueue's reset, removeAt's before/at-current cases).
class Follower : public QObject {
    Q_OBJECT
public:
    enum Kind {
        Full,        // titles + currentIndex-dependent flags; resyncs on dataChanged too
        Structural,  // titles only; deaf to dataChanged, so row signals must carry it
    };

    Follower(QAbstractItemModel* m, Kind kind) : m_(m), kind_(kind) {
        connect(m_, &QAbstractItemModel::rowsInserted, this, &Follower::resync);
        connect(m_, &QAbstractItemModel::rowsRemoved, this, &Follower::resync);
        connect(m_, &QAbstractItemModel::rowsMoved, this, &Follower::resync);
        connect(m_, &QAbstractItemModel::modelReset, this, &Follower::resync);
        connect(m_, &QAbstractItemModel::layoutChanged, this, &Follower::resync);
        if (kind_ == Full)
            connect(m_, &QAbstractItemModel::dataChanged, this, &Follower::resync);
        resync();
    }

    QString joined() const { return snapshot.join(QLatin1Char(',')); }

private:
    void resync() {
        snapshot.clear();
        for (int i = 0; i < m_->rowCount(); ++i) {
            const QModelIndex ix = m_->index(i, 0);
            QString row = m_->data(ix, QueueModel::TitleRole).toString();
            if (kind_ == Full)
                row += (m_->data(ix, QueueModel::ActiveRole).toBool() ? "*" : "")
                       + QString(m_->data(ix, QueueModel::PlayedRole).toBool() ? "." : "");
            snapshot << row;
        }
    }

    QStringList snapshot;
    QAbstractItemModel* m_;
    Kind kind_;
};

class TstQueueView : public QObject {
    Q_OBJECT

private slots:
    void contentFidelity();
    void suggestionsFidelity();
    void unforwardedSignalsStayUnused();
    void writePathsStayClosed();

private:
    static Track track(int n) {
        Track t;
        t.id = QStringLiteral("id%1").arg(n);
        t.title = QStringLiteral("t%1").arg(n);
        t.channel = QStringLiteral("chan");
        t.duration = 60 + n;
        return t;
    }
    // Titles plus the active flag, which is the role that depends on
    // currentIndex rather than on row content — the one a dataChanged forward
    // has to carry.
    static QString dump(const QAbstractItemModel* m) {
        QStringList rows;
        for (int i = 0; i < m->rowCount(); ++i) {
            const QModelIndex ix = m->index(i, 0);
            rows << m->data(ix, QueueModel::TitleRole).toString()
                        + (m->data(ix, QueueModel::ActiveRole).toBool() ? "*" : "")
                        + (m->data(ix, QueueModel::PlayedRole).toBool() ? "." : "");
        }
        return rows.join(QLatin1Char(','));
    }
};

void TstQueueView::contentFidelity() {
    QueueModel src;
    MeloUiQueueView view(&src);
    // Fatal, not Warning: on this distribution qWarning goes to journald unless
    // QT_FORCE_STDERR_LOGGING is set, so a Warning-mode tester can pass by
    // being invisible. Fatal aborts the test instead.
    QAbstractItemModelTester tester(&view, QAbstractItemModelTester::FailureReportingMode::Fatal);

    QCOMPARE(view.roleNames(), src.roleNames());
    QCOMPARE(view.rowCount(), 0);

    Follower follower(&view, Follower::Full);
    Follower structural(&view, Follower::Structural);
    // Titles only, for the structural comparison — the flags are what a stray
    // dataChanged would repair.
    auto titles = [](const QAbstractItemModel* m) {
        QStringList rows;
        for (int i = 0; i < m->rowCount(); ++i)
            rows << m->data(m->index(i, 0), QueueModel::TitleRole).toString();
        return rows.join(QLatin1Char(','));
    };
    auto same = [&](const char* what) {
        QVERIFY2(view.rowCount() == src.rowCount() && dump(&view) == dump(&src),
                 qPrintable(QStringLiteral("%1: mirror [%2] != source [%3]")
                                .arg(QString::fromUtf8(what), dump(&view), dump(&src))));
        // A follower that never heard about the change is the failure mode the
        // comparison above is blind to.
        QVERIFY2(follower.joined() == dump(&view),
                 qPrintable(QStringLiteral("%1: change not announced — follower [%2] != mirror [%3]")
                                .arg(QString::fromUtf8(what), follower.joined(), dump(&view))));
        // And this one is what the follower above is blind to: a row that moved,
        // was inserted or was removed without a structural signal, papered over
        // by a dataChanged that happened to accompany it.
        QVERIFY2(structural.joined() == titles(&view),
                 qPrintable(QStringLiteral("%1: structural change not announced — [%2] != [%3]")
                                .arg(QString::fromUtf8(what), structural.joined(), titles(&view))));
    };

    for (int i = 0; i < 5; ++i) { src.append(track(i)); same("append"); }
    QCOMPARE(dump(&view), QStringLiteral("t0,t1,t2,t3,t4"));

    src.setCurrentIndex(2);          same("setCurrentIndex forward");
    QCOMPARE(dump(&view), QStringLiteral("t0.,t1.,t2*,t3,t4"));
    src.setCurrentIndex(0);          same("setCurrentIndex backward");
    QCOMPARE(dump(&view), QStringLiteral("t0*,t1,t2,t3,t4"));

    src.setCurrentIndex(2);
    src.insertNext(track(9));        same("insertNext");
    QCOMPARE(dump(&view), QStringLiteral("t0.,t1.,t2*,t9,t3,t4"));

    src.move(0, 3);                  same("move forward");
    src.move(3, 0);                  same("move backward");
    src.move(5, 1);                  same("move backward across current");

    src.removeAt(0);                 same("removeAt before current");
    src.removeAt(src.count() - 1);   same("removeAt after current");
    src.removeAt(src.currentIndex()); same("removeAt at current");

    // shuffleUpcoming only touches rows after currentIndex, and bails out
    // entirely unless at least two of them exist. Left on the state above
    // ([t4,t1,t9] with current 2) it is a guaranteed no-op and covers nothing,
    // so set up a queue it will actually reorder — and assert that it would.
    src.setQueue({track(40), track(41), track(42), track(43), track(44), track(45)}, 1);
    same("setQueue before shuffle");
    QVERIFY2(src.currentIndex() + 1 < src.count() - 1,
             "shuffleUpcoming would bail out on this state — the case covers nothing");
    const QStringList beforeShuffle = titles(&view).split(QLatin1Char(','));
    src.shuffleUpcoming();           same("shuffleUpcoming");
    // The order after currentIndex is random, so assert what is invariant: the
    // played prefix is untouched and no row is gained, lost or duplicated.
    QCOMPARE(titles(&view).split(QLatin1Char(',')).mid(0, 2), beforeShuffle.mid(0, 2));
    QStringList shuffled = titles(&view).split(QLatin1Char(',')), original = beforeShuffle;
    shuffled.sort();
    original.sort();
    QCOMPARE(shuffled, original);

    src.setQueue({track(20), track(21), track(22)}, 1);
    same("setQueue");
    QCOMPARE(dump(&view), QStringLiteral("t20.,t21*,t22"));

    src.clear();                     same("clear");
    QCOMPARE(view.rowCount(), 0);

    for (int i = 0; i < 3; ++i) src.append(track(30 + i));
    same("refill after clear");
    QCOMPARE(dump(&view), QStringLiteral("t30,t31,t32"));

    // Count forwards: the mirror re-announces the currentIndex roles itself,
    // and every dataChanged QueueModel emits today comes with a currentIndex
    // change, so "anything arrived" would pass with the forward deleted.
    src.setCurrentIndex(0);
    QSignalSpy srcData(&src, &QAbstractItemModel::dataChanged);
    QSignalSpy srcCurrent(&src, &QueueModel::currentIndexChanged);
    QSignalSpy viewData(&view, &QAbstractItemModel::dataChanged);
    src.setCurrentIndex(2);
    // The comparison below can only fail while the source emits more
    // dataChanged than currentIndexChanged; if QueueModel stops doing so, this
    // case is vacuous.
    QVERIFY2(srcData.count() > srcCurrent.count(),
             qPrintable(QStringLiteral("source emitted %1 dataChanged for %2 currentIndexChanged — "
                                       "the mirror's own re-announcement now covers them all, so "
                                       "this case can no longer detect a dropped forward")
                            .arg(srcData.count())
                            .arg(srcCurrent.count())));
    QVERIFY2(viewData.count() >= srcData.count(),
             qPrintable(QStringLiteral("source emitted %1 dataChanged, mirror forwarded only %2")
                            .arg(srcData.count())
                            .arg(viewData.count())));
    same("dataChanged forward");
}

void TstQueueView::suggestionsFidelity() {
    SuggestionsModel src;
    MeloUiSuggestionsView view(&src);
    QAbstractItemModelTester tester(&view, QAbstractItemModelTester::FailureReportingMode::Fatal);
    Follower follower(&view, Follower::Full);

    Track autoplay = track(9);
    src.set({track(1), track(2)}, autoplay);
    QCOMPARE(view.rowCount(), 3);
    QCOMPARE(follower.joined(), QStringLiteral("t9,t1,t2"));
    QCOMPARE(view.data(view.index(0, 0), MeloUiSuggestionsView::TitleRole).toString(),
             QStringLiteral("t9"));
    QCOMPARE(view.data(view.index(1, 0), MeloUiSuggestionsView::ChannelRole).toString(),
             QStringLiteral("chan"));
    QVERIFY(view.data(view.index(0, 0), MeloUiSuggestionsView::IsAutoplayRole).toBool());
    QVERIFY(!view.data(view.index(1, 0), MeloUiSuggestionsView::IsAutoplayRole).toBool());
    QVERIFY(!view.data(view.index(0, 0), MeloUiSuggestionsView::ActiveRole).toBool());
    QVERIFY(!view.data(view.index(0, 0), MeloUiSuggestionsView::PlayedRole).toBool());
    QCOMPARE(view.roleNames().value(MeloUiSuggestionsView::ActiveRole), QByteArray("active"));
    QCOMPARE(view.roleNames().value(MeloUiSuggestionsView::PlayedRole), QByteArray("played"));

    // A second response replaces suggestions wholesale; the mirror must emit a
    // reset or a plugin ListView remains on the previous video's tracks.
    src.set({track(4)}, Track{});
    QCOMPARE(view.rowCount(), 1);
    QCOMPARE(follower.joined(), QStringLiteral("t4"));
    src.clear();
    QCOMPARE(view.rowCount(), 0);
    QCOMPARE(follower.joined(), QString());
}

// The mirror forwards rows*, modelReset and dataChanged, and nothing else.
// That is only safe while QueueModel emits nothing else. Encode the assumption
// so it fails here, loudly, rather than as drift in a plugin's playlist.
void TstQueueView::unforwardedSignalsStayUnused() {
    QueueModel src;
    MeloUiQueueView view(&src);

    QSignalSpy layout(&src, &QAbstractItemModel::layoutChanged);
    QSignalSpy layoutAbout(&src, &QAbstractItemModel::layoutAboutToBeChanged);
    QSignalSpy header(&src, &QAbstractItemModel::headerDataChanged);
    QSignalSpy colsIns(&src, &QAbstractItemModel::columnsInserted);
    QSignalSpy colsRem(&src, &QAbstractItemModel::columnsRemoved);
    QSignalSpy colsMoved(&src, &QAbstractItemModel::columnsMoved);

    for (int i = 0; i < 5; ++i) src.append(track(i));
    src.insertNext(track(9));
    src.setCurrentIndex(2);
    src.move(0, 3);
    src.move(3, 0);
    src.removeAt(0);
    src.shuffleUpcoming();
    src.setQueue({track(20), track(21)}, 0);
    src.clear();

    const char* msg = "QueueModel grew a signal MeloUiQueueView does not forward — "
                      "add the forward (and a fidelity case) before relaxing this";
    QVERIFY2(layout.isEmpty(), msg);
    QVERIFY2(layoutAbout.isEmpty(), msg);
    QVERIFY2(header.isEmpty(), msg);
    QVERIFY2(colsIns.isEmpty(), msg);
    QVERIFY2(colsRem.isEmpty(), msg);
    QVERIFY2(colsMoved.isEmpty(), msg);

    QCOMPARE(view.rowCount(), src.rowCount());
}

// Everything here runs inside a real QML document. It has to: QtQml's value
// types (QModelIndex among them) are only registered once a document imports a
// module, so probing from a bare QQmlExpression reports `undefined` for members
// that a plugin can in fact reach.
void TstQueueView::writePathsStayClosed() {
    QueueModel src;
    for (int i = 0; i < 5; ++i) src.append(track(i));
    MeloUiQueueView view(&src);

    QQmlEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("M"), &view);

    QQmlComponent component(&engine);
    component.setData(R"(
import QtQml
QtObject {
    // Routes back to the source, and QueueModel's own mutators. All must be
    // absent: a proxy would expose sourceModel and mapToSource, and the raw
    // model would expose the mutators.
    property string absent: {
        var names = ['sourceModel', 'mapToSource', 'mapFromSource', 'mapSelectionToSource',
                     'mapSelectionFromSource', 'clear', 'removeAt', 'move', 'append',
                     'insertNext', 'shuffleUpcoming', 'setQueue', 'setCurrentIndex', 'tracks'];
        var out = [];
        for (var i = 0; i < names.length; ++i)
            if (typeof M[names[i]] !== 'undefined') out.push(names[i]);
        return out.join(',');
    }
    // An index must belong to the mirror, never to QueueModel: the QML value
    // type for QModelIndex exposes the model that created it.
    property bool indexIsOurs: M.index(0, 0).model === M
    property string indexModelMutator: typeof M.index(0, 0).model.clear
    property var rootParentModel: M.index(0, 0).parent.model
    // Inherited QAbstractItemModel invokables. Reachable, and that is fine as
    // long as none of them writes.
    property string writeAttempts: [
        'setData=' + M.setData(M.index(0, 0), 'x', 258),
        'removeRows=' + M.removeRows(0, 1),
        'insertRows=' + M.insertRows(0, 1),
        'removeColumns=' + M.removeColumns(0, 1),
        'insertColumns=' + M.insertColumns(0, 1),
        'moveRows=' + M.moveRows(M.index(0, 0).parent, 0, 1, M.index(0, 0).parent, 3)
    ].join(' ')
    property string noOps: {
        M.sort(0); M.revert(); M.fetchMore(M.index(0, 0).parent);
        return 'submit=' + M.submit();
    }
    // Reads keep working.
    property int rows: M.rowCount()
    property int cols: M.columnCount()
    property string title2: M.data(M.index(2, 0), 258)
    property bool hasRow4: M.hasIndex(4, 0)
}
)", QUrl(QStringLiteral("qrc:/tst_queueview.qml")));

    QScopedPointer<QObject> root(component.create());
    QVERIFY2(!root.isNull(), qPrintable(component.errorString()));

    QCOMPARE(root->property("absent").toString(), QString());
    QVERIFY2(root->property("indexIsOurs").toBool(), "an index escaped belonging to QueueModel");
    QCOMPARE(root->property("indexModelMutator").toString(), QStringLiteral("undefined"));
    QVERIFY2(root->property("rootParentModel").isNull(), "the root parent index named a model");
    QCOMPARE(root->property("writeAttempts").toString(),
             QStringLiteral("setData=false removeRows=false insertRows=false "
                            "removeColumns=false insertColumns=false moveRows=false"));
    QCOMPARE(root->property("noOps").toString(), QStringLiteral("submit=true"));

    QCOMPARE(root->property("rows").toInt(), 5);
    QCOMPARE(root->property("cols").toInt(), 1);
    QCOMPARE(root->property("title2").toString(), QStringLiteral("t2"));
    QVERIFY(root->property("hasRow4").toBool());

    // The whole point: after every write QML could attempt, the queue is intact.
    QCOMPARE(src.count(), 5);
    QCOMPARE(dump(&view), QStringLiteral("t0,t1,t2,t3,t4"));
    QCOMPARE(dump(&view), dump(&src));
}

QTEST_GUILESS_MAIN(TstQueueView)
#include "tst_queueview.moc"
