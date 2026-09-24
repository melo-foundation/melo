#pragma once
#include <QObject>
#include <QProcess>
#include <QElapsedTimer>

// Owns the sidecar child process: spawn (node + bundle path resolution), NDJSON
// line reassembly, stderr forwarding, restart policy (max 3 restarts / 60s).
class SidecarProcess : public QObject {
    Q_OBJECT
public:
    explicit SidecarProcess(QObject* parent = nullptr);
    ~SidecarProcess() override;

    void start();
    void stop();
    bool running() const;
    void sendLine(const QByteArray& jsonLine);   // appends '\n'

signals:
    void lineReceived(const QByteArray& line);   // one complete JSON message
    void started();                              // process (re)started — needs initialize
    void permanentlyFailed(const QString& reason);
    void nodeMissing();                          // no usable node (>=22.15) anywhere — bootstrap needed
    void exited();                               // the process is gone; a restart may follow

private:
    static bool nodeVersionOk(const QString& node);

private:
    void onReadyRead();
    void onFinished(int code, QProcess::ExitStatus status);
    static QString resolveNode();
    static QString resolveBundle();

    QProcess proc_;
    QByteArray buf_;
    int restarts_ = 0;
    QElapsedTimer restartWindow_;
};
