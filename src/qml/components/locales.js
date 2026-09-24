// Locale picker presentation. The list comes from the sidecar (src/locales.ts)
// via settings/locales, the table localePref() validates against. Entries are
// { code, english, native }; search matches all three.
.pragma library

// "" is a real choice, not a missing value: follow whatever the OS reports.
function options(list) {
    var out = [{ value: "", label: "System", sub: "follow the OS locale" }];
    for (var i = 0; i < (list || []).length; i++) {
        var l = list[i];
        out.push({
            value: l.code,
            label: l.native === l.english ? l.english : l.native + " — " + l.english,
            sub: l.code
        });
    }
    return out;
}

/** Case-insensitive match on code, English name or native name. */
function filter(opts, needle) {
    var n = (needle || "").trim().toLowerCase();
    if (!n) return opts;
    var out = [];
    for (var i = 0; i < opts.length; i++) {
        var o = opts[i];
        if ((o.label + " " + o.value + " " + (o.sub || "")).toLowerCase().indexOf(n) !== -1)
            out.push(o);
    }
    return out;
}

/** Regions arrive as { code, name }; "" follows the OS. */
function regionOptions(list) {
    var out = [{ value: "", label: "System", sub: "follow the OS region" }];
    for (var i = 0; i < (list || []).length; i++) {
        out.push({ value: list[i].code, label: list[i].name, sub: list[i].code });
    }
    return out;
}
