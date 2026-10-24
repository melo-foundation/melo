// A YouTube title holding an <img src="http://…"> must stay words: melo's text
// items draw plain text, so the tag never makes Qt fetch the URL. A plain Text
// left on AutoText is the control: it does ask, which proves the counter sees it.
#include <QGuiApplication>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQmlNetworkAccessManagerFactory>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <atomic>

static std::atomic<int> g_requests{0};

class CountingNam : public QNetworkAccessManager {
protected:
    QNetworkReply* createRequest(Operation op, const QNetworkRequest& req, QIODevice* data) override {
        if (req.url().scheme().startsWith(QLatin1String("http"))) ++g_requests;
        // never leave the machine: every request goes to a closed local port
        QNetworkRequest local(req);
        local.setUrl(QUrl(QStringLiteral("http://127.0.0.1:9/blocked")));
        return QNetworkAccessManager::createRequest(op, local, data);
    }
};
class CountingFactory : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager* create(QObject* parent) override {
        auto* nam = new CountingNam;
        nam->setParent(parent);
        return nam;
    }
};

class TstPlainText : public QObject {
    Q_OBJECT
    CountingFactory factory_;

    int requestsFor(const QByteArray& qml) {
        QQmlEngine engine;
        engine.setNetworkAccessManagerFactory(&factory_);
        engine.addImportPath(QStringLiteral(MELO_QML_SRC));
        QQmlComponent c(&engine);
        c.setData(qml, QUrl::fromLocalFile(QStringLiteral(MELO_QML_SRC "/components/test.qml")));
        if (!c.isReady()) qWarning() << c.errors();
        QQuickWindow win;
        g_requests = 0;
        QObject* o = c.create();
        if (!o) return -1;
        if (auto* it = qobject_cast<QQuickItem*>(o)) it->setParentItem(win.contentItem());
        win.resize(400, 100);
        win.show();
        // the image loader is asynchronous: give it time to ask
        QTest::qWait(400);
        const int n = g_requests;
        delete o;
        return n;
    }

private slots:
    void imgTagFetchesNothing() {
        // the channel-name case: a quote closes nothing, the tag still parses as one
        const QByteArray title = "text: '\"><img src=\"http://example.invalid/p.png\"> title'";
        QVERIFY2(requestsFor("import QtQuick\nText { " + title + " }") > 0, "the control fetches the picture");
        QCOMPARE(requestsFor("import QtQuick\nimport \".\"\nInkText { " + title + " }"), 0);
        QCOMPARE(requestsFor("import QtQuick\nimport \".\"\nScrollText { " + title + " }"), 0);
        QCOMPARE(requestsFor("import QtQuick\nimport \".\"\nSkeletonValue { " + title + " }"), 0);
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    TstPlainText t;
    return QTest::qExec(&t, argc, argv);
}

#include "tst_plaintextfetch.moc"
