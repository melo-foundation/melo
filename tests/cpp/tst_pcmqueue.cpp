#include <QtTest>
#include "PcmQueue.h"
#include <vector>

// The visualizer drains only while it is on screen. Everything here is about
// what happens to the audio that piles up while it is not.
class TstPcmQueue : public QObject {
    Q_OBJECT
    // one 10ms chunk at 48k stereo, tagged by its first sample so drained
    // chunks can be identified
    static std::vector<float> chunk(float tag) { return std::vector<float>(960, tag); }
    static std::vector<float> drainTags(PcmQueue& q) {
        std::vector<float> tags;
        q.drain([&](const float* d, std::size_t n) { QCOMPARE(n, std::size_t(960)); tags.push_back(d[0]); });
        return tags;
    }

private slots:
    void feedsEverythingWhenKeepingUp() {
        PcmQueue q;
        q.push(chunk(1).data(), 960);
        q.push(chunk(2).data(), 960);
        QCOMPARE(drainTags(q), (std::vector<float>{1, 2}));
    }

    // the lurch: hidden visualizer, queue at its cap, then one frame
    void dropsTheBacklogAndKeepsTheNewest() {
        PcmQueue q;
        for (int i = 1; i <= 200; ++i) q.push(chunk(float(i)).data(), 960);
        const auto tags = drainTags(q);
        QVERIFY2(tags.size() <= 4, "a frame must never be handed a backlog");
        QCOMPARE(tags.back(), 200.f);   // and what it does get is the live end
    }

    void drainEmptiesTheQueue() {
        PcmQueue q;
        q.push(chunk(1).data(), 960);
        drainTags(q);
        QCOMPARE(drainTags(q), std::vector<float>{});
    }
};
QTEST_MAIN(TstPcmQueue)
#include "tst_pcmqueue.moc"
