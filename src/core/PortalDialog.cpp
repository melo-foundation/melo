#include "PortalDialog.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusMetaType>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusObjectPath>
#include <QUrl>

// portal filter wire types: a(sa(us)) — (name, [(kind, pattern)...]),
// kind 0 = glob pattern
using PortalFilterCondition = QPair<uint, QString>;
using PortalFilter = QPair<QString, QList<PortalFilterCondition>>;
using PortalFilterList = QList<PortalFilter>;
Q_DECLARE_METATYPE(PortalFilterCondition)
Q_DECLARE_METATYPE(PortalFilter)
Q_DECLARE_METATYPE(PortalFilterList)

static QDBusArgument& operator<<(QDBusArgument& arg, const PortalFilterCondition& c) {
    arg.beginStructure();
    arg << c.first << c.second;
    arg.endStructure();
    return arg;
}
static const QDBusArgument& operator>>(const QDBusArgument& arg, PortalFilterCondition& c) {
    arg.beginStructure();
    arg >> c.first >> c.second;
    arg.endStructure();
    return arg;
}
static QDBusArgument& operator<<(QDBusArgument& arg, const PortalFilter& f) {
    arg.beginStructure();
    arg << f.first << f.second;
    arg.endStructure();
    return arg;
}
static const QDBusArgument& operator>>(const QDBusArgument& arg, PortalFilter& f) {
    arg.beginStructure();
    arg >> f.first >> f.second;
    arg.endStructure();
    return arg;
}

// one receiver per request: owns the Response subscription for its handle
class PortalRequestReceiver : public QObject {
    Q_OBJECT
public:
    PortalRequestReceiver(PortalDialog* owner, const QString& tag, const QString& handle)
        : QObject(owner), owner_(owner), tag_(tag), handle_(handle) {
        QDBusConnection::sessionBus().connect(
            QStringLiteral("org.freedesktop.portal.Desktop"), handle_,
            QStringLiteral("org.freedesktop.portal.Request"),
            QStringLiteral("Response"),
            this, SLOT(handleResponse(uint,QVariantMap)));
    }
public slots:
    void handleResponse(uint code, const QVariantMap& results) {
        QDBusConnection::sessionBus().disconnect(
            QStringLiteral("org.freedesktop.portal.Desktop"), handle_,
            QStringLiteral("org.freedesktop.portal.Request"),
            QStringLiteral("Response"),
            this, SLOT(handleResponse(uint,QVariantMap)));
        if (code == 0) {
            QStringList paths;
            for (const QString& u : results.value(QStringLiteral("uris")).toStringList())
                paths.append(QUrl(u).toLocalFile());
            paths.removeAll(QString());
            if (!paths.isEmpty()) emit owner_->picked(tag_, paths);
            else emit owner_->cancelled(tag_);
        } else {
            emit owner_->cancelled(tag_);
        }
        deleteLater();
    }
private:
    PortalDialog* owner_;
    QString tag_;
    QString handle_;
};

PortalDialog::PortalDialog(QObject* parent) : QObject(parent) {
    qDBusRegisterMetaType<PortalFilterCondition>();
    qDBusRegisterMetaType<QList<PortalFilterCondition>>();
    qDBusRegisterMetaType<PortalFilter>();
    qDBusRegisterMetaType<PortalFilterList>();
}

void PortalDialog::openFile(const QString& tag, const QString& title,
                            const QString& filterName, const QStringList& patterns,
                            bool multiple) {
    QVariantMap options;
    options.insert(QStringLiteral("multiple"), multiple);
    if (!patterns.isEmpty()) {
        PortalFilterList filters;
        QList<PortalFilterCondition> conds;
        for (const QString& p : patterns) conds.append({0u, p});
        filters.append({filterName, conds});
        options.insert(QStringLiteral("filters"), QVariant::fromValue(filters));
    }

    QDBusInterface chooser(QStringLiteral("org.freedesktop.portal.Desktop"),
                           QStringLiteral("/org/freedesktop/portal/desktop"),
                           QStringLiteral("org.freedesktop.portal.FileChooser"),
                           QDBusConnection::sessionBus());
    // parent_window "": non-parented (a wayland handle needs xdg_foreign
    // plumbing; portals accept the empty string)
    QDBusPendingCall call = chooser.asyncCall(QStringLiteral("OpenFile"),
                                              QString(), title, options);
    auto* watcher = new QDBusPendingCallWatcher(call, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, tag](QDBusPendingCallWatcher* w) {
        w->deleteLater();
        QDBusPendingReply<QDBusObjectPath> reply = *w;
        if (reply.isError()) { emit cancelled(tag); return; }
        new PortalRequestReceiver(this, tag, reply.value().path());
    });
}

void PortalDialog::saveFile(const QString& tag, const QString& title,
                            const QString& suggestedName, const QString& filterName,
                            const QStringList& patterns) {
    QVariantMap options;
    if (!suggestedName.isEmpty())
        options.insert(QStringLiteral("current_name"), suggestedName);
    if (!patterns.isEmpty()) {
        PortalFilterList filters;
        QList<PortalFilterCondition> conds;
        for (const QString& p : patterns) conds.append({0u, p});
        filters.append({filterName, conds});
        options.insert(QStringLiteral("filters"), QVariant::fromValue(filters));
    }

    QDBusInterface chooser(QStringLiteral("org.freedesktop.portal.Desktop"),
                           QStringLiteral("/org/freedesktop/portal/desktop"),
                           QStringLiteral("org.freedesktop.portal.FileChooser"),
                           QDBusConnection::sessionBus());
    QDBusPendingCall call = chooser.asyncCall(QStringLiteral("SaveFile"),
                                              QString(), title, options);
    auto* watcher = new QDBusPendingCallWatcher(call, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, tag](QDBusPendingCallWatcher* w) {
        w->deleteLater();
        QDBusPendingReply<QDBusObjectPath> reply = *w;
        if (reply.isError()) { emit cancelled(tag); return; }
        new PortalRequestReceiver(this, tag, reply.value().path());
    });
}


#include "PortalDialog.moc"
