#pragma once
#include <QObject>
#include <QPointF>
#include <QTimer>

// One idle clock for the whole app: any pointer, wheel or key event
// anywhere restarts it. 3 s of nothing is idle. A hover, or a move to where
// the pointer already is, is not input: Qt Quick re-sends those at rest.
class UiActivity : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    Q_PROPERTY(int idleAfterMs READ idleAfterMs WRITE setIdleAfterMs NOTIFY idleAfterMsChanged)
public:
    explicit UiActivity(QObject* parent = nullptr);
    bool idle() const { return idle_; }
    int idleAfterMs() const { return timer_.interval(); }
    void setIdleAfterMs(int ms);
    Q_INVOKABLE void wake();
    Q_INVOKABLE void setWindowCursorHidden(QObject* window, bool hidden);
signals:
    void idleChanged();
    void idleAfterMsChanged();
    // a key or a button press, sent before it wakes the clock
    void inputWoke();
protected:
    bool eventFilter(QObject* watched, QEvent* e) override;
private:
    QTimer timer_;
    bool idle_ = false;
    QPointF lastPointer_;
    bool hasPointer_ = false;
};
