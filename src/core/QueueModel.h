#pragma once
#include <QRandomGenerator>
#include <QAbstractListModel>
#include <QList>
#include "Track.h"

// The play queue. currentIndex marks the playing item; rows expose
// active/played state for the queue panel's styling.
class QueueModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY currentIndexChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles { IdRole = Qt::UserRole + 1, TitleRole, ChannelRole, DurationRole,
                 ThumbnailRole, ActiveRole, PlayedRole };

    explicit QueueModel(QObject* parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex& = {}) const override { return int(items_.size()); }
    int count() const { return int(items_.size()); }
    int currentIndex() const { return current_; }

    QVariant data(const QModelIndex& idx, int role) const override {
        if (!idx.isValid() || idx.row() >= items_.size()) return {};
        const Track& t = items_[idx.row()];
        switch (role) {
            case IdRole: return t.id;
            case TitleRole: return t.title;
            case ChannelRole: return t.channel;
            case DurationRole: return t.duration;
            case ThumbnailRole: return t.thumbnail;
            case ActiveRole: return idx.row() == current_;
            case PlayedRole: return idx.row() < current_;
        }
        return {};
    }

    QHash<int, QByteArray> roleNames() const override {
        return {{IdRole, "trackId"}, {TitleRole, "title"}, {ChannelRole, "channel"},
                {DurationRole, "duration"}, {ThumbnailRole, "thumbnail"},
                {ActiveRole, "active"}, {PlayedRole, "played"}};
    }

    // --- coordinator/QML surface ---
    const QList<Track>& tracks() const { return items_; }
    Track at(int i) const { return (i >= 0 && i < items_.size()) ? items_[i] : Track{}; }

    void setQueue(const QList<Track>& tracks, int startIndex) {
        beginResetModel();
        items_ = tracks;
        current_ = qBound(-1, startIndex, int(items_.size()) - 1);
        endResetModel();
        emit countChanged();
        emit currentIndexChanged();
    }

    void setCurrentIndex(int i) {
        if (i == current_ || i < -1 || i >= items_.size()) return;
        const int old = current_;
        current_ = i;
        emit currentIndexChanged();
        refreshRow(old);
        refreshRow(current_);
        // played flags flip for everything between old and new
        if (old >= 0 && current_ >= 0)
            emit dataChanged(index(qMin(old, current_)), index(qMax(old, current_)), {PlayedRole});
    }

    Q_INVOKABLE void append(const Track& t) {
        beginInsertRows({}, int(items_.size()), int(items_.size()));
        items_.append(t);
        endInsertRows();
        emit countChanged();
    }

    Q_INVOKABLE void insertNext(const Track& t) {
        const int pos = qBound(0, current_ + 1, int(items_.size()));
        beginInsertRows({}, pos, pos);
        items_.insert(pos, t);
        endInsertRows();
        emit countChanged();
    }

    Q_INVOKABLE void removeAt(int i) {
        if (i < 0 || i >= items_.size()) return;
        beginRemoveRows({}, i, i);
        items_.removeAt(i);
        endRemoveRows();
        if (i < current_) { current_--; emit currentIndexChanged(); }
        else if (i == current_) {
            // The caller still decides what plays, but current_ has to stay a
            // valid row. Left equal to size(), upcomingIndex() would compare
            // cur + 1 < n against an index past the end and answer -1 forever,
            // stopping playback with playable rows still in the queue.
            current_ = qMin(current_, int(items_.size()) - 1);
            emit currentIndexChanged();
        }
        emit countChanged();
    }

    Q_INVOKABLE void move(int from, int to) {
        if (from == to || from < 0 || to < 0 || from >= items_.size() || to >= items_.size()) return;
        beginMoveRows({}, from, from, {}, to > from ? to + 1 : to);
        items_.move(from, to);
        endMoveRows();
        if (from == current_) current_ = to;
        else if (from < current_ && to >= current_) current_--;
        else if (from > current_ && to <= current_) current_++;
        emit currentIndexChanged();
    }

    Q_INVOKABLE void clear() {
        beginResetModel();
        items_.clear();
        current_ = -1;
        endResetModel();
        emit countChanged();
        emit currentIndexChanged();
    }

    // Shuffle only the upcoming portion (after currentIndex).
    //
    // QRandomGenerator, not rand(): rand() is unseeded here, so every process
    // would produce the same permutation of the same queue.
    Q_INVOKABLE void shuffleUpcoming() {
        if (current_ + 1 >= items_.size() - 1) return;
        beginResetModel();
        for (int i = int(items_.size()) - 1; i > current_ + 1; --i) {
            const int lo = current_ + 1;
            const int j = lo + int(QRandomGenerator::global()->bounded(i - lo + 1));
            items_.swapItemsAt(i, qBound(lo, j, i));
        }
        endResetModel();
    }

signals:
    void currentIndexChanged();
    void countChanged();

private:
    void refreshRow(int i) {
        if (i >= 0 && i < items_.size())
            emit dataChanged(index(i), index(i), {ActiveRole, PlayedRole});
    }

    QList<Track> items_;
    int current_ = -1;
};
