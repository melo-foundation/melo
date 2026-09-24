#pragma once
#include <QAbstractListModel>
#include <QHash>
#include <QPointer>

class QueueModel;
class SuggestionsModel;

// What `MeloUi.queue.model` hands a plugin: a mirror, because both the real
// QueueModel and a QIdentityProxyModel let plugin QML mutate the queue behind
// PlaybackCoordinator (verified on Qt 6.10.3):
//   - QueueModel exposes its Q_INVOKABLE append/insertNext/removeAt/move/clear/
//     shuffleUpcoming.
//   - A proxy exposes the writable sourceModel property, and even with that
//     shadowed, Q_INVOKABLE mapToSource returns a QModelIndex whose `.model` is
//     the source.
// A mirror owns its indices, so there is no source to reach. The inherited
// mutators (setData, insertRows, removeRows, moveRows, sort) are left
// unimplemented and return false or no-op.
//
// Plugin QML reaches every class between QObject and this one, plus the value
// types return values decay to; even the protected slot resetInternalData
// resolves, because the property cache filters on Private alone.
//
// The forwarding is hand-written and goes stale silently if QueueModel gains a
// new mutation shape; tests/cpp/tst_queueview.cpp catches that. This class has
// its own translation unit so the test links it against QueueModel alone.
class MeloUiQueueView : public QAbstractListModel {
    Q_OBJECT
public:
    explicit MeloUiQueueView(QueueModel* src, QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& idx, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

private:
    QPointer<QueueModel> src_;
};

// Suggestions use the same track roles as the queue, plus isAutoplay. This
// mirror adds inactive `active`/`played` roles so plugin QML can switch between
// queue and suggestions without swapping delegate types, while still exposing
// no route back to the shell's model.
class MeloUiSuggestionsView : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles { TrackIdRole = Qt::UserRole + 1, TitleRole, ChannelRole,
                 DurationRole, ThumbnailRole, ActiveRole, PlayedRole,
                 IsAutoplayRole };

    explicit MeloUiSuggestionsView(SuggestionsModel* src, QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& idx, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

private:
    QPointer<SuggestionsModel> src_;
};
