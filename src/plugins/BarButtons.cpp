#include "BarButtons.h"

#include <QVariantMap>

QString BarButtons::keyOf(const QString& pluginId, const QString& id) {
    // The plugin id cannot contain a slash (captionSafe), so this cannot be
    // ambiguous between "a/b" + "c" and "a" + "b/c".
    return pluginId + QLatin1Char('/') + id;
}

QVariantList BarButtons::forBar(const QString& bar) const {
    QVariantList out;
    for (const QVariant& v : buttons_) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("bar")).toString() != bar) continue;
        if (isHidden(m.value(QStringLiteral("pluginId")).toString(),
                     m.value(QStringLiteral("id")).toString())) continue;
        out << m;
    }
    return out;
}

bool BarButtons::isHidden(const QString& pluginId, const QString& id) const {
    return hidden_.contains(keyOf(pluginId, id));
}

void BarButtons::setHidden(const QString& pluginId, const QString& id, bool on) {
    const QString k = keyOf(pluginId, id);
    if (hidden_.contains(k) == on) return;      // a hide that changes nothing
    if (on) hidden_.insert(k); else hidden_.remove(k);
    bump();
}

QStringList BarButtons::hiddenKeys() const {
    QStringList out(hidden_.cbegin(), hidden_.cend());
    out.sort();                                  // stable in the settings file
    return out;
}

void BarButtons::setHiddenKeys(const QStringList& keys) {
    // Not filtered by what is currently offered: a hide for a plugin that is
    // off has to survive, or turning that plugin back on returns a button the
    // user removed.
    hidden_ = QSet<QString>(keys.cbegin(), keys.cend());
    bump();
}

void BarButtons::setButtons(const QVariantList& buttons) {
    buttons_ = buttons;
    bump();
}
