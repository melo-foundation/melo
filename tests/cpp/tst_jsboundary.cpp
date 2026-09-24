#include <QtTest>
#include <QJSEngine>
#include <QJsonObject>
#include <QJsonValue>
#include "jsvalue.h"

// A JS object passed to a Q_INVOKABLE QVariant arrives as QVariant<QJSValue>,
// and QJsonValue::fromVariant turns it into null without error. If a future Qt
// converts it, the first assertion fails and unwrapJs can go.
class TestJsBoundary : public QObject {
    Q_OBJECT

    // exactly what ColorPicker.currentValue() returns for an adaptive entry
    QVariant pickerValue() {
        QJSValue o = eng_.newObject();
        o.setProperty("colour", "#123456");
        o.setProperty("blend", "multiply");
        o.setProperty("source", "adaptive");
        QJSValue a = eng_.newObject();
        a.setProperty("hue", 0.25);
        a.setProperty("lum", -0.6);
        a.setProperty("sat", 0.4);
        a.setProperty("opacity", 0.9);
        o.setProperty("amounts", a);
        return QVariant::fromValue(o);
    }
    QJSEngine eng_;

private slots:
    void theTrapIsReal() {
        const QVariant raw = pickerValue();
        QVERIFY2(raw.canConvert<QJSValue>(), "a JS object arrives wrapped");
        QVERIFY2(QJsonValue::fromVariant(raw).isNull(),
                 "fromVariant no longer nulls a QJSValue — unwrapJs may be droppable");
    }

    void unwrappingIsWhatMakesItAnObject() {
        const QJsonValue v = QJsonValue::fromVariant(unwrapJs(pickerValue()));
        QVERIFY2(v.isObject(), "unwrapped, it is an object");
        const QJsonObject o = v.toObject();
        QCOMPARE(o["colour"].toString(), QStringLiteral("#123456"));
        QCOMPARE(o["blend"].toString(), QStringLiteral("multiply"));
        QCOMPARE(o["source"].toString(), QStringLiteral("adaptive"));
        QCOMPARE(o["amounts"].toObject()["lum"].toDouble(), -0.6);
    }

    // the whole path a palette write takes: QML object -> unwrap -> JSON
    void aPickerEntrySurvivesTheWholeWrite() {
        const QJsonValue stored = QJsonValue::fromVariant(unwrapJs(pickerValue()));
        QVERIFY(stored.isObject());
        QCOMPARE(stored.toObject()["source"].toString(), QStringLiteral("adaptive"));
        QCOMPARE(stored.toObject()["amounts"].toObject()["opacity"].toDouble(), 0.9);
    }

    // a plain colour is still a plain string, not an object
    void aPlainColourStaysAString() {
        const QJSValue s = eng_.toScriptValue(QStringLiteral("#e0e0e0"));
        const QJsonValue v = QJsonValue::fromVariant(unwrapJs(QVariant::fromValue(s)));
        QVERIFY(v.isString());
        QCOMPARE(v.toString(), QStringLiteral("#e0e0e0"));
    }
};

QTEST_MAIN(TestJsBoundary)
#include "tst_jsboundary.moc"
