#pragma once
#include "MeloEngineOnly.h"
#include <QQuickFramebufferObject>
#include <QStringList>
#include <atomic>
#include <memory>

class PcmQueue;
struct VisEngine;

// QML item hosting projectM. projectM draws in a GL context of its own (shared
// with the windows', Qt::AA_ShareOpenGLContexts) and the Renderer copies its
// picture into the item's FBO, so it goes on as the item changes windows.
// Requires scenegraph on the OpenGL RHI backend.
class VisualizerItem : public QQuickFramebufferObject {
    Q_OBJECT
public:
    // Melo's own QML only — see MeloEngineOnly.h. `import Melo 1.0` resolves in
    // a plugin's engine because the type registry is process-global, so the
    // type has to refuse itself rather than rely on an import path that cannot
    // gate it.
    void componentComplete() override {
        QQuickFramebufferObject::componentComplete();
        meloEngineOwns(this, "VisualizerItem");
    }
    Q_PROPERTY(QStringList presetNames READ presetNames NOTIFY presetNamesChanged)
    Q_PROPERTY(QString currentPreset READ currentPreset NOTIFY currentPresetChanged)
public:
    VisualizerItem();
    ~VisualizerItem() override;
    Renderer* createRenderer() const override;
    // projectM instances built so far
    static int enginesBuilt() { return s_engines; }

    static void setPcmQueue(PcmQueue* q) { s_pcm = q; }

    Q_INVOKABLE void nextPreset() { nextPresetRequested_.store(true); }
    Q_INVOKABLE void prevPreset() { prevPresetRequested_.store(true); }
    Q_INVOKABLE void playPresetAt(int i) { presetIdxRequested_.store(i); }
    // live projectM settings from QML (GUI thread) -> applied on the render
    // thread on the next frame (settingsDirty_ latch; projectM API is not
    // thread-safe so it must be touched only in render()).
    Q_INVOKABLE void setBeatSensitivity(double s) { beatSensitivity_.store(s); settingsDirty_.store(true); }
    Q_INVOKABLE void setPresetDuration(double s)  { presetDuration_.store(s);  settingsDirty_.store(true); }
    Q_INVOKABLE void setShuffle(bool on)          { shuffle_.store(on);        settingsDirty_.store(true); }
    Q_INVOKABLE void setPresetLocked(bool on)     { presetLocked_.store(on);   settingsDirty_.store(true); }
    Q_INVOKABLE void setPlaying(bool on) {
        const bool was = playing_.exchange(on);
        if (on && !was) update();   // restart the loop the render thread stopped
    }

    // read by the renderer (render thread)
    // preset list for the config panel's search (renderer pushes it once —
    // the playlist lives render-thread-side)
    QStringList presetNames() const { return presetNames_; }
    Q_INVOKABLE void setPresetNames(const QStringList& names) {
        presetNames_ = names;
        emit presetNamesChanged();
    }

    QString currentPreset() const { return currentPreset_; }
    Q_INVOKABLE void setCurrentPresetIndex(int i) {   // renderer pushes on switch
        currentIndex_ = i;
        const QString name = presetNames_.value(i);
        if (name == currentPreset_) return;
        currentPreset_ = name;
        emit currentPresetChanged();
    }

    static PcmQueue* s_pcm;
    mutable std::atomic<bool> nextPresetRequested_{false};
    mutable std::atomic<bool> prevPresetRequested_{false};
    mutable std::atomic<int> presetIdxRequested_{-1};
    mutable std::atomic<bool> presetNamesSent_{false};
    mutable std::atomic<bool> settingsDirty_{true};
    mutable std::atomic<double> beatSensitivity_{1.0};
    mutable std::atomic<double> presetDuration_{30.0};
    mutable std::atomic<bool> shuffle_{true};
    mutable std::atomic<bool> presetLocked_{false};
    // Pump self-update() only while visible: Renderer::update() schedules window
    // frames, and a hidden visualizer committing at 60fps during a sibling's
    // interactive resize breaks KWin's commit/configure pairing.
    mutable std::atomic<bool> pumpOn_{true};
    // And whether there is anything to draw. With the music paused, visibility
    // alone would keep the window committing at 60fps on a still picture. QML
    // writes this from PlayerState; the pump needs both.
    std::atomic<bool> playing_{true};
    // the playlist index on screen; a projectM built for another window starts on it
    std::atomic<int> currentIndex_{-1};
    std::shared_ptr<VisEngine> engine_;
    static int s_engines;

signals:
    void presetNamesChanged();
    void currentPresetChanged();

protected:
    void itemChange(ItemChange change, const ItemChangeData& value) override;

private:
    QStringList presetNames_;
    QString currentPreset_;
};
