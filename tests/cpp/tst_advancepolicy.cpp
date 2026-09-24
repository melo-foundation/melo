#include <QtTest>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QSignalSpy>
#include <gst/gst.h>
#include <memory>

#include "AudioEngine.h"
#include "MeloUi.h"
#include "PcmQueue.h"
#include "PlaybackCoordinator.h"
#include "PlayerState.h"
#include "QueueModel.h"
#include "SettingsStore.h"
#include "SidecarService.h"
#include "SuggestionsModel.h"

// Drives the real PlaybackCoordinator: shuffle and repeat live in advance(),
// shared by end-of-track and manual skip. SidecarService is never start()ed, so
// resolves never answer and tracks stop at "loading"; the tests assert which
// track was chosen.
class TestAdvancePolicy : public QObject {
    Q_OBJECT

    PcmQueue pcm_;
    std::unique_ptr<AudioEngine> engine_;
    SidecarService sidecar_;
    PlayerState state_;
    QueueModel queue_;
    SuggestionsModel suggestions_;
    std::unique_ptr<SettingsStore> settings_;
    std::unique_ptr<PlaybackCoordinator> coord_;

    // Every index playTrack actually landed on, in order. Recorded off
    // trackChanged because "nothing played" and "the same thing played again"
    // are different outcomes that currentIndex alone cannot tell apart.
    QList<int> plays_;

    void seedQueue(int n, int startIndex) {
        QJsonArray arr;
        for (int i = 0; i < n; ++i)
            arr.append(QJsonObject{{"id", QStringLiteral("t%1").arg(i)},
                                   {"title", QStringLiteral("Track %1").arg(i)},
                                   {"duration", 100.0}});
        plays_.clear();
        // Nothing up next unless a row says so. suggestions_ is a fixture
        // member, so an autoplay track set by one test would survive into
        // every test after it and turn "the queue is exhausted, stop" into
        // "the queue is exhausted, play the leftover autoplay".
        suggestions_.set({}, Track());
        state_.setShuffle(false);
        state_.setRepeat(0);
        coord_->playQueue(arr, startIndex);
        plays_.clear();   // the seeding play is not an advance
    }

    // Stands in for "the track finished playing". The headless slow path
    // leaves loading set (no sidecar answers the resolve) and onTrackEnded
    // bails while loading, so clear it first, then fire the engine's real
    // trackEnded — the signal the coordinator is actually connected to.
    void endOfTrack() {
        state_.setLoading(false);
        QVERIFY(QMetaObject::invokeMethod(engine_.get(), "trackEnded"));
    }

    void manualNext() { state_.setLoading(false); coord_->next(); }

private slots:
    // Song radio opens with the song it was started from — see
    // PlaybackCoordinator::seedFirst. Pure list surgery, so it is driven
    // directly rather than through a sidecar that never answers.
    void seedIsAlwaysFirst() {
        const auto mk = [](const QString& id) { Track t; t.id = id; return t; };

        // already first: nothing moves
        QList<Track> a{mk("seed"), mk("b"), mk("c")};
        int startA = 0;
        PlaybackCoordinator::seedFirst(a, startA, "seed", {});
        QCOMPARE(a.size(), 3);
        QCOMPARE(a.at(0).id, QString("seed"));
        QCOMPARE(startA, 0);

        // buried in the mix: moved to the front, not duplicated
        QList<Track> b{mk("x"), mk("y"), mk("seed"), mk("z")};
        int startB = 2;
        PlaybackCoordinator::seedFirst(b, startB, "seed", {});
        QCOMPARE(b.size(), 4);
        QCOMPARE(b.at(0).id, QString("seed"));
        QCOMPARE(b.count(mk("seed")), 1);
        QCOMPARE(startB, 0);

        // absent: the playing track stands in for it
        QList<Track> c{mk("x"), mk("y")};
        int startC = 0;
        PlaybackCoordinator::seedFirst(c, startC, "seed", mk("seed"));
        QCOMPARE(c.size(), 3);
        QCOMPARE(c.at(0).id, QString("seed"));
        QCOMPARE(startC, 0);

        // absent AND unknown: left exactly as it came
        QList<Track> d{mk("x"), mk("y")};
        int startD = 1;
        PlaybackCoordinator::seedFirst(d, startD, "seed", mk("other"));
        QCOMPARE(d.size(), 2);
        QCOMPARE(d.at(0).id, QString("x"));
        QCOMPARE(startD, 1);

        // no seed at all (a mix, not a song radio): untouched
        QList<Track> e{mk("x")};
        int startE = 0;
        PlaybackCoordinator::seedFirst(e, startE, QString(), mk("x"));
        QCOMPARE(e.size(), 1);
        QCOMPARE(startE, 0);
    }

    void initTestCase() {
        qputenv("MELO_FAKE_SINK", "1");
        gst_init(nullptr, nullptr);
        engine_ = std::make_unique<AudioEngine>(pcm_);
        settings_ = std::make_unique<SettingsStore>(&sidecar_);
        coord_ = std::make_unique<PlaybackCoordinator>(engine_.get(), &sidecar_, &state_,
                                                       &queue_, &suggestions_, settings_.get());
        connect(&state_, &PlayerState::trackChanged, this,
                [this] { plays_.append(queue_.currentIndex()); });
    }

    void cleanupTestCase() { coord_.reset(); settings_.reset(); engine_.reset(); }

    // An autoplay track is played, not appended: appending would let one
    // suggestion grow the user's queue with tracks they never chose.
    void autoplayPlaysWithoutBuildingAQueue() {
        seedQueue(2, 1);                       // the last row
        suggestions_.set({}, Track::fromJson(QJsonObject{
            {"id", QStringLiteral("auto1")},
            {"title", QStringLiteral("Up next")},
            {"duration", 100.0}}));
        const int before = queue_.count();

        endOfTrack();                          // the queue is now exhausted

        QCOMPARE(state_.currentTrack().id, QStringLiteral("auto1"));
        QCOMPARE(queue_.count(), before);      // ...and nothing was added to it
    }

    // The manual path has the same branch: advance() and next() share a code
    // path so one rule covers both.
    void manualNextIntoAutoplayAlsoQueuesNothing() {
        seedQueue(2, 1);
        suggestions_.set({}, Track::fromJson(QJsonObject{
            {"id", QStringLiteral("auto2")},
            {"title", QStringLiteral("Up next")},
            {"duration", 100.0}}));
        const int before = queue_.count();

        manualNext();

        QCOMPARE(state_.currentTrack().id, QStringLiteral("auto2"));
        QCOMPARE(queue_.count(), before);
    }

    // repeat=off: the queue ends and playback stops. Not "wraps quietly", not
    // "replays the last track" — nothing plays at all.
    void repeatOffStopsAtTheEnd() {
        seedQueue(3, 0);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 1);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 2);
        QCOMPARE(plays_, (QList<int>{1, 2}));

        endOfTrack();                       // past the last item
        QCOMPARE(queue_.currentIndex(), 2);
        QCOMPARE(plays_.size(), 2);         // nothing new played
    }

    void repeatAllWrapsPastTheEnd() {
        seedQueue(3, 2);
        state_.setRepeat(2);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 0);
        QCOMPARE(plays_, (QList<int>{0}));
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 1);
    }

    // repeat=one at end-of-track: the SAME index plays again. currentIndex
    // staying put is only half the claim — a stall would look identical — so
    // the play log has to grow.
    void repeatOneReplaysTheSameIndexAtEndOfTrack() {
        seedQueue(3, 1);
        state_.setRepeat(1);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 1);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 1);
        QCOMPARE(plays_, (QList<int>{1, 1}));
    }

    // A user pressing next means next; repeat-one is about what happens when
    // a track ENDS. Put the policy in next() and the two paths diverge; put it
    // only in advance() without an override and the skip button dies while
    // repeat-one is on.
    void manualNextOverridesRepeatOneButLeavesItInForce() {
        seedQueue(3, 0);
        state_.setRepeat(1);

        manualNext();
        QCOMPARE(queue_.currentIndex(), 1);      // the button moved on
        manualNext();
        QCOMPARE(queue_.currentIndex(), 2);
        QCOMPARE(plays_, (QList<int>{1, 2}));

        // ...and the mode was overridden for that press only, not cancelled.
        QCOMPARE(state_.repeat(), 1);
        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 2);
        QCOMPARE(plays_, (QList<int>{1, 2, 2}));
    }

    // Playing a search result seeds no queue rows, so there is no
    // index for repeat-one to return to — and "repeat this track" must still
    // mean something. Index-only policy silently does nothing here.
    void repeatOneReplaysAQueuelessTrack() {
        state_.setShuffle(false);
        state_.setRepeat(1);
        plays_.clear();
        coord_->playTrackData(QJsonObject{{"id", QStringLiteral("solo")},
                                          {"title", QStringLiteral("Solo")}});
        QCOMPARE(queue_.count(), 0);
        plays_.clear();

        endOfTrack();
        QCOMPARE(plays_.size(), 1);
        QCOMPARE(state_.currentTrack().id, QStringLiteral("solo"));
        endOfTrack();
        QCOMPARE(plays_.size(), 2);
    }

    // repeat-all is NOT overridden by a manual press: Winamp wraps on the next
    // button too. Only repeat-one is special, because only repeat-one would
    // make the button do nothing.
    void manualNextStillWrapsUnderRepeatAll() {
        seedQueue(3, 2);
        state_.setRepeat(2);
        manualNext();
        QCOMPARE(queue_.currentIndex(), 0);
    }

    // shuffle draws from a pool of not-yet-played indices, so every track gets
    // played once before any is heard twice.
    void shufflePlaysEveryIndexOnceBeforeAnyRepeats() {
        seedQueue(8, 0);
        state_.setShuffle(true);

        for (int i = 0; i < 7; ++i) endOfTrack();

        QCOMPARE(plays_.size(), 7);
        QSet<int> seen(plays_.begin(), plays_.end());
        seen.insert(0);                      // the seeded track counts as played
        QCOMPARE(seen.size(), 8);            // all eight, none twice
        QVERIFY(!plays_.contains(0));        // and never back to where it started
    }

    // Exhaustion is resolved by the repeat mode in force: with repeat off the
    // pool runs out and playback stops, exactly as an unshuffled queue would.
    void shuffleWithRepeatOffStopsWhenThePoolIsExhausted() {
        seedQueue(4, 0);
        state_.setShuffle(true);

        for (int i = 0; i < 3; ++i) endOfTrack();
        QCOMPARE(plays_.size(), 3);

        endOfTrack();
        QCOMPARE(plays_.size(), 3);          // pool empty, repeat off -> stop
    }

    // The two modes compose. Same shuffle, different repeat, different
    // behaviour: the pool refills and a fresh lap starts, forever.
    void shuffleWithRepeatAllReshufflesForever() {
        seedQueue(4, 0);
        state_.setShuffle(true);
        state_.setRepeat(2);

        for (int i = 0; i < 11; ++i) endOfTrack();
        QCOMPARE(plays_.size(), 11);         // never stalled

        // First lap: the three indices the seeded track left unplayed.
        QSet<int> lap1(plays_.begin(), plays_.begin() + 3);
        lap1.insert(0);
        QCOMPARE(lap1.size(), 4);

        // and a reshuffle never hands back the track that just finished
        for (int i = 1; i < plays_.size(); ++i) QVERIFY(plays_[i] != plays_[i - 1]);
        QVERIFY(plays_[0] != 0);
    }

    // Turning shuffle on starts a fresh pool. Without this, enabling shuffle
    // late in a queue inherits whatever the coordinator happened to remember.
    void enablingShuffleStartsAFreshPool() {
        seedQueue(4, 0);
        state_.setShuffle(true);
        for (int i = 0; i < 3; ++i) endOfTrack();
        QCOMPARE(plays_.size(), 3);

        state_.setShuffle(false);
        state_.setShuffle(true);
        endOfTrack();
        QCOMPARE(plays_.size(), 4);          // pool was refilled, not exhausted
    }

    // --- prefetch agrees with advance -----------------------------------

    // Prefetch asks for the next track a track early, so the shuffle draw is
    // made once and held; a fresh draw would rarely match advance()'s pick and
    // lose the crossfade.
    void theShuffleDrawIsHeldUntilItIsPlayed() {
        seedQueue(8, 0);
        state_.setShuffle(true);

        const int drawn = coord_->upcomingIndex(true);
        QVERIFY(drawn > 0);
        for (int i = 0; i < 6; ++i)          // the prefetcher, asking repeatedly
            QCOMPARE(coord_->upcomingIndex(true), drawn);

        endOfTrack();
        QCOMPARE(queue_.currentIndex(), drawn);   // ...and that is what played
        QCOMPARE(plays_, (QList<int>{drawn}));

        // consumed: the next question is a new draw, not the spent one
        const int again = coord_->upcomingIndex(true);
        QVERIFY(again != drawn);
        QVERIFY(again != 0);                 // and never a row already played
    }

    // A held draw must not outlive the queue it was made against, or the
    // prefetcher gets an index that no longer names the row it named.
    void aHeldDrawIsDroppedWhenTheQueueChangesUnderIt() {
        seedQueue(3, 0);
        state_.setShuffle(true);
        QVERIFY(coord_->upcomingIndex(true) > 0);

        coord_->removeFromQueue(2);           // renumbers
        const int after = coord_->upcomingIndex(true);
        QVERIFY(after >= 0);
        QVERIFY(after < queue_.count());      // never points past the queue
        QVERIFY(after != queue_.currentIndex());
    }

    // Under repeat-one the upcoming index IS the current one, so prefetch's
    // same-track guard suppresses the prefetch. Without this, melo would
    // re-resolve the looping track once per pass for a stream it already has.
    void repeatOneMakesTheUpcomingIndexTheCurrentOne() {
        seedQueue(3, 1);
        state_.setRepeat(1);
        QCOMPARE(coord_->upcomingIndex(true), 1);      // == currentIndex
        QCOMPARE(coord_->upcomingIndex(false), 2);     // the skip button still moves
    }

    // --- pool integrity across queue replacement ------------------------

    // playSuggestion clears the queue. Marks left behind would then
    // apply to whatever rows land next, silently skipping them for a lap.
    void playingASuggestionStartsTheNextQueueWithAFreshPool() {
        seedQueue(4, 0);
        state_.setShuffle(true);
        for (int i = 0; i < 3; ++i) endOfTrack();     // exhaust the lap
        QCOMPARE(plays_.size(), 3);

        suggestions_.set({Track{QStringLiteral("sug"), QStringLiteral("Suggested"), {}, 0, {}, {}}}, Track{});
        state_.setLoading(false);
        coord_->playSuggestion(0);
        QCOMPARE(queue_.count(), 0);

        QJsonArray fresh;
        for (int i = 0; i < 4; ++i)
            fresh.append(QJsonObject{{"id", QStringLiteral("n%1").arg(i)},
                                     {"title", QStringLiteral("New %1").arg(i)}});
        coord_->addToQueue(fresh);                    // seeds row 0 with "sug"
        QCOMPARE(queue_.count(), 5);
        plays_.clear();

        for (int i = 0; i < 4; ++i) endOfTrack();
        // Carrying the old marks over would leave only row 4 drawable and stop
        // after one; a fresh pool reaches all four new rows.
        QCOMPARE(plays_.size(), 4);
        QSet<int> seen(plays_.begin(), plays_.end());
        QCOMPARE(seen, (QSet<int>{1, 2, 3, 4}));
    }

    // Queueing a track does not raise the panel over whatever is on screen;
    // it follows the add only when the panel is already up.
    void addToQueueDoesNotRaiseThePanel() {
        seedQueue(2, 0);
        state_.setShowPanel(false);
        QJsonArray one{QJsonObject{{"id", QStringLiteral("q1")}, {"title", QStringLiteral("Q1")}}};
        coord_->addToQueue(one);
        QVERIFY(!state_.showPanel());

        state_.setShowPanel(true);
        state_.setPanelMode(PlayerState::Suggestions);
        coord_->addToQueue(one);
        QVERIFY(state_.showPanel());
        QCOMPARE(state_.panelMode(), PlayerState::Queue);
    }

    // Reordering renumbers the rows, so the playing row has to be tracked
    // through the move rather than left pointing at whatever lands there.
    void reorderQueueKeepsThePlayingRow() {
        seedQueue(4, 1);                     // playing row 1
        const QString playing = queue_.at(1).id;

        coord_->reorderQueue(3, 0);          // below the playing row -> above it
        QCOMPARE(queue_.currentIndex(), 2);
        QCOMPARE(queue_.at(2).id, playing);

        coord_->reorderQueue(0, 3);          // above the playing row -> below it
        QCOMPARE(queue_.currentIndex(), 1);
        QCOMPARE(queue_.at(1).id, playing);

        coord_->reorderQueue(1, 3);          // drag the playing row itself
        QCOMPARE(queue_.currentIndex(), 3);
        QCOMPARE(queue_.at(3).id, playing);
    }

    // Play Next lands after the playing row, and a batch keeps its order —
    // each insert goes to the same slot, so a forward walk would reverse it.
    void playNextLandsAfterTheCurrentRow() {
        seedQueue(4, 1);                     // playing row 1
        const QString after = queue_.at(2).id;

        QJsonArray two;
        for (const auto& id : {"n0", "n1"})
            two.append(QJsonObject{{"id", QString(id)}, {"title", QString(id)}});
        coord_->playNext(two);

        QCOMPARE(queue_.count(), 6);
        QCOMPARE(queue_.currentIndex(), 1);          // the playing row did not move
        QCOMPARE(queue_.at(2).id, QStringLiteral("n0"));
        QCOMPARE(queue_.at(3).id, QStringLiteral("n1"));
        QCOMPARE(queue_.at(4).id, after);            // what followed still follows
    }

    // --- radio ----------------------------------------------------------

    // Radio tops the queue up on every advance so it never runs dry.
    // repeat-one never consumes a row, so left in it would append one track
    // per track-length, forever. Headlessly the append is an RPC that never
    // answers, so the suppression is visible as "the replay happened at all".
    void repeatOneSuppressesTheRadioTopUp() {
        seedQueue(3, 1);
        state_.setRepeat(1);
        state_.setRadioActive(true);

        endOfTrack();
        QCOMPARE(queue_.currentIndex(), 1);
        QCOMPARE(plays_, (QList<int>{1}));   // replayed, not parked on an RPC

        // ...and under any other repeat mode the radio branch still runs,
        // which is what makes the assertion above about repeat-one and not
        // about radio being broken in this harness.
        state_.setRepeat(2);
        plays_.clear();
        endOfTrack();
        QCOMPARE(plays_.size(), 0);          // waiting on radio/next, as designed

        state_.setRadioActive(false);
    }

    // --- bridge surface -------------------------------------------------

    // MeloUiPlayer aggregates PlayerState into ONE changed(); a property whose
    // signal was never connected reads correctly once and then lies forever,
    // which in QML is a binding that never updates.
    void bridgeExposesBothModesAndNotifies() {
        MeloUiPlayer player(&state_, coord_.get());
        state_.setShuffle(false);
        state_.setRepeat(0);

        QSignalSpy spy(&player, &MeloUiPlayer::changed);
        state_.setShuffle(true);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(player.shuffle(), true);

        state_.setRepeat(2);
        QCOMPARE(spy.count(), 2);
        QCOMPARE(player.repeat(), 2);
    }

    // MeloUi is the plugin-facing attack surface: a skin's repeat button is
    // plugin code, and it drives this as an index. Out of range is clamped
    // here, the same way seek() and setBalance() already are.
    void bridgeClampsRepeatAndRoundTripsShuffle() {
        MeloUiPlayer player(&state_, coord_.get());

        player.setRepeat(1);
        QCOMPARE(state_.repeat(), 1);
        player.setRepeat(99);
        QCOMPARE(state_.repeat(), 2);
        player.setRepeat(-7);
        QCOMPARE(state_.repeat(), 0);

        player.setShuffle(true);
        QCOMPARE(state_.shuffle(), true);
        player.setShuffle(false);
        QCOMPARE(state_.shuffle(), false);
    }

    void init() {
        coord_->setInterceptOffer({});
        coord_->setInterceptOccupied({});
    }

    void swallowedNextDoesNotAdvance() {
        seedQueue(3, 0);
        QStringList offered;
        coord_->setInterceptOffer([&](const QString& a) {
            offered.append(a);
            return a == QStringLiteral("next");
        });
        manualNext();
        QCOMPARE(offered, QStringList{QStringLiteral("next")});
        QCOMPARE(queue_.currentIndex(), 0);
        QCOMPARE(plays_.size(), 0);
    }
    void eosDoesNotOfferNext() {
        seedQueue(3, 0);
        QStringList offered;
        coord_->setInterceptOffer([&](const QString& a) {
            offered.append(a);
            return true;
        });
        endOfTrack();
        QVERIFY(!offered.contains(QStringLiteral("next")));
        QVERIFY(!offered.contains(QStringLiteral("play")));
        QCOMPARE(queue_.currentIndex(), 1);
    }
    void swallowedPauseLeavesPlayingFlag() {
        // Headless: force a playing+not-loading state the bar would have.
        state_.setLoading(false);
        engine_->setPaused(false);
        state_.setIsPlaying(true);
        bool offeredPause = false;
        coord_->setInterceptOffer([&](const QString& a) {
            offeredPause = a == QStringLiteral("pause");
            return true;
        });
        coord_->togglePlay();
        QVERIFY(offeredPause);
        QVERIFY(state_.isPlaying());   // builtin did not run
    }
};
QTEST_MAIN(TestAdvancePolicy)
#include "tst_advancepolicy.moc"
