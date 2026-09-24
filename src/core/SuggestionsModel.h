#pragma once
#include <QAbstractListModel>
#include <QList>
#include "Track.h"

// Suggestions from yt/getNext (+ the autoplay item merged first).
class SuggestionsModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles { IdRole = Qt::UserRole + 1, TitleRole, ChannelRole, DurationRole,
                 ThumbnailRole, IsAutoplayRole };

    explicit SuggestionsModel(QObject* parent = nullptr) : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex& = {}) const override { return int(items_.size()); }
    int count() const { return int(items_.size()); }

    QVariant data(const QModelIndex& idx, int role) const override {
        if (!idx.isValid() || idx.row() >= items_.size()) return {};
        const Track& t = items_[idx.row()];
        switch (role) {
            case IdRole: return t.id;
            case TitleRole: return t.title;
            case ChannelRole: return t.channel;
            case DurationRole: return t.duration;
            case ThumbnailRole: return t.thumbnail;
            case IsAutoplayRole: return idx.row() == 0 && hasAutoplayFirst_;
        }
        return {};
    }

    QHash<int, QByteArray> roleNames() const override {
        return {{IdRole, "trackId"}, {TitleRole, "title"}, {ChannelRole, "channel"},
                {DurationRole, "duration"}, {ThumbnailRole, "thumbnail"},
                {IsAutoplayRole, "isAutoplay"}};
    }

    Track at(int i) const { return (i >= 0 && i < items_.size()) ? items_[i] : Track{}; }
    Track autoplayTrack() const { return hasAutoplayFirst_ && !items_.isEmpty() ? items_.first() : Track{}; }

    void set(const QList<Track>& suggestions, const Track& autoplay) {
        beginResetModel();
        items_.clear();
        hasAutoplayFirst_ = autoplay.isValid();
        if (hasAutoplayFirst_) items_.append(autoplay);
        for (const Track& t : suggestions)
            if (!hasAutoplayFirst_ || t.id != autoplay.id) items_.append(t);
        endResetModel();
        emit countChanged();
    }

    // Paged related list: the next page appends, the autoplay item stays first.
    void append(const QList<Track>& more) {
        QList<Track> add;
        for (const Track& t : more) {
            if (!t.isValid()) continue;
            bool dup = false;
            for (const Track& have : items_) if (have.id == t.id) { dup = true; break; }
            for (const Track& have : add) if (have.id == t.id) { dup = true; break; }
            if (!dup) add.append(t);
        }
        if (add.isEmpty()) return;
        beginInsertRows({}, int(items_.size()), int(items_.size() + add.size()) - 1);
        items_.append(add);
        endInsertRows();
        emit countChanged();
    }

    void clear() {
        beginResetModel();
        items_.clear();
        hasAutoplayFirst_ = false;
        endResetModel();
        emit countChanged();
    }

signals:
    void countChanged();

private:
    QList<Track> items_;
    bool hasAutoplayFirst_ = false;
};
