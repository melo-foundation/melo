#include <QtTest>
#include <QFile>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <gst/gst.h>
#include "VideoDeck.h"

// Serves one directory over HTTP/1.1 with byte ranges, on its own thread: a
// pull-mode demuxer may read from inside a seek on the calling thread.
class RangeServer : public QThread {
public:
    explicit RangeServer(QString dir) : dir_(std::move(dir)) {}
    ~RangeServer() override { quit(); wait(); }
    quint16 port() { ready_.acquire(); ready_.release(); return port_; }
    QAtomicInt delayMs;   // the next response waits this long

protected:
    void run() override {
        QTcpServer server;
        server.listen(QHostAddress::LocalHost);
        port_ = server.serverPort();
        QObject::connect(&server, &QTcpServer::newConnection, [&] {
            while (QTcpSocket* sock = server.nextPendingConnection()) {
                auto* buf = new QByteArray;
                QObject::connect(sock, &QTcpSocket::disconnected, sock, [sock, buf] {
                    delete buf; sock->deleteLater();
                });
                QObject::connect(sock, &QTcpSocket::readyRead, sock, [this, sock, buf] {
                    buf->append(sock->readAll());
                    int end;
                    while ((end = buf->indexOf("\r\n\r\n")) >= 0) {
                        const QByteArray head = buf->left(end);
                        buf->remove(0, end + 4);
                        answer(sock, head);
                    }
                });
            }
        });
        ready_.release();
        exec();
    }

private:
    void answer(QTcpSocket* sock, const QByteArray& head) {
        if (const int d = delayMs.fetchAndStoreRelaxed(0)) QThread::msleep(d);
        const QList<QByteArray> lines = head.split('\n');
        const QList<QByteArray> req = lines.value(0).trimmed().split(' ');
        const QByteArray method = req.value(0), path = req.value(1);
        QFile f(dir_ + QString::fromUtf8(path));
        if (!f.open(QIODevice::ReadOnly)) {
            sock->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            return;
        }
        const qint64 size = f.size();
        qint64 from = 0, to = size - 1;
        bool ranged = false;
        for (const QByteArray& l : lines) {
            const QByteArray t = l.trimmed();
            if (!t.toLower().startsWith("range: bytes=")) continue;
            const QList<QByteArray> ab = t.mid(13).split('-');
            from = ab.value(0).toLongLong();
            if (!ab.value(1).isEmpty()) to = qMin(ab.value(1).toLongLong(), size - 1);
            ranged = true;
        }
        if (from >= size) {
            sock->write(QByteArray("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */")
                        + QByteArray::number(size) + "\r\nContent-Length: 0\r\n\r\n");
            return;
        }
        QByteArray out = ranged ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
        out += "Accept-Ranges: bytes\r\nContent-Type: video/mp4\r\nContent-Length: "
             + QByteArray::number(to - from + 1) + "\r\n";
        if (ranged)
            out += "Content-Range: bytes " + QByteArray::number(from) + "-" + QByteArray::number(to)
                 + "/" + QByteArray::number(size) + "\r\n";
        out += "\r\n";
        sock->write(out);
        if (method != "GET") return;
        f.seek(from);
        // 1.6 MB/s, faster than the clip plays: a seek ahead fetches its range
        auto body = std::make_shared<QByteArray>(f.read(to - from + 1));
        auto* timer = new QTimer(sock);
        QObject::connect(timer, &QTimer::timeout, sock, [sock, body, timer] {
            sock->write(body->left(16384));
            body->remove(0, 16384);
            if (body->isEmpty()) timer->stop();
        });
        timer->start(10);
    }

    QString dir_;
    quint16 port_ = 0;
    QSemaphore ready_;
};

// A real deck over a real file: frames arrive in order, a seek starts a new
// generation, the appsink queue pauses the decoder while nothing pulls.
class TstVideoDeck : public QObject {
    Q_OBJECT
    QTemporaryDir dir_;
    QString webm_;
    QString odd_;

    static bool have(const char* f) {
        GstElementFactory* e = gst_element_factory_find(f);
        if (e) gst_object_unref(e);
        return e != nullptr;
    }

    // `frames` of the ball pattern at 25 fps, w x h, VP8 in WebM
    static bool makeClip(const QString& path, int w, int h, int frames) {
        const QString launch = QStringLiteral(
            "videotestsrc num-buffers=%1 pattern=ball ! video/x-raw,width=%2,height=%3,framerate=25/1 "
            "! vp8enc deadline=1 ! webmmux ! filesink location=\"%4\"").arg(frames).arg(w).arg(h).arg(path);
        GError* err = nullptr;
        GstElement* p = gst_parse_launch(launch.toUtf8().constData(), &err);
        if (!p || err) return false;
        gst_element_set_state(p, GST_STATE_PLAYING);
        GstBus* bus = gst_element_get_bus(p);
        GstMessage* m = gst_bus_timed_pop_filtered(bus, 10 * GST_SECOND,
            GstMessageType(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        const bool eos = m && GST_MESSAGE_TYPE(m) == GST_MESSAGE_EOS;
        if (m) gst_message_unref(m);
        gst_object_unref(bus);
        gst_element_set_state(p, GST_STATE_NULL); gst_object_unref(p);
        return eos;
    }

private slots:
    void initTestCase() {
        gst_init(nullptr, nullptr);
        if (!have("vp8enc") || !have("webmmux") || !have("vp8dec") || !have("videotestsrc"))
            QSKIP("vp8enc/webmmux/vp8dec missing: cannot make a test clip");
        // pin vp8dec above hardware decoders so the fixture is I420
        if (GstPluginFeature* f = GST_PLUGIN_FEATURE(gst_element_factory_find("vp8dec"))) {
            gst_plugin_feature_set_rank(f, GST_RANK_PRIMARY + 1000);
            gst_object_unref(f);
        }
        webm_ = dir_.filePath("clip.webm");
        odd_ = dir_.filePath("odd.webm");
        QVERIFY(makeClip(webm_, 160, 90, 75));   // 3 s
        QVERIFY(makeClip(odd_, 161, 91, 10));
    }

    void framesArriveInOrderAndTheQueuePaces() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        QTRY_VERIFY_WITH_TIMEOUT(deck.hasFrame(), 5000);    // the preroll arrived while PAUSED
        deck.start();
        // consume at 0.5 s: frames at 0.48 or so, never later than the position
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.5)) && f->pts >= 0.4, 5000);
        QVERIFY(f->pts <= 0.52);
        QVERIFY(f->px && f->px->width == 160 && f->px->height == 90
                && f->px->format == VideoFormat::I420 && f->px->planes[0].stride >= 160);
        // not asking for 300 ms must not wedge anything: the decoder waits on
        // the appsink queue and resumes when the next frame is wanted
        QTest::qWait(300);
        const auto g = deck.frameAt(1.0);
        QVERIFY(g && g->pts > f->pts);
        // the decoder waited: only the queued handful is ready, not the whole clip
        const auto h = deck.frameAt(100.0);
        QVERIFY(h && h->pts - g->pts <= 0.8);
    }

    void anErrorIsReportedNotThrown() {
        VideoDeck deck("file:///nonexistent/clip.webm");
        QTRY_VERIFY_WITH_TIMEOUT(deck.failed(), 5000);
        QVERIFY(!deck.frameAt(1.0).has_value());
    }

    void aSeekBumpsTheGenerationAndLandsNearTheTarget() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        deck.start();
        QTRY_VERIFY_WITH_TIMEOUT(deck.frameAt(0.2).has_value(), 5000);
        const uint64_t g0 = deck.generation();
        QVERIFY(deck.seekTo(2.0));
        QCOMPARE(deck.generation(), g0 + 1);
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(2.1)) && f->gen == g0 + 1, 5000);
        QVERIFY(f->pts >= 1.9 && f->pts <= 2.12);
    }

    // A prerolled deck shows its first frame on the tick it starts.
    void aPrerolledDeckShowsAtOnceOnStart() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        QTRY_VERIFY_WITH_TIMEOUT(deck.hasFrame(), 5000);
        deck.start();
        const auto f = deck.frameAt(0.0);
        QVERIFY(f && f->pts < 0.1);
    }

    // A started deck that never showed keeps its preroll through a seek (the silence skip).
    void thePrerollHoldsThroughAnImmediateSeek() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        deck.start();                                         // started before the preroll: start() pulls nothing
        QTRY_VERIFY_WITH_TIMEOUT(deck.hasFrame(), 5000);      // a frame is possible; frameAt not called
        QVERIFY(deck.seekTo(2.0));                            // seekTo's own pull holds it
        const auto p = deck.frameAt(0.0);
        QVERIFY(p && p->pts < 0.1);
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(2.1)) && f->pts >= 1.9, 5000);
        QVERIFY(f->pts <= 2.12);
    }

    // A seek parked before start is never preceded by frame zero.
    void aParkedSeekNeverShowsFrameZero() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        QVERIFY(deck.seekTo(2.0));
        QTRY_VERIFY_WITH_TIMEOUT(deck.hasFrame(), 5000);
        deck.start();
        QElapsedTimer t; t.start();
        bool landed = false;
        while (!landed && t.elapsed() < 5000) {
            for (double pos : {0.0, 2.1}) {
                const auto f = deck.frameAt(pos);
                if (!f) continue;
                QVERIFY2(f->pts >= 1.9, qPrintable(QString::number(f->pts)));
                if (f->gen > 0) { landed = true; break; }
            }
            QTest::qWait(5);
        }
        QVERIFY(landed);
    }

    // A seek before the preroll is parked, not dropped: playback starts at
    // the target and the clip's opening never shows.
    void anEarlySeekIsNotLost() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        QVERIFY(deck.seekTo(2.0));
        deck.start();
        bool sawEarly = false;
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT(((f = deck.frameAt(2.1)) && (sawEarly |= f->pts < 1.0, true)
                                  && f->pts >= 1.9 && f->pts <= 2.12), 5000);
        QVERIFY(!sawEarly);
    }

    // Far behind the position (after a pause), the deck jumps instead of
    // fast-forwarding through the queue.
    void jumpsWhenFarBehind() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        deck.start();
        QTRY_VERIFY_WITH_TIMEOUT(deck.frameAt(0.3).has_value(), 5000);
        const uint64_t g0 = deck.generation();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(2.5)) && qAbs(f->pts - 2.5) <= 0.2, 5000);
        QCOMPARE(deck.generation(), g0 + 1);
    }

    // YouTube's MP4 is fragmented: the seek lands through a range request and the call returns at once.
    void seeksAFragmentedMp4OverHttp() {
        const char* enc = have("x264enc") ? "x264enc tune=zerolatency"
                        : have("av1enc") ? "av1enc cpu-used=8 usage-profile=realtime" : nullptr;
        if (!enc || !have("mp4mux") || !have("qtdemux") || !have("souphttpsrc"))
            QSKIP("x264enc/av1enc, mp4mux, qtdemux or souphttpsrc missing");
        QTemporaryDir dir;
        const QString mp4 = dir.filePath("clip.mp4");
        const QString launch = QStringLiteral(
            "videotestsrc num-buffers=250 pattern=snow ! video/x-raw,width=160,height=90,framerate=25/1 "
            "! %1 ! mp4mux fragment-duration=1000 ! filesink location=\"%2\"").arg(QLatin1String(enc), mp4);
        GError* err = nullptr;
        GstElement* p = gst_parse_launch(launch.toUtf8().constData(), &err);
        QVERIFY2(p && !err, err ? err->message : "parse failed");
        gst_element_set_state(p, GST_STATE_PLAYING);
        GstBus* bus = gst_element_get_bus(p);
        GstMessage* m = gst_bus_timed_pop_filtered(bus, 30 * GST_SECOND,
            GstMessageType(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        const bool eos = m && GST_MESSAGE_TYPE(m) == GST_MESSAGE_EOS;
        if (m) gst_message_unref(m);
        gst_object_unref(bus);
        gst_element_set_state(p, GST_STATE_NULL); gst_object_unref(p);
        QVERIFY(eos);

        RangeServer server(dir.path());
        server.start();
        {
            VideoDeck deck(QStringLiteral("http://127.0.0.1:%1/clip.mp4").arg(server.port()).toStdString());
            deck.start();
            QTRY_VERIFY_WITH_TIMEOUT(deck.frameAt(0.2).has_value(), 5000);
            server.delayMs.storeRelaxed(1500);
            QElapsedTimer t;
            t.start();
            QVERIFY(deck.seekTo(6.0));
            QVERIFY2(t.elapsed() < 50, qPrintable(QString::number(t.elapsed())));
            std::optional<VideoFrame> f;
            QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(6.1)) && f->pts >= 5.9 && f->pts <= 6.15, 8000);
        }
        VideoDeck::joinAllTeardowns();
    }

    // The frame is the decoder's own I420: three planes, chroma at half size,
    // BT.601 limited, the default for 576 lines or fewer with no colorimetry.
    void aPlanarFrameCarriesTheDecodersPlanes() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        deck.start();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.3)).has_value(), 5000);
        const VideoPixels& px = *f->px;
        QVERIFY(px.format == VideoFormat::I420);
        QCOMPARE(px.planeCount, 3);
        QCOMPARE(px.width, 160); QCOMPARE(px.height, 90);
        QCOMPARE(px.planes[0].width, 160); QCOMPARE(px.planes[0].height, 90);
        QVERIFY(px.planes[0].stride >= 160);
        QCOMPARE(px.planes[1].width, 80); QCOMPARE(px.planes[1].height, 45);
        QVERIFY(px.planes[1].stride >= 80);
        QCOMPARE(px.planes[2].width, 80); QCOMPARE(px.planes[2].height, 45);
        QVERIFY(px.planes[1].data != px.planes[0].data && px.planes[2].data != px.planes[1].data);
        QVERIFY(px.color.matrix == VideoMatrix::BT601);
        QVERIFY(!px.color.fullRange);
    }

    // Odd sizes: the chroma planes round up, as GStreamer lays them out.
    void anOddSizedFrameRoundsItsChromaUp() {
        VideoDeck deck(QUrl::fromLocalFile(odd_).toString().toStdString());
        deck.start();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.1)).has_value(), 5000);
        const VideoPixels& px = *f->px;
        QCOMPARE(px.width, 161); QCOMPARE(px.height, 91);
        QCOMPARE(px.planes[1].width, 81); QCOMPARE(px.planes[1].height, 46);
        QVERIFY(px.planes[1].stride >= 81);
    }

    // NV12 as a hardware decoder hands it over: Y, then one interleaved UV plane.
    void aPlanarNv12FrameCarriesTwoPlanes() {
        if (!have("testsrcbin")) QSKIP("testsrcbin missing: cannot make NV12 frames");
        VideoDeck deck("testbin://video,caps=[video/x-raw,format=NV12,width=161,height=91,framerate=25/1],"
                       "num-buffers=10");
        deck.start();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.1)).has_value(), 5000);
        const VideoPixels& px = *f->px;
        QVERIFY(px.format == VideoFormat::NV12);
        QCOMPARE(px.planeCount, 2);
        QCOMPARE(px.planes[0].width, 161); QCOMPARE(px.planes[0].height, 91);
        QCOMPARE(px.planes[1].width, 81); QCOMPARE(px.planes[1].height, 46);
        QVERIFY(px.planes[1].stride >= 162);
        const auto a = rgbaOf(f->px);
        QVERIFY(a && a->format == VideoFormat::RGBA);
        QCOMPARE(a->width, 161); QCOMPARE(a->height, 91);
        QCOMPARE(a->planes[0].stride, 644);
        QCOMPARE(a->planeCount, 1);
    }

    // The RGBA twin is videoconvert's output: tight, opaque, made once.
    void theRgbaTwinIsMadeOnceAndIsTight() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
        deck.start();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.3)).has_value(), 5000);
        const auto a = rgbaOf(f->px);
        QVERIFY(a);
        QVERIFY(a->format == VideoFormat::RGBA);
        QCOMPARE(a->width, 160); QCOMPARE(a->height, 90);
        QCOMPARE(a->planes[0].stride, 640);
        QVERIFY(rgbaOf(f->px) == a);
        const unsigned char* p = a->planes[0].data;
        bool lit = false;
        for (int i = 0; i < 160 * 90 * 4 && !lit; i += 4) lit = p[i] > 32 || p[i + 1] > 32 || p[i + 2] > 32;
        QVERIFY(lit);                 // the ball pattern is not black
        QCOMPARE(int(p[3]), 255);     // opaque
    }

    // Rgba output: videoconvert makes RGBA, planes[0] is it.
    void rgbaOutputStillGivesRgba() {
        VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString(), VideoDeck::Output::Rgba);
        deck.start();
        std::optional<VideoFrame> f;
        QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.3)).has_value(), 5000);
        QVERIFY(f->px->format == VideoFormat::RGBA);
        QCOMPARE(f->px->planeCount, 1);
        QVERIFY(f->px->planes[0].stride >= 640);
        QVERIFY(rgbaOf(f->px) == f->px);
    }

    // A frame held across a deck switch can still make its twin after the deck is gone.
    void theTwinOutlivesTheDeck() {
        std::shared_ptr<const VideoPixels> held;
        {
            VideoDeck deck(QUrl::fromLocalFile(webm_).toString().toStdString());
            deck.start();
            std::optional<VideoFrame> f;
            QTRY_VERIFY_WITH_TIMEOUT((f = deck.frameAt(0.3)).has_value(), 5000);
            held = f->px;
        }
        VideoDeck::joinAllTeardowns();
        const auto t = rgbaOf(held);
        QVERIFY(t && t->width == 160 && t->height == 90);
    }

    void cleanupTestCase() { VideoDeck::joinAllTeardowns(); }
};

QTEST_GUILESS_MAIN(TstVideoDeck)
#include "tst_videodeck.moc"
