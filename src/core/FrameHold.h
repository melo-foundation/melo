#pragma once
#include <QEvent>
#include <QObject>
#include <QQuickWindow>
#include <QSet>
#include <QWindow>

// Held windows render nothing: every update request is refused, and one frame
// is asked for on release. PluginWindowHost holds windows through a grip
// resize the same way.
class FrameHold : public QObject {
public:
    using QObject::QObject;

    void hold(QWindow* w, bool on) {
        if (!w || on == held_.contains(w)) return;
        if (on) {
            held_.insert(w);
            w->installEventFilter(this);
            connect(w, &QObject::destroyed, this, [this, w] { held_.remove(w); });
            return;
        }
        held_.remove(w);
        w->removeEventFilter(this);
        disconnect(w, &QObject::destroyed, this, nullptr);
        // update(), not requestUpdate(): the basic loop swaps only a window it
        // has marked pending
        if (auto* q = qobject_cast<QQuickWindow*>(w)) q->update();
        else w->requestUpdate();
    }
    bool isHeld(const QWindow* w) const { return held_.contains(const_cast<QWindow*>(w)); }

protected:
    bool eventFilter(QObject* watched, QEvent* event) override {
        if (event->type() == QEvent::UpdateRequest && held_.contains(watched)) return true;
        return QObject::eventFilter(watched, event);
    }

private:
    QSet<QObject*> held_;
};
