#pragma once
#include <QRegion>

// QWindow::setMask(QRegion()) means "no mask", but Mutter on X11 keeps
// clipping the window to the last shape it was sent: a window that drops its
// shape and then grows (maximising) draws only in its old rectangle. A
// rectangle larger than any window reads as unshaped everywhere.
inline QRegion meloWindowMask(const QRegion& shape) {
    return shape.isEmpty() ? QRegion(0, 0, 32767, 32767) : shape;
}
