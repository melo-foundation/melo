#include "RpcClient.h"
#include "SidecarProcess.h"

#include <QJsonDocument>
#include <QTimer>

RpcClient::RpcClient(SidecarProcess* proc, QObject* parent)
    : QObject(parent), proc_(proc) {
    connect(proc_, &SidecarProcess::lineReceived, this, &RpcClient::onLine);
    connect(proc_, &SidecarProcess::started, this, [this] { failAll("sidecar restarted"); });
    connect(proc_, &SidecarProcess::permanentlyFailed, this,
            [this](const QString& r) { failAll(r); });
}

RpcCall* RpcClient::call(const QString& method, const QJsonObject& params, int timeoutMs) {
    auto* rpcCall = new RpcCall;
    const qint64 id = nextId_++;
    pending_.insert(id, rpcCall);

    QJsonObject msg{
        {"jsonrpc", "2.0"},
        {"id", id},
        {"method", method},
        {"params", params},
    };
    proc_->sendLine(QJsonDocument(msg).toJson(QJsonDocument::Compact));

    auto* timer = new QTimer(rpcCall);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, rpcCall, [this, id, rpcCall] {
        if (pending_.remove(id)) {
            emit rpcCall->failed(-32001, "timeout");
            rpcCall->deleteLater();
        }
    });
    timer->start(timeoutMs);
    return rpcCall;
}

void RpcClient::onLine(const QByteArray& line) {
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(line, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;
    const QJsonObject msg = doc.object();

    if (!msg.contains("id")) {   // notification
        emit notification(msg["method"].toString(), msg["params"].toObject());
        return;
    }
    const qint64 id = qint64(msg["id"].toDouble());
    RpcCall* rpcCall = pending_.take(id);
    if (!rpcCall) return;   // already timed out
    if (msg.contains("error")) {
        const QJsonObject e = msg["error"].toObject();
        emit rpcCall->failed(e["code"].toInt(), e["message"].toString());
    } else {
        emit rpcCall->finished(msg["result"]);
    }
    rpcCall->deleteLater();
}

void RpcClient::failAll(const QString& reason) {
    const auto calls = pending_;
    pending_.clear();
    for (RpcCall* c : calls) {
        emit c->failed(-32002, "SidecarDied: " + reason);
        c->deleteLater();
    }
}
