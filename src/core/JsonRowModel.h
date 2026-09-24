#pragma once
#include <QAbstractListModel>
#include <QVariantList>
#include <QVariantMap>

// Generic list model over QVariantMap rows (role names fixed at construction;
// the FIRST role is the row identity key for diffing).
class JsonRowModel : public QAbstractListModel {
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
public:
    explicit JsonRowModel(const QStringList& roleNames, QObject* parent = nullptr)
        : QAbstractListModel(parent), names_(roleNames) {}

    int count() const { return rows_.size(); }

    // Diff-aware refresh: beginResetModel makes attached views drop their
    // scroll position. Same keys in same order -> per-row dataChanged; one
    // contiguous run inserted/removed -> granular insert/remove; only a reorder
    // (sort or filter change, where a jump to top is expected) hard-resets.
    void reset(const QVariantList& rows) {
        const int oldN = rows_.size(), newN = rows.size();
        if (oldN > 0 && newN > 0) {
            const QString key = names_.first();
            const auto k = [&](const QVariantList& l, int i) {
                return l[i].toMap().value(key);
            };
            int p = 0;
            const int maxP = qMin(oldN, newN);
            while (p < maxP && k(rows_, p) == k(rows, p)) ++p;
            int s = 0;
            const int maxS = maxP - p;   // suffix must not overlap the prefix
            while (s < maxS && k(rows_, oldN - 1 - s) == k(rows, newN - 1 - s)) ++s;
            if (p + s == oldN || p + s == newN) {   // one splice (or none)
                if (newN > oldN) {
                    beginInsertRows({}, p, p + (newN - oldN) - 1);
                    for (int i = 0; i < newN - oldN; ++i) rows_.insert(p + i, rows[p + i]);
                    endInsertRows();
                } else if (oldN > newN) {
                    beginRemoveRows({}, p, p + (oldN - newN) - 1);
                    for (int i = 0; i < oldN - newN; ++i) rows_.removeAt(p);
                    endRemoveRows();
                }
                for (int i = 0; i < newN; ++i) {   // in-place field refresh
                    if (rows_[i] != rows[i]) {
                        rows_[i] = rows[i];
                        emit dataChanged(index(i), index(i));
                    }
                }
                if (oldN != newN) emit countChanged();
                return;
            }
        }
        beginResetModel();
        rows_ = rows;
        endResetModel();
        emit countChanged();
    }

    Q_INVOKABLE QVariantMap get(int i) const {
        return (i >= 0 && i < rows_.size()) ? rows_[i].toMap() : QVariantMap();
    }

    int rowCount(const QModelIndex& = {}) const override { return rows_.size(); }
    QVariant data(const QModelIndex& idx, int role) const override {
        if (!idx.isValid() || idx.row() >= rows_.size()) return {};
        const int i = role - Qt::UserRole - 1;
        if (i < 0 || i >= names_.size()) return {};
        return rows_[idx.row()].toMap().value(names_[i]);
    }
    QHash<int, QByteArray> roleNames() const override {
        QHash<int, QByteArray> h;
        for (int i = 0; i < names_.size(); ++i)
            h[Qt::UserRole + 1 + i] = names_[i].toUtf8();
        return h;
    }

signals:
    void countChanged();

private:
    QStringList names_;
    QVariantList rows_;
};
