#pragma once
#include <QByteArray>
#include <QFile>
#include <QRegularExpression>
#include <QString>
#include <QStringList>
#include <QtEndian>
#include <cstring>

// What an AppImage says about itself: its ELF sections, and the update
// information appimagetool -u writes into `.upd_info`.
namespace appimage {

// The named section's bytes, or empty. Reads ELF32 and ELF64 of either byte order.
inline QByteArray elfSection(const QString& path, const QByteArray& name) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    const QByteArray id = f.read(64);
    if (id.size() < 52 || !id.startsWith("\x7f" "ELF")) return {};
    const bool is64 = id[4] == 2;
    const bool le = id[5] == 1;
    const uchar* h = reinterpret_cast<const uchar*>(id.constData());
    auto u16 = [le](const uchar* p) { return le ? qFromLittleEndian<quint16>(p) : qFromBigEndian<quint16>(p); };
    auto u32 = [le](const uchar* p) { return le ? qFromLittleEndian<quint32>(p) : qFromBigEndian<quint32>(p); };
    auto u64 = [le](const uchar* p) { return le ? qFromLittleEndian<quint64>(p) : qFromBigEndian<quint64>(p); };
    if (is64 && id.size() < 64) return {};
    const quint64 shoff = is64 ? u64(h + 0x28) : u32(h + 0x20);
    const quint16 shentsize = u16(h + (is64 ? 0x3A : 0x2E));
    const quint16 shnum = u16(h + (is64 ? 0x3C : 0x30));
    const quint16 shstrndx = u16(h + (is64 ? 0x3E : 0x32));
    if (!shoff || shnum == 0 || shstrndx >= shnum || shentsize < (is64 ? 64 : 40) || shnum > 4096) return {};
    if (!f.seek(qint64(shoff))) return {};
    const QByteArray table = f.read(qint64(shentsize) * shnum);
    if (table.size() != qint64(shentsize) * shnum) return {};
    struct Sec { quint32 name; quint64 off, size; };
    auto sec = [&](int i) {
        const uchar* s = reinterpret_cast<const uchar*>(table.constData()) + qsizetype(i) * shentsize;
        return is64 ? Sec { u32(s), u64(s + 0x18), u64(s + 0x20) }
                    : Sec { u32(s), u32(s + 0x10), u32(s + 0x14) };
    };
    auto readAt = [&f](quint64 off, quint64 size) -> QByteArray {
        if (size > (1u << 24) || off + size > quint64(f.size()) || !f.seek(qint64(off))) return {};
        return f.read(qint64(size));
    };
    const Sec strs = sec(shstrndx);
    const QByteArray names = readAt(strs.off, strs.size);
    for (int i = 0; i < shnum; ++i) {
        const Sec s = sec(i);
        if (s.name >= quint64(names.size())) continue;
        if (std::strcmp(names.constData() + s.name, name.constData()) == 0) return readAt(s.off, s.size);
    }
    return {};
}

// `gh-releases-zsync|owner|repo|channel|file`: channel is `latest` or a tag;
// the file name may hold `*`.
struct UpdateInfo {
    QString owner, repo, channel, zsyncName;
    bool valid() const { return !owner.isEmpty() && !repo.isEmpty() && !channel.isEmpty() && !zsyncName.isEmpty(); }
    QString apiUrl() const {
        const QString base = QStringLiteral("https://api.github.com/repos/%1/%2/releases/").arg(owner, repo);
        return channel == QLatin1String("latest") ? base + QStringLiteral("latest")
                                                  : base + QStringLiteral("tags/") + channel;
    }
    bool matchesAsset(const QString& asset) const {
        return QRegularExpression(QRegularExpression::wildcardToRegularExpression(zsyncName))
                   .match(asset).hasMatch();
    }
};

inline UpdateInfo parseUpdateInfo(const QByteArray& raw) {
    const qsizetype nul = raw.indexOf('\0');
    const QString s = QString::fromUtf8(nul < 0 ? raw : raw.left(nul)).trimmed();
    const QStringList p = s.split(u'|');
    if (p.size() != 5 || p[0] != QLatin1String("gh-releases-zsync")) return {};
    return { p[1], p[2], p[3], p[4] };
}

// "melo 0.N.P" from an alpha-N(.P) tag; any other tag or a v-number reads as it is
inline QString versionLabel(const QString& tag, const QString& name) {
    static const QRegularExpression alpha(QStringLiteral("^alpha-(\\d+)(?:\\.(\\d+))?$"));
    const auto m = alpha.match(tag);
    if (m.hasMatch())
        return QStringLiteral("melo 0.%1.%2").arg(m.captured(1), m.captured(2).isEmpty() ? QStringLiteral("0") : m.captured(2));
    static const QRegularExpression semver(QStringLiteral("^v?(\\d+\\.\\d+(?:\\.\\d+)?)$"));
    const auto v = semver.match(tag);
    if (v.hasMatch()) return QStringLiteral("melo ") + v.captured(1);
    return QStringLiteral("melo ") + (name.trimmed().isEmpty() ? tag : name.trimmed());
}

}   // namespace appimage
