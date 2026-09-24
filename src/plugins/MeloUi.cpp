#include "MeloUi.h"
#include "PlayerState.h"
#include "PlaybackCoordinator.h"
#include "SidecarService.h"
#include "RpcClient.h"
#include "QueueModel.h"
#include "SuggestionsModel.h"
#include "SpectrumSource.h"

#include <QJsonObject>
#include <cstdio>
#include <utility>

MeloUiPlayer::MeloUiPlayer(PlayerState* state, PlaybackCoordinator* coord, QObject* parent)
    : QObject(parent), state_(state), coord_(coord) {
    if (!state_) return;
    // one `changed` for the whole facade: a skinned player redraws its display
    // wholesale anyway, and per-property signals would multiply the surface
    for (auto sig : { &PlayerState::trackChanged, &PlayerState::isPlayingChanged,
                      &PlayerState::positionChanged, &PlayerState::durationChanged,
                      &PlayerState::volumeChanged, &PlayerState::loadingChanged,
                      &PlayerState::balanceChanged, &PlayerState::shuffleChanged,
                      &PlayerState::repeatChanged })
        connect(state_, sig, this, &MeloUiPlayer::changed);
}

bool MeloUiPlayer::playing() const    { return state_ && state_->isPlaying(); }
bool MeloUiPlayer::loading() const    { return state_ && state_->loading(); }
double MeloUiPlayer::position() const { return state_ ? state_->position() : 0.0; }
double MeloUiPlayer::duration() const { return state_ ? state_->duration() : 0.0; }
QString MeloUiPlayer::title() const   { return state_ ? state_->trackTitle() : QString(); }
QString MeloUiPlayer::channel() const { return state_ ? state_->trackChannel() : QString(); }
bool MeloUiPlayer::hasTrack() const   { return state_ && state_->hasTrack(); }
double MeloUiPlayer::volume() const   { return state_ ? state_->volume() : 0.0; }
double MeloUiPlayer::balance() const  { return state_ ? state_->balance() : 0.0; }
bool MeloUiPlayer::shuffle() const    { return state_ && state_->shuffle(); }
int MeloUiPlayer::repeat() const      { return state_ ? state_->repeat() : 0; }

// play/pause are *Builtin guarded by the current state: asking for the
// state you are already in must be a no-op, or a plugin polling its skin's
// buttons would toggle playback under the user. Builtin, not the offering
// methods — otherwise a hello-intercept call-through loops.
void MeloUiPlayer::play()  { if (coord_ && !playing()) coord_->playBuiltin(); }
void MeloUiPlayer::pause() { if (coord_ && playing()) coord_->pauseBuiltin(); }
void MeloUiPlayer::stop()  { if (coord_) coord_->stopBuiltin(); }
void MeloUiPlayer::next()  { if (coord_) coord_->nextBuiltin(); }
void MeloUiPlayer::prev()  { if (coord_) coord_->previousBuiltin(); }
// Every input on this object is hostile by assumption, so seek is clamped
// exactly as setVolume is. PlaybackCoordinator::seek forwards to the engine
// unvalidated on the non-loading path; NaN or a large negative would reach it.
void MeloUiPlayer::seek(double seconds) {
    if (!coord_ || !qIsFinite(seconds)) return;
    double s = qMax(0.0, seconds);
    const double d = duration();          // 0 while a track is still resolving
    if (d > 0.0 && s > d) s = d;
    coord_->seek(s);
}
void MeloUiPlayer::setVolume(double v)  { if (coord_) coord_->setVolume(qBound(0.0, v, 1.0)); }
// Clamped and non-finite-rejected here as well as downstream: a skin's
// balance slider is plugin code and qBound(NaN) is not a clamp.
void MeloUiPlayer::setBalance(double v) {
    if (!coord_ || !qIsFinite(v)) return;
    coord_->setBalance(qBound(-1.0, v, 1.0));
}
void MeloUiPlayer::setShuffle(bool on) { if (state_) state_->setShuffle(on); }
// A skin's repeat button is plugin code driving an index, and
// an unrecognised mode would make advance() match no branch and stop the
// music, so it is clamped into the enum rather than stored as given.
void MeloUiPlayer::setRepeat(int mode) {
    if (state_) state_->setRepeat(qBound(int(PlayerState::RepeatOff), mode,
                                         int(PlayerState::RepeatAll)));
}

MeloUiSettings::MeloUiSettings(QString pluginId, SidecarService* sidecar, QObject* parent)
    : QObject(parent), id_(std::move(pluginId)), sidecar_(sidecar) {
    if (!sidecar_) return;
    // A refresh issued before the sidecar is up is lost (sendLine no-ops, and
    // RpcClient failAll()s pending calls on start), leaving `values` empty for
    // good. Re-issue a refresh the caller already asked for once it is ready.
    connect(sidecar_, &SidecarService::readyChanged, this, [this] {
        if (refreshWanted_ && sidecar_->ready()) refresh();
    });
}

QVariant MeloUiSettings::get(const QString& key) const { return values_.value(key); }

void MeloUiSettings::set(const QString& key, const QVariant& value) {
    const quint64 seq = nextSeq_++;
    pending_.insert(key, Pending{ seq, value });   // optimistic; the reply reconciles

    // No sidecar is a failed write, not a silent success: leaving the overlay
    // entry would show the plugin a value nothing ever stored.
    if (!sidecar_) { onWriteFailed(seq, key); return; }

    // The sidecar validates against the manifest schema and returns the whole
    // authoritative bag, so an out-of-schema write is corrected here rather
    // than left showing the plugin's own guess.
    auto* c = sidecar_->call(QStringLiteral("plugins/setSetting"),
                             QJsonObject{ {"id", id_}, {"key", key},
                                          {"value", QJsonValue::fromVariant(value)} });
    connect(c, &RpcCall::finished, this, [this, seq, key](const QJsonValue& r) {
        onWriteReply(seq, key, r.toObject());
    });
    // RpcClient emits `failed` on a 30s timeout and on sidecar death or restart
    // (failAll). Without this the optimistic write would sit in the overlay
    // forever with the sidecar down — never acked, never rolled back.
    connect(c, &RpcCall::failed, this, [this, seq, key](int, const QString&) {
        onWriteFailed(seq, key);
    });

    // recompute() last: it emits changed(), and a plugin writing from
    // onValuesChanged would otherwise send a later seq first. Every staleness
    // decision here assumes seq order is send order.
    recompute();
}

void MeloUiSettings::refresh() {
    // Cleared only when a bag actually arrives, so every failure below leaves
    // the request outstanding for the readyChanged hook to re-issue.
    refreshWanted_ = true;
    if (!sidecar_) {
        // Not recoverable — but not silent either. Empty `values` with no
        // diagnostic anywhere gives no one a reason to suspect the bridge.
        std::fprintf(stderr, "[melo] plugin %s: settings refresh with no sidecar — "
                             "values stays empty\n", id_.toUtf8().constData());
        return;
    }
    // Stamped at ISSUE, not at arrival: the reply carries the bag as the
    // sidecar had it when it processed this message, so it outranks replies to
    // writes sent before it and must yield to those sent after.
    const quint64 seq = nextSeq_++;
    auto* c = sidecar_->call(QStringLiteral("plugins/getSettings"),
                             QJsonObject{ {"id", id_} });
    connect(c, &RpcCall::finished, this, [this, seq](const QJsonValue& r) {
        const QJsonValue v = r.toObject().value(QStringLiteral("values"));
        if (!v.isObject()) {
            std::fprintf(stderr, "[melo] plugin %s: getSettings reply carried no values\n",
                         id_.toUtf8().constData());
            return;                       // still outstanding; a malformed reply is not an answer
        }
        refreshWanted_ = false;           // an empty bag IS an answer
        applyRemote(v.toObject().toVariantMap(), seq);
    });
    // Timeout, sidecar death, or failAll on (re)start. Nothing is pending on a
    // read, so there is nothing to roll back — the point is that the request
    // survives to be retried instead of disappearing.
    connect(c, &RpcCall::failed, this, [this](int, const QString& m) {
        std::fprintf(stderr, "[melo] plugin %s: settings refresh failed: %s\n",
                     id_.toUtf8().constData(), m.toUtf8().constData());
    });
}

void MeloUiSettings::onWriteReply(quint64 seq, const QString& key, const QJsonObject& reply) {
    // A reply without a well-formed `values` is not "the bag is empty" — the
    // sidecar returns {} for an id it cannot find, and a malformed reply must
    // never be read as an instruction to erase everything the plugin has.
    const QJsonValue v = reply.value(QStringLiteral("values"));
    if (v.isObject()) applyRemote(v.toObject().toVariantMap(), seq);
    // The ack is still an ack even when its bag is stale or unusable: this
    // write's own reply has arrived, so its overlay entry retires — unless a
    // newer write to the same key has already replaced it.
    const auto it = pending_.constFind(key);
    if (it != pending_.cend() && it->seq == seq) pending_.erase(it);
    recompute();
}

void MeloUiSettings::onWriteFailed(quint64 seq, const QString& key) {
    const auto it = pending_.constFind(key);
    if (it != pending_.cend() && it->seq == seq) pending_.erase(it);
    recompute();                          // key falls back to remote_, or vanishes
}

void MeloUiSettings::applyRemote(const QVariantMap& v, quint64 seq) {
    if (seq < lastRemoteSeq_) return;     // an older bag; a newer one already won
    remote_ = v;
    lastRemoteSeq_ = seq;
    recompute();
}

void MeloUiSettings::recompute() {
    QVariantMap merged = remote_;
    for (auto it = pending_.cbegin(); it != pending_.cend(); ++it)
        merged.insert(it.key(), it->value);
    if (merged == values_) return;
    values_ = std::move(merged);
    emit changed();
}

MeloUiQueue::MeloUiQueue(QueueModel* queue, PlaybackCoordinator* coord, QObject* parent)
    : QObject(parent), queue_(queue), coord_(coord) {
    if (!queue_) return;
    // one `changed` for both, same reason as MeloUiPlayer: a playlist window
    // re-reads the whole queue on any change anyway
    connect(queue_, &QueueModel::currentIndexChanged, this, &MeloUiQueue::changed);
    connect(queue_, &QueueModel::countChanged, this, &MeloUiQueue::changed);
    view_ = new MeloUiQueueView(queue_, this);
}

QObject* MeloUiQueue::model() const { return view_.data(); }   // null once the view is gone
int MeloUiQueue::currentIndex() const { return queue_ ? queue_->currentIndex() : -1; }
int MeloUiQueue::count() const { return queue_ ? queue_->count() : 0; }

// Every one of these is a coordinator call. QueueModel has its own
// removeAt/move/clear and they are the wrong door — they edit the list without
// telling the object that decides what plays next.
void MeloUiQueue::jumpTo(int i)            { if (coord_) coord_->jumpQueue(i); }
void MeloUiQueue::removeAt(int i)          { if (coord_) coord_->removeFromQueue(i); }
void MeloUiQueue::move(int from, int to)   { if (coord_) coord_->reorderQueue(from, to); }
void MeloUiQueue::clear()                  { if (coord_) coord_->clearQueue(); }

MeloUiSuggestions::MeloUiSuggestions(SuggestionsModel* suggestions,
                                     PlaybackCoordinator* coord, QObject* parent)
    : QObject(parent), suggestions_(suggestions), coord_(coord) {
    if (!suggestions_) return;
    connect(suggestions_, &SuggestionsModel::countChanged,
            this, &MeloUiSuggestions::changed);
    view_ = new MeloUiSuggestionsView(suggestions_, this);
}

QObject* MeloUiSuggestions::model() const { return view_.data(); }
int MeloUiSuggestions::count() const { return suggestions_ ? suggestions_->count() : 0; }
void MeloUiSuggestions::play(int i) { if (coord_) coord_->playSuggestion(i); }

MeloUiEq::MeloUiEq(PlaybackCoordinator* coord, QObject* parent)
    : QObject(parent), coord_(coord) {
    // melo's signal in, this facade's own signal out — so a plugin binding
    // updates when the EQ window or applyEqConfig moves the curve, not only
    // when the plugin itself does.
    if (coord_) connect(coord_, &PlaybackCoordinator::eqChanged, this, &MeloUiEq::changed);
}

// Read through to the engine. The flat fallback keeps the SHAPE stable when
// there is no coordinator: plugin QML indexes bands[0..9], and handing it an
// empty list turns a dead facade into an undefined-value crash.
QVariantList MeloUiEq::bands() const {
    if (coord_) return coord_->eqBands();
    return QVariantList{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
}

double MeloUiEq::preamp() const { return coord_ ? coord_->preamp() : 0.0; }

// qBound is not a clamp for NaN — qBound(-24.0, NaN, 12.0) returns -24.0, so
// without the isfinite check first, a skin's slider glitching to NaN would
// silently pin the band to full cut rather than being ignored. (std::clamp
// differs again: it returns the NaN.) Either way the value must be rejected.
void MeloUiEq::setBand(int index, double db) {
    if (index < 0 || index > 9 || !qIsFinite(db)) return;
    if (coord_) coord_->setEqBand(index, qBound(-24.0, db, 12.0));   // engine range
}

// Winamp's preamp travel. Same NaN reasoning as setBand.
void MeloUiEq::setPreamp(double db) {
    if (!qIsFinite(db)) return;
    if (coord_) coord_->setPreamp(qBound(-12.0, db, 12.0));
}

// src_ stays raw: SpectrumSource is a shell object no plugin can name, so
// nothing plugin-side can end its life early (the QPointers guard the reachable ones).
MeloUiSpectrum::MeloUiSpectrum(SpectrumSource* src, QObject* parent)
    : QObject(parent), src_(src) {
    // melo's signal in, this facade's own signal out. The plugin connects to
    // ours, so re-emitting ours reaches only plugin handlers.
    if (src_) connect(src_, &SpectrumSource::updated, this, &MeloUiSpectrum::updated);
}

QVariantList MeloUiSpectrum::bins() const { return src_ ? src_->bins() : QVariantList(); }
QVariantList MeloUiSpectrum::wave() const { return src_ ? src_->wave() : QVariantList(); }
int MeloUiSpectrum::binCount() const      { return src_ ? src_->binCount() : 0; }
int MeloUiSpectrum::waveCount() const     { return src_ ? src_->waveCount() : 0; }

MeloUiWindow::MeloUiWindow(QString id, PluginWindowBackend* backend, QObject* parent)
    : QObject(parent), id_(std::move(id)), backend_(backend) {}

int MeloUiWindow::x() const      { return backend_ ? backend_->pluginWindowRect(id_).x() : 0; }
int MeloUiWindow::y() const      { return backend_ ? backend_->pluginWindowRect(id_).y() : 0; }
int MeloUiWindow::width() const  { return backend_ ? backend_->pluginWindowRect(id_).width() : 0; }
int MeloUiWindow::height() const { return backend_ ? backend_->pluginWindowRect(id_).height() : 0; }
bool MeloUiWindow::visible() const { return backend_ && backend_->pluginWindowShown(id_); }
bool MeloUiWindow::shaded() const  { return backend_ && backend_->pluginWindowShaded(id_); }

void MeloUiWindow::show()        { if (backend_) backend_->setPluginWindowShown(id_, true); }
void MeloUiWindow::hide()        { if (backend_) backend_->setPluginWindowShown(id_, false); }
void MeloUiWindow::toggleShade() { if (backend_) backend_->togglePluginWindowShade(id_); }
void MeloUiWindow::startDrag()   { if (backend_) backend_->startPluginWindowDrag(id_); }
void MeloUiWindow::startResize() { if (backend_) backend_->startPluginWindowResize(id_); }
// id_ — never an argument. See the header: this is the whole reason a plugin
// cannot shape a window it does not own.
void MeloUiWindow::setShape(const QVariantList& polygons) {
    if (backend_) backend_->setPluginWindowShape(id_, polygons);
}

MeloUi::MeloUi(QString pluginId, QString pluginDir, PlayerState* state,
               PlaybackCoordinator* coord, SidecarService* sidecar,
               QueueModel* queue, SuggestionsModel* suggestions,
               SpectrumSource* spectrum, QObject* parent)
    : QObject(parent), id_(std::move(pluginId)), dir_(std::move(pluginDir)),
      player_(new MeloUiPlayer(state, coord, this)),
      settings_(new MeloUiSettings(id_, sidecar, this)),
      queue_(new MeloUiQueue(queue, coord, this)),
      suggestions_(new MeloUiSuggestions(suggestions, coord, this)),
      eq_(new MeloUiEq(coord, this)),
      spectrum_(new MeloUiSpectrum(spectrum, this)),
      app_(new MeloUiApp(this)) {
    // A getter rather than the settings object, so MeloUiArchives links without
    // the coordinator/sidecar world (tst_plugincontainment builds it).
    archives_ = new MeloUiArchives(
        id_,
        [s = QPointer<MeloUiSettings>(settings_)](const QString& key) -> QString {
            return s ? s->get(key).toString() : QString();
        },
        this);
    // The reload path. A `file` setting changes in three ways — melo's settings
    // page writes it, the plugin writes it, or a fetched bag corrects it — and
    // all three land as this one signal. Without it a plugin would go on drawing
    // the skin it opened at startup until it happened to call get() again.
    connect(settings_, &MeloUiSettings::changed, archives_,
            [this] { if (archives_) archives_->refresh(); });
}

void MeloUi::setSettingsSchema(const QJsonArray& settings) {
    if (archives_) archives_->setSchema(settings);
}

void MeloUi::setWindows(const QVariantMap& windows) {
    if (windows_ == windows) return;
    windows_ = windows;
    emit windowsChanged();
}
