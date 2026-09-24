#include "MeloUiQueueView.h"
#include "QueueModel.h"
#include "SuggestionsModel.h"

// Hand-forwarded rather than proxied, because every proxy hands back a route to
// the source (see the header): sourceModel as a property, and mapToSource()
// returning an index whose QML value type carries the source model pointer.
// This mirror creates its own indices, so neither route exists.
MeloUiQueueView::MeloUiQueueView(QueueModel* src, QObject* parent)
    : QAbstractListModel(parent), src_(src) {
    if (!src_) return;
    // 1:1 flat list, so every source range forwards verbatim. QueueModel emits
    // the destination row already adjusted for beginMoveRows, so pass it on
    // untouched rather than re-deriving it.
    connect(src_, &QAbstractItemModel::rowsAboutToBeInserted, this,
            [this](const QModelIndex&, int first, int last) { beginInsertRows({}, first, last); });
    connect(src_, &QAbstractItemModel::rowsInserted, this, [this] { endInsertRows(); });
    connect(src_, &QAbstractItemModel::rowsAboutToBeRemoved, this,
            [this](const QModelIndex&, int first, int last) { beginRemoveRows({}, first, last); });
    connect(src_, &QAbstractItemModel::rowsRemoved, this, [this] { endRemoveRows(); });
    connect(src_, &QAbstractItemModel::rowsAboutToBeMoved, this,
            [this](const QModelIndex&, int start, int end, const QModelIndex&, int dest) {
                beginMoveRows({}, start, end, {}, dest);
            });
    connect(src_, &QAbstractItemModel::rowsMoved, this, [this] { endMoveRows(); });
    connect(src_, &QAbstractItemModel::modelAboutToBeReset, this, [this] { beginResetModel(); });
    connect(src_, &QAbstractItemModel::modelReset, this, [this] { endResetModel(); });
    connect(src_, &QAbstractItemModel::dataChanged, this,
            [this](const QModelIndex& tl, const QModelIndex& br, const QList<int>& roles) {
                emit dataChanged(index(tl.row()), index(br.row()), roles);
            });
    // `active` and `played` depend on currentIndex, and QueueModel::move()
    // updates current_ after endMoveRows(), so a view refreshing on the move
    // draws them one step stale. Re-announce both roles on every current change.
    connect(src_, &QueueModel::currentIndexChanged, this, [this] {
        const int n = rowCount();
        if (n > 0)
            emit dataChanged(index(0), index(n - 1),
                             {QueueModel::ActiveRole, QueueModel::PlayedRole});
    });
    // The source outlives this object in melo, but a plugin's view must not be
    // left reading a dead model if that ever stops being true.
    connect(src_, &QObject::destroyed, this, [this] {
        beginResetModel();
        src_ = nullptr;
        endResetModel();
    });
}

int MeloUiQueueView::rowCount(const QModelIndex& parent) const {
    return (src_ && !parent.isValid()) ? src_->rowCount() : 0;
}

QVariant MeloUiQueueView::data(const QModelIndex& idx, int role) const {
    if (!src_ || !idx.isValid() || idx.row() >= src_->rowCount()) return {};
    // The source index is created and consumed here; only the QVariant escapes,
    // so no QueueModel-owned QModelIndex is ever visible to QML.
    return src_->data(src_->index(idx.row(), 0), role);
}

QHash<int, QByteArray> MeloUiQueueView::roleNames() const {
    return src_ ? src_->roleNames() : QHash<int, QByteArray>{};
}

MeloUiSuggestionsView::MeloUiSuggestionsView(SuggestionsModel* src, QObject* parent)
    : QAbstractListModel(parent), src_(src) {
    if (!src_) return;
    connect(src_, &QAbstractItemModel::modelAboutToBeReset,
            this, [this] { beginResetModel(); });
    connect(src_, &QAbstractItemModel::modelReset, this, [this] { endResetModel(); });
    connect(src_, &QObject::destroyed, this, [this] {
        beginResetModel();
        src_ = nullptr;
        endResetModel();
    });
}

int MeloUiSuggestionsView::rowCount(const QModelIndex& parent) const {
    return (src_ && !parent.isValid()) ? src_->rowCount() : 0;
}

QVariant MeloUiSuggestionsView::data(const QModelIndex& idx, int role) const {
    if (!src_ || !idx.isValid() || idx.row() >= src_->rowCount()) return {};
    const QModelIndex sourceIndex = src_->index(idx.row(), 0);
    switch (role) {
    case TrackIdRole:    return src_->data(sourceIndex, SuggestionsModel::IdRole);
    case TitleRole:      return src_->data(sourceIndex, SuggestionsModel::TitleRole);
    case ChannelRole:    return src_->data(sourceIndex, SuggestionsModel::ChannelRole);
    case DurationRole:   return src_->data(sourceIndex, SuggestionsModel::DurationRole);
    case ThumbnailRole:  return src_->data(sourceIndex, SuggestionsModel::ThumbnailRole);
    case ActiveRole:
    case PlayedRole:     return false;
    case IsAutoplayRole: return src_->data(sourceIndex, SuggestionsModel::IsAutoplayRole);
    }
    return {};
}

QHash<int, QByteArray> MeloUiSuggestionsView::roleNames() const {
    return {{TrackIdRole, "trackId"}, {TitleRole, "title"}, {ChannelRole, "channel"},
            {DurationRole, "duration"}, {ThumbnailRole, "thumbnail"},
            {ActiveRole, "active"}, {PlayedRole, "played"},
            {IsAutoplayRole, "isAutoplay"}};
}
