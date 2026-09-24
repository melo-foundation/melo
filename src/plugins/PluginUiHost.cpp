#include "PluginUiHost.h"
#include "PluginImportDir.h"
#include <QMetaMethod>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QDir>
#include <QFileInfo>
#include <QVariant>
#include <cstdio>

// QML registers every .qml file in a directory as a type named after the file,
// and that type wins over a same-named context property, so a `Plugin.qml`
// makes `Plugin.<anything>` silently undefined. Scans the whole directory: a
// sibling melo never opens still registers the type.
static bool shadowsInjectedName(const QString& pluginDir, const QString& rel, QString* err) {
    const QDir d(QFileInfo(QDir(pluginDir).filePath(rel)).absolutePath());
    const QStringList siblings = d.entryList(QStringList{QStringLiteral("*.qml")}, QDir::Files);
    for (const QString& name : siblings) {
        const QString base = QFileInfo(name).completeBaseName();
        for (const QLatin1String injected : { QLatin1String("Plugin"), QLatin1String("MeloUi") }) {
            if (base != injected) continue;
            if (err)
                *err = QStringLiteral(
                    "%1 must not contain a file named %2.qml: QML registers every .qml file in a "
                    "directory as a type of the same name, and that type shadows the injected %2 "
                    "object — every %2.<member> read in a qml file loaded from that directory would "
                    "silently be undefined. Rename the file.")
                    .arg(d.absolutePath(), base);
            return true;
        }
    }
    return false;
}

PluginUiHost::PluginUiHost(QString pluginId, QString pluginDir, QObject* bridge, QObject* parent)
    : QObject(parent), id_(std::move(pluginId)), dir_(std::move(pluginDir)) {
    const QString importDir = meloPluginImportDir();
    if (importDir.isEmpty()) {
        // Fatal by policy: falling back to the system import set would hand the
        // plugin Qt.labs.platform and QtQuick.LocalStorage.
        error_ = QStringLiteral("curated plugin import directory not found — refusing to load plugin QML");
        std::fprintf(stderr, "[plugin:%s] %s\n", qPrintable(id_), qPrintable(error_));
        return;
    }
    engine_ = std::make_unique<QQmlEngine>();
    // (1) the only import path, replacing the default list. C++-registered URIs
    // (`Melo 1.0`) still resolve: qmlRegisterType is process-global. Pinned by
    // tst_plugincontainment::knownGap_cppRegisteredTypesResolveInPluginEngines.
    engine_->setImportPathList(QStringList{importDir});
    // (2) the ONLY context property. melo's globals (Player, Settings,
    // WindowCtl, sidecar, Theme) are deliberately absent.
    engine_->rootContext()->setContextProperty(QStringLiteral("MeloUi"), bridge);

    // plugin QML warnings must be attributable, like the sidecar's
    // [plugin:<id>] stderr prefix
    connect(engine_.get(), &QQmlEngine::warnings, this,
            [this](const QList<QQmlError>& errs) {
        for (const auto& e : errs)
            std::fprintf(stderr, "[plugin:%s] %s\n",
                         qPrintable(id_), qPrintable(e.toString()));
    });
}

PluginUiHost::~PluginUiHost() {
    // Window contents are QObject children of the host (see createWindowContent's
    // ownership rule). ~QObject would destroy them AFTER engine_'s member
    // destructor has already run, i.e. QML objects outliving the engine that
    // created them. Take them down here, in order, while the engine is alive.
    while (!children().isEmpty())
        delete children().first();
    root_.reset();
}

bool PluginUiHost::load(const QString& entryQmlRel) {
    if (!engine_) return false;                  // keep the construction error
    error_.clear();
    if (entryQmlRel.isEmpty()) return true;      // no shared root declared
    if (shadowsInjectedName(dir_, entryQmlRel, &error_)) {
        std::fprintf(stderr, "[plugin:%s] entry %s\n",
                     qPrintable(id_), qPrintable(error_));
        return false;
    }
    QQmlComponent c(engine_.get(), QUrl::fromLocalFile(QDir(dir_).filePath(entryQmlRel)));
    if (c.isError()) { error_ = c.errorString(); return false; }
    // Do NOT reset root_ first. On a failed create that would leave the root
    // context's `Plugin` property pointing at a freed object, and any window QML
    // reading `Plugin` afterwards is a use-after-free. The old root stays live
    // and named until a replacement exists.
    std::unique_ptr<QObject> created(c.create());
    if (!created) { error_ = c.errorString(); return false; }
    // exposed to every window component as `Plugin`. Rebound BEFORE the previous
    // root is destroyed, so the name never outlives its object.
    engine_->rootContext()->setContextProperty(QStringLiteral("Plugin"), created.get());
    root_ = std::move(created);
    return true;
}

bool PluginUiHost::invokeAction(const QString& key) {
    if (!root_ || key.isEmpty()) return false;
    const QMetaObject* mo = root_->metaObject();
    const int idx = mo->indexOfMethod(QString(key + QStringLiteral("()")).toUtf8().constData());
    if (idx < 0) return false;
    const QMetaMethod m = mo->method(idx);
    // Signals (`signal resetAccent()`) and QML functions both land here as
    // zero-argument metamethods. Slots are excluded on purpose: the only
    // zero-arg slots on a QML root come from QObject itself (deleteLater), and
    // a manifest key must never reach one.
    if (m.methodType() != QMetaMethod::Signal && m.methodType() != QMetaMethod::Method)
        return false;
    // QObject's own signals pass the slot filter: indexOfMethod("destroyed()")
    // resolves moc's default-argument clone, so an action keyed `destroyed` would
    // emit QObject::destroyed on a live plugin root. Only plugin-declared methods.
    if (m.enclosingMetaObject() == &QObject::staticMetaObject) return false;
    // Cloned metamethods are moc's default-argument overloads of a method with
    // a longer signature; the manifest key never named that signature.
    if (m.attributes() & QMetaMethod::Cloned) return false;
    return m.invoke(root_.get(), Qt::DirectConnection);
}

bool PluginUiHost::invokeIdHandler(const char* method, const QString& id) {
    if (!root_ || id.isEmpty()) return false;
    const QMetaObject* mo = root_->metaObject();
    // An id addresses `function command(id)` / `function intercept(id)`, never
    // a QObject method. Do not indexOfMethod(id + "()") on the root: that
    // resolves moc's cloned destroyed() (see invokeAction). Refuse the name
    // here instead.
    if (QObject::staticMetaObject.indexOfMethod(
            QString(id + QStringLiteral("()")).toUtf8().constData()) >= 0)
        return false;
    // The method the plugin declared. Untyped QML `function command(id)` is
    // registered as command(QVariant) and as a Slot (unlike zero-arg QML
    // functions, which land as Method). A typed QString parameter is
    // command(QString). Either is one argument, never id+"()". Same for intercept.
    int idx = mo->indexOfMethod(QString("%1(QString)").arg(method).toUtf8().constData());
    if (idx < 0) idx = mo->indexOfMethod(QString("%1(QVariant)").arg(method).toUtf8().constData());
    if (idx < 0) return false;
    const QMetaMethod m = mo->method(idx);
    // Slot is allowed here: that is how QML registers command(id) / intercept(id).
    // The QObject-slot refusal is the name check above plus enclosingMetaObject,
    // so deleteLater still cannot run.
    if (m.methodType() == QMetaMethod::Constructor)
        return false;
    if (m.enclosingMetaObject() == &QObject::staticMetaObject) return false;
    if (m.attributes() & QMetaMethod::Cloned) return false;
    if (m.parameterMetaType(0).id() == QMetaType::QString)
        return m.invoke(root_.get(), Qt::DirectConnection, Q_ARG(QString, id));
    QVariant arg(id);
    return m.invoke(root_.get(), Qt::DirectConnection, Q_ARG(QVariant, arg));
}

bool PluginUiHost::invokeCommand(const QString& id) {
    return invokeIdHandler("command", id);
}

bool PluginUiHost::invokeIntercept(const QString& id) {
    return invokeIdHandler("intercept", id);
}

void PluginUiHost::refreshSettings() {
    if (refresher_) refresher_();
}

void PluginUiHost::installArchiveProvider(SkinImageProvider::Resolver resolver) {
    if (!engine_ || !resolver || archiveProviderInstalled_) return;
    archiveProviderInstalled_ = true;
    // The engine takes ownership and destroys the provider with itself. The
    // resolver must therefore stay valid for the engine's whole life — it owns
    // what it needs by shared_ptr; see MeloUiArchives::resolver().
    engine_->addImageProvider(QString::fromLatin1(SkinImageProvider::kProviderId),
                              new SkinImageProvider(std::move(resolver)));
}

// See the header for why this is allowed past (3). The gate is a bare C++ item
// with no QML context, so the occupant's first `parent` hop reaches no melo QML;
// the second does. It narrows the hole without closing it.
QObject* PluginUiHost::createSlotContent(const QString& qml, QQuickItem* slotGate) {
    if (!engine_ || !slotGate) return nullptr;
    error_.clear();
    if (shadowsInjectedName(dir_, qml, &error_)) {
        std::fprintf(stderr, "[plugin:%s] slot %s\n", qPrintable(id_), qPrintable(error_));
        return nullptr;
    }
    QQmlComponent c(engine_.get(), QUrl::fromLocalFile(QDir(dir_).filePath(qml)));
    if (c.isError()) { error_ = c.errorString(); return nullptr; }
    std::unique_ptr<QObject> o(c.create(engine_->rootContext()));
    if (!o) { error_ = c.errorString(); return nullptr; }
    auto* item = qobject_cast<QQuickItem*>(o.get());
    if (!item) {
        error_ = QStringLiteral("slot qml is not a visual item");
        std::fprintf(stderr, "[plugin:%s] %s\n", qPrintable(id_), qPrintable(error_));
        return nullptr;
    }
    item->setParentItem(slotGate);
    // Ownership is the host's, exactly as createWindowContent promises: the
    // shell deletes the returned object to empty the slot, and a teardown
    // destroys it before the engine either way.
    o->setParent(this);
    return o.release();
}

QObject* PluginUiHost::createWindowContent(const QString& qmlRel, QObject* windowParent) {
    if (!engine_) return nullptr;                // keep the construction error
    error_.clear();
    // Same shadowing hazard as entry.qml, and checked per window because a
    // window may live in a different directory than the entry file.
    if (shadowsInjectedName(dir_, qmlRel, &error_)) {
        std::fprintf(stderr, "[plugin:%s] window %s\n", qPrintable(id_), qPrintable(error_));
        return nullptr;
    }
    // (3) enforced, not merely documented: a windowParent belonging to another
    // QQmlEngine is a shell object, and reparenting into it would put melo's
    // tree one `parent` hop from plugin QML.
    if (windowParent) {
        QQmlEngine* parentEngine = qmlEngine(windowParent);
        if (parentEngine && parentEngine != engine_.get()) {
            error_ = QStringLiteral("refusing to attach plugin content to an object from another QML engine");
            std::fprintf(stderr, "[plugin:%s] %s\n", qPrintable(id_), qPrintable(error_));
            return nullptr;
        }
    }
    // A QQuickWindow is not a QQuickItem. Casting straight to QQuickItem would
    // quietly skip the reparent and render an empty window, which reads as a
    // plugin bug — resolve the window's contentItem instead.
    QQuickItem* parentItem = qobject_cast<QQuickItem*>(windowParent);
    if (!parentItem)
        if (auto* w = qobject_cast<QQuickWindow*>(windowParent))
            parentItem = w->contentItem();

    QQmlComponent c(engine_.get(), QUrl::fromLocalFile(QDir(dir_).filePath(qmlRel)));
    if (c.isError()) { error_ = c.errorString(); return nullptr; }
    std::unique_ptr<QObject> o(c.create(engine_->rootContext()));
    if (!o) { error_ = c.errorString(); return nullptr; }

    if (auto* item = qobject_cast<QQuickItem*>(o.get())) {
        if (windowParent && !parentItem) {
            // Non-null parent we cannot attach to: fail loudly rather than hand
            // back a visual root that will never appear.
            error_ = QStringLiteral("cannot attach plugin content: window parent is neither a QQuickItem nor a QQuickWindow");
            std::fprintf(stderr, "[plugin:%s] %s\n", qPrintable(id_), qPrintable(error_));
            return nullptr;
        }
        // (3) parented to the plugin's OWN window only. If parentItem were a
        // shell item, a plugin could walk parent upward into melo's object tree.
        if (parentItem)
            item->setParentItem(parentItem);
    }
    // Ownership, unconditionally: the host. setParentItem is visual only, and
    // whether it also claimed QObject parentage must not decide who frees this.
    o->setParent(this);
    return o.release();
}
