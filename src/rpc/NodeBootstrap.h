#pragma once
#include <QNetworkAccessManager>
#include <QObject>

// One-time Node.js runtime download for the lite AppImage: no bundled node,
// system node too old or absent -> fetch the pinned official tarball, verify
// sha256, extract just bin/node beside yt-dlp (~/.local/share/melo/bin/).
class NodeBootstrap : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY stateChanged)
    Q_PROPERTY(double progress READ progress NOTIFY stateChanged)   // 0..1
    Q_PROPERTY(int receivedMB READ receivedMB NOTIFY stateChanged)
    Q_PROPERTY(int totalMB READ totalMB NOTIFY stateChanged)
    Q_PROPERTY(QString error READ error NOTIFY stateChanged)
public:
    explicit NodeBootstrap(QObject* parent = nullptr) : QObject(parent) {}

    bool active() const { return active_; }
    double progress() const { return progress_; }
    int receivedMB() const { return receivedMB_; }
    int totalMB() const { return totalMB_; }
    QString error() const { return error_; }

    static QString installedPath();

    Q_INVOKABLE void download();

signals:
    void stateChanged();
    void finished(bool ok);

private:
    void fail(const QString& why);

    QNetworkAccessManager nam_;
    bool active_ = false;
    double progress_ = 0;
    int receivedMB_ = 0;
    int totalMB_ = 0;
    QString error_;
};
