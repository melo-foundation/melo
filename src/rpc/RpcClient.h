#pragma once
#include <QObject>
#include <QJsonObject>
#include <QJsonValue>
#include <QHash>

class SidecarProcess;
class QTimer;

// One in-flight JSON-RPC call. Self-deletes after finished/failed fires.
class RpcCall : public QObject {
    Q_OBJECT
signals:
    void finished(const QJsonValue& result);
    void failed(int code, const QString& message);
    friend class RpcClient;
};

// JSON-RPC 2.0 client over a SidecarProcess. Rejects all in-flight calls when
// the process dies; caller (SidecarService) re-initializes on restart.
class RpcClient : public QObject {
    Q_OBJECT
public:
    explicit RpcClient(SidecarProcess* proc, QObject* parent = nullptr);

    RpcCall* call(const QString& method, const QJsonObject& params = {}, int timeoutMs = 30000);

signals:
    void notification(const QString& method, const QJsonObject& params);

private:
    void onLine(const QByteArray& line);
    void failAll(const QString& reason);

    SidecarProcess* proc_;
    QHash<qint64, RpcCall*> pending_;
    qint64 nextId_ = 1;
};
