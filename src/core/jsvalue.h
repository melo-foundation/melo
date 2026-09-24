#pragma once
#include <QJSValue>
#include <QVariant>

// A JS object from QML arrives as QVariant<QJSValue>, which
// QJsonValue::fromVariant silently turns into null: the write succeeds and
// stores nothing. Every QVariant crossing the QML boundary goes through here.
inline QVariant unwrapJs(const QVariant& v) {
    if (v.canConvert<QJSValue>()) return v.value<QJSValue>().toVariant();
    return v;
}
