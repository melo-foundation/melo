#include <QJsonDocument>
#include <QJsonArray>
#include <utility>
#include <QRegularExpression>
#include <QXmlStreamReader>
#include "ThemeFormat.h"
#include <QJsonValue>
#include <QStringList>

namespace ThemeFormat {



static const char* kSurfaceRoles[] = {
    "window", "page", "chrome", "title", "player", "panel", "dialog", "menu", "card", "button", "input",
    "hover", "buttonHover", "buttonPress", "closeFace", "closeFaceHover", "selected", "cardSelected", "toast", "scrollbar", "tooltip", "skeleton", "panelHeader",
    "sliderTrack", "toggleOff", "buttonActive", "scrubberTrack",
};
// Floating over CONTENT rather than over the desktop: these keep an absolute
// opacity and ignore opacityScale, or a translucent theme would put the
// view's own text through the panel covering it.
static const char* kFloatingRoles[] = { "panel", "dialog", "menu", "toast", "tooltip" };

// one number per surface role — the RELATIVE structure of a style; the
// scheme's opacityScale sits on top
QJsonObject opacityJson(double content) {
    return QJsonObject{
        {"window", 1.0}, {"chrome", 1.0}, {"player", content},
        {"panel", 1.0}, {"dialog", 1.0}, {"menu", 0.75},
        {"card", content}, {"button", content}, {"hover", content}, {"selected", content},
        {"toast", 0.92}, {"scrollbar", content}, {"tooltip", 1.0},
        // ink: its own opacity, never the master's — the window fade already
        // handles "everything dimmer"
        {"text", 1.0}, {"textSoft", 1.0}, {"textDim", 1.0}, {"textFaint", 1.0},
        {"textOverArt", 1.0},
    };
}

QJsonObject foldOpacityScale(const QJsonObject& settings) {
    const double k = settings.value(QStringLiteral("opacityScale")).toDouble(1.0);
    if (k == 1.0 || !settings.value(QStringLiteral("opacity")).isObject()) return settings;
    QJsonObject op = settings.value(QStringLiteral("opacity")).toObject();
    for (auto it = op.begin(); it != op.end(); ++it)
        if (isSurfaceRole(it.key()) && !isFloatingRole(it.key()))
            it.value() = it.value().toDouble() * k;
    QJsonObject out = settings;
    out[QStringLiteral("opacity")] = op;
    return out;
}

bool isSurfaceRole(const QString& key) {
    for (const char* r : kSurfaceRoles) if (key == QLatin1String(r)) return true;
    return false;
}
bool isFloatingRole(const QString& key) {
    for (const char* r : kFloatingRoles) if (key == QLatin1String(r)) return true;
    return false;
}
QStringList surfaceRoles() {
    QStringList out;
    for (const char* r : kSurfaceRoles) out << QLatin1String(r);
    return out;
}


QJsonObject partsPatch(const QJsonObject& themeSettings, const QJsonObject& current,
                       const QStringList& takenKeys, const QStringList& keptKeys) {
    QJsonObject patch;
    QJsonArray clear;
    for (const QString& k : takenKeys) {
        if (themeSettings.contains(k)) patch[k] = themeSettings[k];
        else clear.append(k);
    }
    for (const QString& k : keptKeys)
        if (current.contains(k)) patch[k] = current[k];
    return QJsonObject{{"patch", patch}, {"clear", clear}};
}

QJsonObject builtInLayout(const QString& id) {
    static const char* kRows = R"({
      "id": "rows", "name": "Rows", "height": 77, "pad": 12, "vcenter": true, "vOffset": 2, "rowGap": 4,
      "rows": [
        { "height": 28, "gap": 8, "cells": [
          { "type": "thumb", "w": 48, "h": 28 },
          { "type": "title", "flex": 1, "lines": 2, "artist": "below" } ] },
        { "height": 24, "gap": 8, "cells": [
          { "type": "prev", "size": 22, "glyph": 14 },
          { "type": "play", "size": 22, "glyph": 14, "gap": 3 },
          { "type": "next", "size": 22, "glyph": 14, "gap": 3 },
          { "type": "elapsed", "size": 12 },
          { "type": "scrub", "flex": 1, "h": 24, "track": 6, "hover": 8, "radius": 2, "glide": true },
          { "type": "total", "size": 12 },
          { "type": "button", "id": "eq", "gap": 16 },
          { "type": "button", "id": "queue" },
          { "type": "button", "id": "vis", "mini": true } ] } ] })";
    static const char* kCentre = R"({
      "id": "centre", "name": "Centre", "height": 77, "pad": 12, "top": 8, "rowGap": 8,
      "rows": [
        { "height": 28, "gap": 6, "cells": [
          { "type": "button", "id": "library", "size": 24 },
          { "type": "button", "id": "radio", "size": 24 },
          { "type": "prev", "size": 28, "glyph": 17, "gap": 26 },
          { "type": "play", "size": 28, "glyph": 17, "centre": true, "gap": 12 },
          { "type": "next", "size": 28, "glyph": 17, "gap": 12 },
          { "type": "button", "id": "eq", "size": 24, "gap": 26 },
          { "type": "button", "id": "queue", "size": 24 },
          { "type": "button", "id": "vis", "size": 24, "mini": true } ] },
        { "height": 22, "gap": 8, "cells": [
          { "type": "spacer", "flex": 1 },
          { "type": "elapsed", "size": 11 },
          { "type": "scrub", "h": 22, "fitMax": 532, "fitMargin": 114, "track": 4, "hover": 7 },
          { "type": "total", "size": 11 },
          { "type": "spacer", "flex": 1 } ] } ],
      "variants": [ { "maxWidth": "narrow", "height": 56, "top": 6, "rows": [
        { "height": 28, "gap": 6, "cells": [
          { "type": "time", "sep": "  /  ", "minWidth": 431, "gap": 2 },
          { "type": "spacer", "flex": 1, "gap": 0 },
          { "type": "button", "id": "library", "size": 24 },
          { "type": "button", "id": "radio", "size": 24 },
          { "type": "prev", "size": 28, "glyph": 17, "gap": 26 },
          { "type": "play", "size": 28, "glyph": 17, "centre": true, "gap": 12 },
          { "type": "next", "size": 28, "glyph": 17, "gap": 12 },
          { "type": "button", "id": "eq", "size": 24, "gap": 26 },
          { "type": "button", "id": "queue", "size": 24 },
          { "type": "button", "id": "vis", "size": 24, "mini": true } ] },
        { "at": "bottom", "height": 10, "pad": 0, "cells": [
          { "type": "scrub", "flex": 1, "h": 10, "edge": true, "track": 3, "hover": 8 } ] } ] } ] })";
    static const char* kStrip = R"({
      "id": "strip", "name": "Strip", "height": 56, "pad": 12, "vcenter": true,
      "rows": [
        { "height": 24, "gap": 6, "cells": [
          { "type": "thumb", "w": 40, "h": 24, "gap": 8 },
          { "type": "title", "flex": 1, "lines": 1, "artist": "inline", "gap": 8 },
          { "type": "prev", "size": 24, "glyph": 15, "gap": 16 },
          { "type": "play", "size": 24, "glyph": 15, "centre": true, "gap": 8 },
          { "type": "next", "size": 24, "glyph": 15, "gap": 8 },
          { "type": "button", "id": "library", "minWidth": 640, "gap": 14 },
          { "type": "button", "id": "radio", "minWidth": 640 },
          { "type": "scrub", "flex": 1, "h": 20, "track": 3, "hover": 6, "gap": 14 },
          { "type": "time", "minWidth": 500, "gap": 8 },
          { "type": "button", "id": "eq", "gap": 14 },
          { "type": "button", "id": "queue" },
          { "type": "button", "id": "vis", "mini": true } ] } ] })";
    static const char* kMiniStrip = R"({
      "id": "ministrip", "name": "Mini strip", "height": 56, "pad": 12, "vcenter": true,
      "rows": [
        { "height": 24, "gap": 6, "cells": [
          { "type": "thumb", "w": 40, "h": 24, "gap": 8 },
          { "type": "title", "flex": 1, "lines": 1, "artist": "inline", "gap": 8 },
          { "type": "prev", "size": 24, "glyph": 15, "gap": 16 },
          { "type": "play", "size": 24, "glyph": 15, "centre": true, "gap": 8 },
          { "type": "next", "size": 24, "glyph": 15, "gap": 8 },
          { "type": "scrub", "flex": 1, "h": 20, "track": 3, "hover": 6, "gap": 14 },
          { "type": "time", "minWidth": 500, "gap": 8 },
          { "type": "volume", "w": 80, "minWidth": 640, "gap": 14 },
          { "type": "button", "id": "eq", "gap": 14 },
          { "type": "button", "id": "queue" },
          { "type": "button", "id": "vis", "mini": true } ] } ] })";
    const char* raw = id == QLatin1String("centre") ? kCentre : id == QLatin1String("strip") ? kStrip
                    : id == QLatin1String("rows") ? kRows : id == QLatin1String("ministrip") ? kMiniStrip : nullptr;
    return raw ? QJsonDocument::fromJson(raw).object() : QJsonObject{};
}
QStringList builtInLayoutIds() { return {"rows", "centre", "strip", "ministrip"}; }

// The parts a theme may carry, the format's list; ThemeStore's kThemeParts
// must say the same, and tst_themekeys checks that it does
QStringList partKinds() {
    return {"palette", "window", "type", "surfaces", "transparency", "behaviour", "size", "background", "controls", "glyphs", "player", "insets"};
}
static bool hasOwnPart(const QJsonObject& theme, const QString& part, const QMap<QString, QStringList>& keysOfPart) {
    if (part == QLatin1String("palette")) return !theme["palette"].toObject().isEmpty();
    const QJsonObject s = theme["settings"].toObject();
    for (const QString& k : keysOfPart.value(part)) if (s.contains(k)) return true;
    return false;
}
QStringList partsOf(const QJsonObject& theme, const QMap<QString, QStringList>& keysOfPart,
                    const std::function<QJsonObject(const QString&)>& lookup) {
    QStringList out;
    const QJsonObject ptrs = theme["parts"].toObject();
    for (const QString& part : partKinds()) {
        if (hasOwnPart(theme, part, keysOfPart)) { out << part; continue; }
        const QString from = ptrs[part].toString();
        if (!from.isEmpty() && hasOwnPart(lookup(from), part, keysOfPart)) out << part;   // a pointer to a part that is there
    }
    return out;
}
QJsonObject resolvedSettings(const QJsonObject& theme, const QMap<QString, QStringList>& keysOfPart,
                             const std::function<QJsonObject(const QString&)>& lookup) {
    QJsonObject s = theme["settings"].toObject();
    const QJsonObject ptrs = theme["parts"].toObject();
    for (auto it = ptrs.constBegin(); it != ptrs.constEnd(); ++it) {
        if (it.key() == QLatin1String("palette") || hasOwnPart(theme, it.key(), keysOfPart)) continue;
        const QJsonObject other = lookup(it.value().toString())["settings"].toObject();
        for (const QString& k : keysOfPart.value(it.key())) if (other.contains(k)) s[k] = other[k];
    }
    return s;
}
QJsonObject resolvedPalette(const QJsonObject& theme, const std::function<QJsonObject(const QString&)>& lookup) {
    const QJsonObject own = theme["palette"].toObject();
    if (!own.isEmpty()) return own;
    const QString from = theme["parts"].toObject()["palette"].toString();
    return from.isEmpty() ? own : lookup(from)["palette"].toObject();
}


// ---- SVG -> a glyph entry ------------------------------------------------
// melo's glyphs are path data in a square viewBox, drawn either all-filled or
// all-stroked (Glyph.qml gives every subpath the same brush). An imported SVG
// is folded into that shape, or refused with an error naming what could not
// be reduced.

static QString num(double v) {
    return QString::number(v, 'g', 10);
}
static void numbersIn(const QString& s, QList<double>& out, bool* ok) {
    static const QRegularExpression rx(QStringLiteral("[-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?"));
    auto it = rx.globalMatch(s);
    while (it.hasNext()) out << it.next().captured(0).toDouble();
    if (out.isEmpty()) *ok = false;
}
// how many numbers each path command takes; -1 is not a command
static int argCount(QChar c) {
    switch (c.toUpper().toLatin1()) {
    case 'M': case 'L': case 'T': return 2;
    case 'H': case 'V': return 1;
    case 'C': return 6;
    case 'S': case 'Q': return 4;
    case 'A': return 7;
    case 'Z': return 0;
    }
    return -1;
}
static bool tokenizeD(const QString& d, QStringList& out) {
    static const QRegularExpression rx(QStringLiteral("[-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?"));
    int i = 0;
    while (i < d.size()) {
        const QChar c = d.at(i);
        if (c.isSpace() || c == QLatin1Char(',')) { ++i; continue; }
        if (c.isLetter()) { out << QString(c); ++i; continue; }
        const auto m = rx.match(d, i, QRegularExpression::NormalMatch,
                                 QRegularExpression::AnchorAtOffsetMatchOption);
        if (!m.hasMatch() || m.capturedLength(0) == 0) return false;
        out << m.captured(0);
        i += m.capturedLength(0);
    }
    return true;
}
// A translate folded into the path itself. Only absolute coordinates move —
// a relative command is already a delta — except the leading `m`, which the
// spec says starts at the origin like `M` does.
static QString shiftD(const QString& d, double dx, double dy, bool* ok) {
    QStringList tok;
    if (!tokenizeD(d, tok)) { *ok = false; return {}; }
    if (dx == 0 && dy == 0) return d;
    QStringList out;
    int i = 0;
    bool leading = true;
    while (i < tok.size()) {
        QChar cmd = tok[i].at(0);
        if (!cmd.isLetter()) { *ok = false; return {}; }
        const int n = argCount(cmd);
        if (n < 0) { *ok = false; return {}; }
        out << tok[i];
        ++i;
        bool firstGroup = true;
        while (n > 0 && i + n <= tok.size() && !tok[i].at(0).isLetter()) {
            QList<double> v;
            for (int k = 0; k < n; ++k) v << tok[i + k].toDouble();
            const bool move = cmd.isUpper() || (leading && firstGroup && cmd == QLatin1Char('m'));
            if (move) {
                const QChar u = cmd.toUpper();
                if (u == QLatin1Char('H')) v[0] += dx;
                else if (u == QLatin1Char('V')) v[0] += dy;
                else if (u == QLatin1Char('A')) { v[5] += dx; v[6] += dy; }
                else for (int k = 0; k + 1 < n; k += 2) { v[k] += dx; v[k + 1] += dy; }
            }
            for (double x : std::as_const(v)) out << num(x);
            i += n;
            firstGroup = false;
            leading = false;
        }
        leading = false;
    }
    return out.join(QLatin1Char(' '));
}

// the one transform shape that can be folded without a matrix
static bool translateOf(const QString& t, double* dx, double* dy) {
    static const QRegularExpression re(
        QStringLiteral("^\\s*translate\\s*\\(\\s*([-+0-9.eE]+)(?:[\\s,]+([-+0-9.eE]+))?\\s*\\)\\s*$"));
    const auto m = re.match(t);
    if (!m.hasMatch()) return false;
    *dx = m.captured(1).toDouble();
    *dy = m.captured(2).isEmpty() ? 0.0 : m.captured(2).toDouble();
    return true;
}

namespace {
struct SvgFrame {
    QString fill, strokeWidth;
    double dx = 0, dy = 0;
};
// a presentation attribute, or the same property out of `style`
QString styleProp(const QString& style, const QString& prop) {
    const QRegularExpression re(QStringLiteral("(?:^|;)\\s*") + prop
                                + QStringLiteral("\\s*:\\s*([^;]+)"));
    const auto m = re.match(style);
    return m.hasMatch() ? m.captured(1).trimmed() : QString();
}
}  // namespace

QJsonObject importGlyphSvg(const QByteArray& svg) {
    auto no = [](const QString& why) {
        return QJsonObject{{"ok", false}, {"error", why}};
    };
    QXmlStreamReader r(svg);
    QList<SvgFrame> stack;
    QStringList paths;
    double vb = 0;
    bool haveBox = false, fill = true, haveBrush = false;
    QString sw;

    while (!r.atEnd()) {
        const auto t = r.readNext();
        if (t == QXmlStreamReader::EndElement) {
            if (!stack.isEmpty()) stack.removeLast();
            continue;
        }
        if (t != QXmlStreamReader::StartElement) continue;

        const auto a = r.attributes();
        const QString style = a.value(QLatin1String("style")).toString();
        SvgFrame f = stack.isEmpty() ? SvgFrame{} : stack.last();
        auto prop = [&](const char* name) {
            const QString s = styleProp(style, QLatin1String(name));
            return s.isEmpty() ? a.value(QLatin1String(name)).toString() : s;
        };
        if (!prop("fill").isEmpty()) f.fill = prop("fill");
        if (!prop("stroke-width").isEmpty()) f.strokeWidth = prop("stroke-width");
        const QString tr = a.value(QLatin1String("transform")).toString();
        if (!tr.isEmpty()) {
            double dx = 0, dy = 0;
            if (!translateOf(tr, &dx, &dy))
                return no(QStringLiteral("transform \"%1\" is not a translate").arg(tr.trimmed()));
            f.dx += dx;
            f.dy += dy;
        }
        stack << f;

        const QString el = r.name().toString();
        if (el == QLatin1String("svg")) {
            // A viewBox with a non-zero origin IS a translate of its content,
            // so it folds the same way and the entry keeps a plain square box.
            QList<double> box;
            bool okBox = true;
            numbersIn(a.value(QLatin1String("viewBox")).toString(), box, &okBox);
            if (okBox && box.size() == 4) {
                stack.last().dx -= box[0];
                stack.last().dy -= box[1];
                vb = qMax(box[2], box[3]);
                haveBox = true;
            } else {
                QList<double> w, h;
                bool okW = true, okH = true;
                numbersIn(a.value(QLatin1String("width")).toString(), w, &okW);
                numbersIn(a.value(QLatin1String("height")).toString(), h, &okH);
                if (okW && okH && !w.isEmpty() && !h.isEmpty()) {
                    vb = qMax(w[0], h[0]);
                    haveBox = true;
                }
            }
            continue;
        }

        const SvgFrame& c = stack.last();
        bool ok = true;
        QString d;
        auto nums = [&](const char* name, double dflt) {
            const QString s = a.value(QLatin1String(name)).toString();
            return s.isEmpty() ? dflt : s.toDouble();
        };
        if (el == QLatin1String("path")) {
            d = shiftD(a.value(QLatin1String("d")).toString(), c.dx, c.dy, &ok);
            if (!ok) return no(QStringLiteral("path data could not be read"));
            if (d.trimmed().isEmpty()) continue;
        } else if (el == QLatin1String("rect")) {
            const double x = nums("x", 0) + c.dx, y = nums("y", 0) + c.dy;
            const double w = nums("width", 0), h = nums("height", 0);
            if (w <= 0 || h <= 0) continue;
            double rx = nums("rx", -1), ry = nums("ry", -1);
            if (rx < 0) rx = qMax(ry, 0.0);
            if (ry < 0) ry = rx;
            rx = qMin(rx, w / 2); ry = qMin(ry, h / 2);
            if (rx <= 0 || ry <= 0) {
                d = QStringLiteral("M%1 %2H%3V%4H%1Z").arg(num(x), num(y), num(x + w), num(y + h));
            } else {
                const QString arc = QStringLiteral("A%1 %2 0 0 1 ").arg(num(rx), num(ry));
                d = QStringLiteral("M%1 %2H%3").arg(num(x + rx), num(y), num(x + w - rx))
                    + arc + QStringLiteral("%1 %2").arg(num(x + w), num(y + ry))
                    + QStringLiteral("V%1").arg(num(y + h - ry))
                    + arc + QStringLiteral("%1 %2").arg(num(x + w - rx), num(y + h))
                    + QStringLiteral("H%1").arg(num(x + rx))
                    + arc + QStringLiteral("%1 %2").arg(num(x), num(y + h - ry))
                    + QStringLiteral("V%1").arg(num(y + ry))
                    + arc + QStringLiteral("%1 %2Z").arg(num(x + rx), num(y));
            }
        } else if (el == QLatin1String("circle") || el == QLatin1String("ellipse")) {
            const double cx = nums("cx", 0) + c.dx, cy = nums("cy", 0) + c.dy;
            const double rx = el == QLatin1String("circle") ? nums("r", 0) : nums("rx", 0);
            const double ry = el == QLatin1String("circle") ? nums("r", 0) : nums("ry", 0);
            if (rx <= 0 || ry <= 0) continue;
            // two half arcs: one arc cannot close on its own start point
            d = QStringLiteral("M%1 %2A%3 %4 0 1 0 %5 %2A%3 %4 0 1 0 %1 %2Z")
                    .arg(num(cx - rx), num(cy), num(rx), num(ry), num(cx + rx));
        } else if (el == QLatin1String("polygon") || el == QLatin1String("polyline")) {
            QList<double> pts;
            bool okPts = true;
            numbersIn(a.value(QLatin1String("points")).toString(), pts, &okPts);
            if (!okPts || pts.size() < 4 || pts.size() % 2)
                return no(QStringLiteral("<%1> has no usable points").arg(el));
            for (int k = 0; k < pts.size(); k += 2)
                d += QStringLiteral("%1%2 %3").arg(k ? QStringLiteral("L") : QStringLiteral("M"),
                                                   num(pts[k] + c.dx), num(pts[k + 1] + c.dy));
            if (el == QLatin1String("polygon")) d += QStringLiteral("Z");
        } else if (el == QLatin1String("line")) {
            d = QStringLiteral("M%1 %2L%3 %4").arg(num(nums("x1", 0) + c.dx), num(nums("y1", 0) + c.dy),
                                                   num(nums("x2", 0) + c.dx), num(nums("y2", 0) + c.dy));
        } else {
            continue;   // <g>, <defs>, <title>: containers and furniture
        }

        // The first shape says how the whole glyph is painted, because
        // Glyph.qml gives every subpath one brush. fill:none means stroked.
        if (!haveBrush) {
            fill = c.fill != QLatin1String("none");
            sw = c.strokeWidth;
            haveBrush = true;
        }
        paths << d;
    }
    if (r.hasError()) return no(r.errorString());
    if (!haveBox) return no(QStringLiteral("no viewBox and no width/height"));
    if (paths.isEmpty()) return no(QStringLiteral("no path, rect, circle, polygon, polyline or line"));
    // Glyph.qml draws nine subpaths; a tenth would be dropped in silence
    if (paths.size() > 9)
        return no(QStringLiteral("%1 paths — a glyph draws at most 9").arg(paths.size()));

    QJsonArray arr;
    for (const QString& d : std::as_const(paths)) arr << d;
    QJsonObject entry{{"vb", vb}, {"ink", vb}, {"fill", fill}, {"paths", arr}};
    if (!fill && !sw.isEmpty()) entry["sw"] = sw.toDouble();
    return QJsonObject{{"ok", true}, {"entry", entry}};
}

}  // namespace ThemeFormat
