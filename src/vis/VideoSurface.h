#pragma once
#include "MeloEngineOnly.h"
#include "VideoFrameSource.h"
#include <QList>
#include <QQuickItem>
#include <QSize>
#include <QTimer>

// Draws the frame the engine selects for the audio position: NV12/I420 planes
// through VideoPlanesMaterial where the RHI can, RGBA through a texture node
// elsewhere (the software scene graph included).
class VideoSurface : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    Q_PROPERTY(bool frozen READ frozen WRITE setFrozen NOTIFY frozenChanged)
    Q_PROPERTY(bool hasFrame READ hasFrame NOTIFY hasFrameChanged)
    Q_PROPERTY(QSize frameSize READ frameSize NOTIFY hasFrameChanged)
    Q_PROPERTY(QString fit READ fit WRITE setFit NOTIFY fitChanged)   // "fill", "fit" or "stretch"
    Q_PROPERTY(qreal fillMix READ fillMix WRITE setFillMix NOTIFY fillMixChanged)   // 0 = the fit setting, 1 = fill
    Q_PROPERTY(QRectF contentRect READ contentRect NOTIFY contentRectChanged)   // the drawn picture
public:
    VideoSurface();
    ~VideoSurface() override;
    void componentComplete() override {
        QQuickItem::componentComplete();
        meloEngineOwns(this, "VideoSurface");
    }
    static void setSource(VideoFrameSource* s) { s_source = s; }
    static void notifyTrackChange();   // a frozen surface fetches once, on the source's change
#ifdef MELO_VIDEOSURFACE_TEST
    static int paintCount;
#endif

    bool running() const { return running_; }
    void setRunning(bool on);
    bool frozen() const { return frozen_; }
    void setFrozen(bool on);
    bool hasFrame() const { return hasFrame_; }
    QSize frameSize() const { return frameSize_; }
    QString fit() const { return fit_; }
    void setFit(const QString& fit);
    qreal fillMix() const { return fillMix_; }
    void setFillMix(qreal mix);
    QRectF contentRect() const { return contentRect_; }

signals:
    void runningChanged();
    void frozenChanged();
    void hasFrameChanged();
    void fitChanged();
    void fillMixChanged();
    void contentRectChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
    void itemChange(ItemChange change, const ItemChangeData& value) override;
    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;

private:
    void retick();
    void fetch();
    void dropPicture();
    static VideoFrameSource* s_source;
    static QList<VideoSurface*> s_live;
    QTimer tick_;
    bool running_ = false;
    bool frozen_ = false;
    bool hasFrame_ = false;
    bool dropNode_ = false;   // the next paint deletes the node
    QSize frameSize_;
    QString fit_ = QStringLiteral("fill");
    qreal fillMix_ = 0;
    QRectF contentRect_;
    void setContentRect(const QRectF& r);
    VideoView view_;          // what the last paint drew
    VideoView pending_;       // what the tick fetched for the next paint
    bool planar_ = false;                  // this window's RHI draws planes
    QQuickWindow* planarWindow_ = nullptr; // the window planar_ was decided for
};
