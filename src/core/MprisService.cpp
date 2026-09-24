#include "MprisService.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QRegularExpression>
#include <QUrl>
#include <QWindow>

#include "PlaybackCoordinator.h"
#include "PlayerState.h"

MprisService::MprisService(PlaybackCoordinator* player, PlayerState* state, QObject* parent)
    : QObject(parent), player_(player), state_(state) {
    new MprisRootAdaptor(this);
    auto* pa = new MprisPlayerAdaptor(this);

    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerService(QStringLiteral("org.mpris.MediaPlayer2.melo")))
        bus.registerService(QStringLiteral("org.mpris.MediaPlayer2.melo.instance%1")
                                .arg(QCoreApplication::applicationPid()));
    bus.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), this,
                       QDBusConnection::ExportAdaptors);

    // melo's own scrub, told to every remote. MPRIS requires Seeked for a
    // position change the client did not request; without it a controller's
    // slider stays where the last tick left it until the track changes.
    connect(player_, &PlaybackCoordinator::seeked, this, [pa](double seconds) {
        emit pa->Seeked(qlonglong(qMax(0.0, seconds) * 1000000.0));
    });

    // adaptors don't auto-emit PropertiesChanged — push on state changes
    connect(state_, &PlayerState::trackChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("Metadata"), metadata()}});
    });
    connect(state_, &PlayerState::durationChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("Metadata"), metadata()}});
    });
    auto pushStatus = [this, pa] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("PlaybackStatus"), pa->playbackStatus()}});
    };
    connect(state_, &PlayerState::isPlayingChanged, this, pushStatus);
    connect(state_, &PlayerState::volumeChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("Volume"), state_->volume()}});
    });
    connect(state_, &PlayerState::shuffleChanged, this, [this, pa] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("Shuffle"), pa->shuffle()}});
    });
    connect(state_, &PlayerState::repeatChanged, this, [this, pa] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"),
                          {{QStringLiteral("LoopStatus"), pa->loopStatus()}});
    });
}

// Shuffle and repeat over MPRIS. Plasma's media widget and KDE Connect write
// these into the same PlayerState the skin and melo's own UI read.
bool MprisPlayerAdaptor::shuffle() const { return s_->state()->shuffle(); }
void MprisPlayerAdaptor::setShuffle(bool on) { s_->state()->setShuffle(on); }

QString MprisPlayerAdaptor::loopStatus() const {
    switch (s_->state()->repeat()) {
        case PlayerState::RepeatOne: return QStringLiteral("Track");
        case PlayerState::RepeatAll: return QStringLiteral("Playlist");
        default: return QStringLiteral("None");
    }
}

// An unknown LoopStatus is dropped, not coerced: the spec enumerates exactly
// three values, and mapping anything else onto one of them would silently
// change the user's mode on a malformed write.
void MprisPlayerAdaptor::setLoopStatus(const QString& s) {
    if (s == QLatin1String("None")) s_->state()->setRepeat(PlayerState::RepeatOff);
    else if (s == QLatin1String("Track")) s_->state()->setRepeat(PlayerState::RepeatOne);
    else if (s == QLatin1String("Playlist")) s_->state()->setRepeat(PlayerState::RepeatAll);
}

QVariantMap MprisService::metadata() const {
    QVariantMap m;
    if (!state_->hasTrack()) return m;
    const Track t = state_->currentTrack();
    QString safe = t.id;
    safe.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9]")), QStringLiteral("_"));
    m[QStringLiteral("mpris:trackid")] =
        QVariant::fromValue(QDBusObjectPath(QStringLiteral("/org/melo/track/") + safe));
    if (state_->duration() > 0)
        m[QStringLiteral("mpris:length")] = qlonglong(state_->duration() * 1000000.0);
    if (!t.thumbnail.isEmpty()) {
        // library thumbnails are local paths — DBus consumers need file:// URLs
        const QString art = t.thumbnail.startsWith('/')
            ? QUrl::fromLocalFile(t.thumbnail).toString() : t.thumbnail;
        m[QStringLiteral("mpris:artUrl")] = art;
    }
    m[QStringLiteral("xesam:title")] = t.title;
    m[QStringLiteral("xesam:artist")] = QStringList{t.channel};
    return m;
}

void MprisService::propertiesChanged(const QString& iface, const QVariantMap& props) {
    QDBusMessage msg = QDBusMessage::createSignal(
        QStringLiteral("/org/mpris/MediaPlayer2"),
        QStringLiteral("org.freedesktop.DBus.Properties"),
        QStringLiteral("PropertiesChanged"));
    msg << iface << props << QStringList();
    QDBusConnection::sessionBus().send(msg);
}

// ---------------- root ----------------

void MprisRootAdaptor::Raise() {
    if (s_->window()) {
        s_->window()->show();
        s_->window()->requestActivate();
    }
}

void MprisRootAdaptor::Quit() { QCoreApplication::quit(); }

// ---------------- player ----------------

QString MprisPlayerAdaptor::playbackStatus() const {
    // "Stopped" after Stop(), not "Paused". A remote showing Paused offers
    // resume for a position melo has already thrown away, and MPRIS defines
    // Stopped as exactly this: a track is loaded and the position is 0.
    if (!s_->state()->hasTrack()) return QStringLiteral("Stopped");
    if (s_->state()->isPlaying()) return QStringLiteral("Playing");
    return s_->state()->position() <= 0.0 ? QStringLiteral("Stopped")
                                          : QStringLiteral("Paused");
}

double MprisPlayerAdaptor::volume() const { return s_->state()->volume(); }

void MprisPlayerAdaptor::setVolume(double v) {
    s_->player()->setVolume(qBound(0.0, v, 1.0));
}

qlonglong MprisPlayerAdaptor::position() const {
    return qlonglong(s_->state()->position() * 1000000.0);
}

void MprisPlayerAdaptor::Next() { s_->player()->next(); }
void MprisPlayerAdaptor::Previous() { s_->player()->previous(); }

void MprisPlayerAdaptor::Pause() {
    if (s_->state()->isPlaying()) s_->player()->togglePlay();
}

void MprisPlayerAdaptor::PlayPause() { s_->player()->togglePlay(); }

void MprisPlayerAdaptor::Stop() { s_->player()->stop(); }

void MprisPlayerAdaptor::Play() {
    if (!s_->state()->isPlaying()) s_->player()->togglePlay();
}

void MprisPlayerAdaptor::Seek(qlonglong offsetUs) {
    const double target = s_->state()->position() + offsetUs / 1000000.0;
    s_->player()->seek(qMax(0.0, target));
    emit Seeked(qlonglong(qMax(0.0, target) * 1000000.0));
}

void MprisPlayerAdaptor::SetPosition(const QDBusObjectPath&, qlonglong positionUs) {
    const double target = positionUs / 1000000.0;
    s_->player()->seek(target);
    emit Seeked(positionUs);
}
