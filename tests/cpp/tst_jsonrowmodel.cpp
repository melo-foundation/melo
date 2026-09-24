#include <QSignalSpy>
#include <QtTest>

#include "JsonRowModel.h"

// Scroll-position regression guard: JsonRowModel.reset must NOT hard-reset
// (which drops every view's scroll position) for the common library
// mutations — field flips, one insertion, one removal. Only reorders may.
class TstJsonRowModel : public QObject {
    Q_OBJECT

    static QVariantMap row(const QString& id, const QString& title,
                           bool downloaded = false) {
        return {{"trackId", id}, {"title", title}, {"downloaded", downloaded}};
    }

private slots:
    void fieldChangeKeepsRows() {
        JsonRowModel m({"trackId", "title", "downloaded"});
        m.reset({row("a", "A"), row("b", "B"), row("c", "C")});

        QSignalSpy resets(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy changed(&m, &QAbstractItemModel::dataChanged);
        m.reset({row("a", "A"), row("b", "B", true), row("c", "C")});

        QCOMPARE(resets.count(), 0);
        QCOMPARE(changed.count(), 1);
        QCOMPARE(changed.first().at(0).toModelIndex().row(), 1);
        QCOMPARE(m.get(1)["downloaded"].toBool(), true);
        QCOMPARE(m.count(), 3);
    }

    void insertionIsGranular() {
        JsonRowModel m({"trackId", "title"});
        m.reset({row("a", "A"), row("c", "C")});

        QSignalSpy resets(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy inserted(&m, &QAbstractItemModel::rowsInserted);
        m.reset({row("a", "A"), row("b", "B"), row("c", "C")});

        QCOMPARE(resets.count(), 0);
        QCOMPARE(inserted.count(), 1);
        QCOMPARE(inserted.first().at(1).toInt(), 1);   // first
        QCOMPARE(inserted.first().at(2).toInt(), 1);   // last
        QCOMPARE(m.count(), 3);
        QCOMPARE(m.get(1)["trackId"].toString(), "b");
    }

    void removalIsGranular() {
        JsonRowModel m({"trackId", "title"});
        m.reset({row("a", "A"), row("b", "B"), row("c", "C")});

        QSignalSpy resets(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        m.reset({row("a", "A"), row("c", "C")});

        QCOMPARE(resets.count(), 0);
        QCOMPARE(removed.count(), 1);
        QCOMPARE(removed.first().at(1).toInt(), 1);
        QCOMPARE(m.count(), 2);
        QCOMPARE(m.get(1)["trackId"].toString(), "c");
    }

    void removalAtEndWithFieldChange() {
        JsonRowModel m({"trackId", "title", "downloaded"});
        m.reset({row("a", "A"), row("b", "B"), row("c", "C")});

        QSignalSpy resets(&m, &QAbstractItemModel::modelAboutToBeReset);
        m.reset({row("a", "A", true), row("b", "B")});

        QCOMPARE(resets.count(), 0);
        QCOMPARE(m.count(), 2);
        QCOMPARE(m.get(0)["downloaded"].toBool(), true);
    }

    void reorderFallsBackToReset() {
        JsonRowModel m({"trackId", "title"});
        m.reset({row("a", "A"), row("b", "B"), row("c", "C")});

        QSignalSpy resets(&m, &QAbstractItemModel::modelAboutToBeReset);
        m.reset({row("c", "C"), row("b", "B"), row("a", "A")});

        QCOMPARE(resets.count(), 1);   // sort change: jump to top is expected
        QCOMPARE(m.get(0)["trackId"].toString(), "c");
    }

    void initialFillAndClear() {
        JsonRowModel m({"trackId", "title"});
        QSignalSpy counts(&m, &JsonRowModel::countChanged);
        m.reset({row("a", "A")});
        QCOMPARE(m.count(), 1);
        m.reset({});
        QCOMPARE(m.count(), 0);
        QCOMPARE(counts.count(), 2);
    }
};

QTEST_GUILESS_MAIN(TstJsonRowModel)
#include "tst_jsonrowmodel.moc"
