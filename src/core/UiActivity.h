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
public:
    explicit UiActivity(QObject* parent = nullptr);
    bool idle() const { return idle_; }
    void setIdleAfterMs(int ms);
    Q_INVOKABLE void wake();
    Q_INVOKABLE void setWindowCursorHidden(QObject* window, bool hidden);
signals:
    void idleChanged();
    // a key or a button press, sent before it wakes the clock
    void inputWoke();
    // a button press in any of the app's windows, before the window delivers it
    void windowPressed(QObject* window);
protected:
    bool eventFilter(QObject* watched, QEvent* e) override;
private:
    QTimer timer_;
    bool idle_ = false;
    QPointF lastPointer_;
    bool hasPointer_ = false;
};
