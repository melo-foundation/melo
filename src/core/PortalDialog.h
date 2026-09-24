#pragma once
#include <QObject>
#include <QStringList>

// XDG Desktop Portal file chooser (org.freedesktop.portal.FileChooser), native
// on KDE, GNOME and wlroots; QtQuick.Dialogs would add ~4MB to the AppImages.
// Call sites route by `tag`: openFile() -> picked(tag, paths), absolute paths,
// or nothing on cancel.
class PortalDialog : public QObject {
    Q_OBJECT
public:
    explicit PortalDialog(QObject* parent = nullptr);

    Q_INVOKABLE void openFile(const QString& tag, const QString& title,
                              const QString& filterName, const QStringList& patterns,
                              bool multiple);
    Q_INVOKABLE void saveFile(const QString& tag, const QString& title,
                              const QString& suggestedName, const QString& filterName,
                              const QStringList& patterns);

signals:
    void picked(const QString& tag, const QStringList& paths);
    void cancelled(const QString& tag);
};
