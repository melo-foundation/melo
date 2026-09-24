#pragma once
#include "../vis/MeloEngineOnly.h"

#include <QColor>
#include <QQuickItem>

class QSGTextureProvider;

// A rectangle that blends with whatever is behind it through the pipeline blend
// state (QSGMaterialShader::updateGraphicsPipelineState), so it needs no
// backdrop texture.
//
//   invert    src = white, One-Minus-Dst-Color / Zero   ->  1 - dst
//   multiply  Dst-Color / Zero                          ->  src * dst
//   screen    One / One-Minus-Src-Color                 ->  src + dst(1-src)
//   darken    One / One, Min
//   lighten   One / One, Max
//   subtract  One / One, ReverseSubtract                ->  dst - src
//
// "difference" (|src - dst|) is unsupported: fixed-function blend has no abs.
class BlendItem : public QQuickItem {
    Q_OBJECT
public:
    // Melo's own QML only (see MeloEngineOnly.h): a mode like "invert" reads
    // the framebuffer, so in a plugin engine it would let plugin QML sample
    // what melo drew underneath, including another plugin's surface.
    void componentComplete() override {
        QQuickItem::componentComplete();
        meloEngineOwns(this, "BlendItem");
    }

    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
    Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY modeChanged)
    Q_PROPERTY(QQuickItem* source READ source WRITE setSource NOTIFY sourceChanged)
    // The source is COVERAGE: only its alpha is read, tinted by `color`. For a
    // glyph layer, whose RGB carries subpixel-antialiasing fringes that would
    // otherwise be multiplied through as colour and read as blur.
    Q_PROPERTY(bool maskOnly READ maskOnly WRITE setMaskOnly NOTIFY maskOnlyChanged)

    explicit BlendItem(QQuickItem* parent = nullptr);

    // The SOURCE colour. White is the identity for invert and multiply, so it
    // is the default: a BlendRect with no colour set inverts cleanly.
    QColor color() const { return color_; }
    void setColor(const QColor& c);

    // One of the names above. An unknown name draws nothing rather than
    // guessing, and says so once — a themed value that does not exist should
    // not silently become "normal" and look like it worked.
    QString mode() const { return mode_; }
    void setMode(const QString& m);

    // Whether a name is one this can actually do. Exposed so the settings UI
    // and ThemeStore agree with the renderer instead of keeping their own list.
    Q_INVOKABLE static bool supportsMode(const QString& m);

    // Blend another item's rendered contents instead of a flat colour. Text
    // needs this: glyph materials' pipeline state cannot be changed, so render
    // the text to a texture and blend that:
    //
    //   Text { id: t; ... }
    //   ShaderEffectSource { id: tex; sourceItem: t; hideSource: true
    //                        live: true; visible: false }
    //   BlendRect { source: tex; mode: "invert"; anchors.fill: t }
    //
    // Costs one offscreen texture per blended item.
    QQuickItem* source() const { return source_; }
    void setSource(QQuickItem* item);
    bool maskOnly() const { return maskOnly_; }
    void setMaskOnly(bool on);

signals:
    void colorChanged();
    void modeChanged();
    void sourceChanged();
    void maskOnlyChanged();

protected:
    QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;

private:
    QColor color_ = Qt::white;
    QString mode_ = QStringLiteral("normal");
    QQuickItem* source_ = nullptr;
    bool maskOnly_ = false;
    // Both only ever touched on the render thread, in updatePaintNode.
    QSGTextureProvider* watched_ = nullptr;
    QMetaObject::Connection watchConn_;
};
