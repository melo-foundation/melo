#include "MeloUiArchives.h"

#include "SkinArchive.h"
#include "paths.h"

#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonObject>
#include <QJsonValue>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QUrl>

#include <utility>

#if defined(Q_OS_UNIX)
#include <climits>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#elif defined(Q_OS_WIN)
#include <windows.h>
#include <string>
#endif

namespace {

// The plugin data root melo hands the sidecar (main.ts joins the same two
// names onto the same dataDir). Derived from meloConfigDir() rather than from
// a literal, per paths.h.
QString pluginDataDir(const QString& pluginId) {
    // The sidecar already rejects ids outside [A-Za-z0-9][A-Za-z0-9_-]*;
    // re-checked because this is where the id becomes a path component and
    // every containment check is relative to this root. An empty root fails
    // every later check closed.
    static const QRegularExpression slug(
        QStringLiteral("\\A[A-Za-z0-9][A-Za-z0-9_-]*\\z"));
    if (!slug.match(pluginId).hasMatch()) return {};
    return QDir(meloConfigDir()).filePath(QStringLiteral("plugin-data/") + pluginId);
}

// Percent-encodes one component of an image:// id. Everything outside the URL
// unreserved set goes to %XX, which is what makes a separator inside an ENTRY
// NAME survive as %2F instead of splitting the id into a fourth component.
QString encodeComponent(const QString& s) {
    return QString::fromLatin1(QUrl::toPercentEncoding(s));
}

// A settings value must be a bare file name. Plugin QML can store any string
// via MeloUi.settings.set (e.g. "../../../id_rsa"), and nothing before this
// function validates a `file` field's value.
bool isBareFileName(const QString& v) {
    if (v.isEmpty()) return false;
    if (v == QLatin1String(".") || v == QLatin1String("..")) return false;
    if (v.contains(QLatin1Char('/'))) return false;
    // Backslash and colon are separators on Windows only, and a settings file
    // may cross platforms, so both are refused everywhere.
    if (v.contains(QLatin1Char('\\'))) return false;
    if (v.contains(QLatin1Char(':'))) return false;
    // An embedded NUL passes every check above AND the extension filter —
    // "secret.txt\0.wsz" has suffix "wsz" to QFileInfo — and then truncates at
    // the NUL when it becomes a C string on the way to open(). No escape from
    // the data dir, but the file melo opens would not be the file it validated.
    if (v.contains(QChar(u'\0'))) return false;
    return QFileInfo(v).fileName() == v;
}

// A manifest `dir` is a relative path INTO the plugin's data folder. The
// sidecar's badDataDir() already refuses an absolute one or a `..` segment;
// repeated here so the containment check below is not the only thing between a
// manifest and the user's home directory.
bool isContainedRelativeDir(const QString& dir) {
    if (dir.isEmpty()) return true;
    if (dir.startsWith(QLatin1Char('/')) || dir.startsWith(QLatin1Char('\\'))) return false;
    if (dir.size() >= 2 && dir.at(1) == QLatin1Char(':')) return false;   // C:\...
    const QStringList segs = dir.split(QRegularExpression(QStringLiteral("[\\\\/]")));
    for (const QString& s : segs)
        if (s == QLatin1String("..")) return false;
    return true;
}

}   // namespace

// --- the verified read ------------------------------------------------------
//
// Open once, then validate what is open, and return bytes, never a path. A
// check-then-open by name is a race: the plugin's sidecar half can write its
// data dir (--allow-fs-write, manager.ts) and re-point the name in between.
//   * O_NOFOLLOW refuses a symlink as the final component only.
//   * readlink("/proc/self/fd/N") resolves the whole path of the inode already
//     held, intermediate directories included, so nothing can swap after it.
// Not openat2(RESOLVE_BENEATH): Linux 5.6+ only, no glibc wrapper, and no
// Windows analogue, while verifying the held handle maps onto
// GetFinalPathNameByHandleW.
bool MeloUiArchives::readVerifiedFile(const QString& path, const QString& root,
                                      const QString& label, QByteArray* bytes,
                                      QString* error) {
    const auto fail = [error](const QString& msg) {
        if (error) *error = msg;
        return false;
    };
    // Never the path: this string reaches plugin QML through MeloUiArchive::error.
    const QString outside =
        QStringLiteral("\"%1\" is not inside the plugin's own data folder").arg(label);

#if defined(Q_OS_UNIX)
    // O_NONBLOCK is for open(): opening a FIFO with no writer blocks forever,
    // on the GUI thread. Reachable because the plugin's sidecar can symlink
    // `dir` to any directory holding a readable fifo. No effect on regular files.
    const int fd = ::open(QFile::encodeName(path).constData(),
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        // ELOOP is the symlink refusal. Not distinguished: a plugin would only
        // learn what melo refused to open.
        if (errno == ELOOP) return fail(outside);
        return fail(QStringLiteral("cannot open \"%1\"").arg(label));
    }
    struct FdGuard {
        int fd;
        ~FdGuard() { ::close(fd); }
    } guard{fd};

    struct stat st {};
    if (::fstat(fd, &st) != 0) return fail(QStringLiteral("cannot read \"%1\"").arg(label));
    // A directory, fifo, device or socket is not a skin. This does not protect
    // against the fifo hang, which happens in open() above; O_NONBLOCK covers
    // that.
    if (!S_ISREG(st.st_mode)) return fail(QStringLiteral("\"%1\" is not a file").arg(label));

    // Where this descriptor really points. Asked of the kernel, about an inode
    // already held — this is the check the whole design turns on.
    char resolved[PATH_MAX + 1];
    const QByteArray procPath = "/proc/self/fd/" + QByteArray::number(fd);
    const ssize_t n = ::readlink(procPath.constData(), resolved, PATH_MAX);
    if (n <= 0) return fail(QStringLiteral("cannot verify \"%1\"").arg(label));
    const QString actual = QFile::decodeName(QByteArray(resolved, n));
    // An unlinked inode reads back with a " (deleted)" suffix. Left as is: a
    // suffix cannot manufacture the root prefix, and an in-root file replaced
    // mid-load should still be read.
    if (actual != root && !actual.startsWith(root + QLatin1Char('/')))
        return fail(outside);

    if (st.st_size > SkinArchive::kMaxDecodedBytes)
        return fail(QStringLiteral("\"%1\" is too large").arg(label));

    // Read through the verified descriptor. Not QFile(path) — that would reopen
    // by name and throw away everything above.
    QByteArray out;
    out.reserve(int(st.st_size));
    char chunk[64 * 1024];
    for (;;) {
        const ssize_t got = ::read(fd, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR) continue;
            return fail(QStringLiteral("cannot read \"%1\"").arg(label));
        }
        if (got == 0) break;
        // The file may have grown since fstat; the cap is on what melo will
        // hold, not on what st_size claimed.
        if (out.size() + got > SkinArchive::kMaxDecodedBytes)
            return fail(QStringLiteral("\"%1\" is too large").arg(label));
        out.append(chunk, int(got));
    }
    *bytes = std::move(out);
    return true;

#elif defined(Q_OS_WIN)
    // Same shape: GetFinalPathNameByHandleW reports the handle's final target,
    // so junctions, symlinks and swapped directories show in the comparison.
    // Untested: CI builds on Windows but runs no tests. Symlinks are followed
    // (no FILE_FLAG_OPEN_REPARSE_POINT), which the final-path check covers.
    // GetFileType is coarser than st_mode: it rejects pipes (\\.\pipe\...) and
    // character devices, nothing finer.
    const auto finalPath = [](HANDLE h) -> QString {
        DWORD need = ::GetFinalPathNameByHandleW(h, nullptr, 0,
                                                 FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (need == 0) return {};
        std::wstring buf(need + 1, L'\0');
        const DWORD got = ::GetFinalPathNameByHandleW(h, buf.data(), need,
                                                      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (got == 0 || got > need) return {};
        QString s = QString::fromWCharArray(buf.data(), int(got));
        if (s.startsWith(QLatin1String("\\\\?\\"))) s.remove(0, 4);
        return QDir::fromNativeSeparators(s);
    };

    const HANDLE h = ::CreateFileW(reinterpret_cast<const wchar_t*>(
                                       QDir::toNativeSeparators(path).utf16()),
                                   GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                                   nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE)
        return fail(QStringLiteral("cannot open \"%1\"").arg(label));
    struct HandleGuard {
        HANDLE h;
        ~HandleGuard() { ::CloseHandle(h); }
    } guard{h};

    // The root must go through the SAME normalisation, or a short (8.3) name or
    // a junction anywhere above would make two spellings of one directory
    // compare unequal.
    const HANDLE rootHandle = ::CreateFileW(reinterpret_cast<const wchar_t*>(
                                                QDir::toNativeSeparators(root).utf16()),
                                            GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                            nullptr, OPEN_EXISTING,
                                            FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (rootHandle == INVALID_HANDLE_VALUE)
        return fail(QStringLiteral("the plugin's data folder does not exist yet"));
    struct RootGuard {
        HANDLE h;
        ~RootGuard() { ::CloseHandle(h); }
    } rootGuard{rootHandle};

    const QString actual = finalPath(h);
    const QString rootFinal = finalPath(rootHandle);
    if (actual.isEmpty() || rootFinal.isEmpty())
        return fail(QStringLiteral("cannot verify \"%1\"").arg(label));
    if (actual.compare(rootFinal, Qt::CaseInsensitive) != 0
        && !actual.startsWith(rootFinal + QLatin1Char('/'), Qt::CaseInsensitive))
        return fail(outside);

    // The type rejection, such as Windows can express it. FILE_TYPE_DISK is the
    // only kind melo will read; a named pipe reports FILE_TYPE_PIPE and is NOT
    // caught by the directory-attribute test below, which is the same class of
    // hole as the Unix fifo.
    if (::GetFileType(h) != FILE_TYPE_DISK)
        return fail(QStringLiteral("\"%1\" is not a file").arg(label));

    BY_HANDLE_FILE_INFORMATION info{};
    if (!::GetFileInformationByHandle(h, &info))
        return fail(QStringLiteral("cannot read \"%1\"").arg(label));
    if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        return fail(QStringLiteral("\"%1\" is not a file").arg(label));

    QByteArray out;
    char chunk[64 * 1024];
    for (;;) {
        DWORD got = 0;
        if (!::ReadFile(h, chunk, DWORD(sizeof(chunk)), &got, nullptr))
            return fail(QStringLiteral("cannot read \"%1\"").arg(label));
        if (got == 0) break;
        if (out.size() + qint64(got) > SkinArchive::kMaxDecodedBytes)
            return fail(QStringLiteral("\"%1\" is too large").arg(label));
        out.append(chunk, int(got));
    }
    *bytes = std::move(out);
    return true;

#else
    // FAIL CLOSED. There is no portable way to ask "what does this open
    // descriptor name", and the path-based approximation is the bug this
    // function exists to remove. A platform without one gets no archives rather
    // than a racy read.
    Q_UNUSED(path);
    Q_UNUSED(root);
    Q_UNUSED(bytes);
    return fail(QStringLiteral("archive access is unavailable on this platform"));
#endif
}

// --- PluginArchiveStore -----------------------------------------------------

std::shared_ptr<const SkinArchive> PluginArchiveStore::lookup(
    const QString& pluginId, const QString& settingsKey) const {
    // Exact compare, never a join. A plugin addressing another plugin's id
    // gets nothing; so does ".." (which arrives here intact).
    if (pluginId != id_) return {};
    const std::lock_guard<std::mutex> lock(mutex_);
    return byKey_.value(settingsKey);   // the copy is made under the lock
}

void PluginArchiveStore::put(const QString& settingsKey,
                             std::shared_ptr<const SkinArchive> archive) {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (archive) byKey_.insert(settingsKey, std::move(archive));
    else byKey_.remove(settingsKey);
}

// --- MeloUiArchive ----------------------------------------------------------

MeloUiArchive::MeloUiArchive(QString pluginId, QString settingsKey, QObject* parent)
    : QObject(parent), pluginId_(std::move(pluginId)), key_(std::move(settingsKey)) {}

QStringList MeloUiArchive::names() const {
    return archive_ ? archive_->names() : QStringList();
}

QString MeloUiArchive::image(const QString& name) const {
    if (!archive_) return {};
    // An entry the archive does not hold produces NO url. Serving one would
    // make a broken Image the plugin's only feedback, and — more to the point —
    // would let a plugin distinguish "no such entry" from "provider refused",
    // which is the difference an oracle is built out of.
    if (archive_->image(name).isNull()) return {};
    // #<generation> busts QQuickPixmap's url-keyed cache so a new skin is not
    // drawn from the old one's pixels. Qt 6.10.3 passes the fragment through to
    // requestImage, so the provider truncates at '#'; a real '#' is sent as %23.
    // Concatenated, not QString::arg: "%2F" in a component reads as a placeholder.
    QString url = QStringLiteral("image://");
    url += QLatin1String(SkinImageProvider::kProviderId);
    url += QLatin1Char('/');
    url += encodeComponent(pluginId_);
    url += QLatin1Char('/');
    url += encodeComponent(key_);
    url += QLatin1Char('/');
    url += encodeComponent(name);
    url += QLatin1Char('#');
    url += QString::number(generation_);
    return url;
}

QString MeloUiArchive::text(const QString& name) const {
    return archive_ ? archive_->text(name) : QString();
}

QString MeloUiArchive::pixel(const QString& name, int x, int y) const {
    if (!archive_) return {};
    const QImage image = archive_->image(name);
    if (image.isNull() || x < 0 || y < 0 || x >= image.width() || y >= image.height())
        return {};
    return image.pixelColor(x, y).name(QColor::HexRgb);
}

void MeloUiArchive::adopt(std::shared_ptr<const SkinArchive> archive, QString error) {
    archive_ = std::move(archive);
    error_ = std::move(error);
    ++generation_;
    emit changed();
}

// --- MeloUiArchives ---------------------------------------------------------

MeloUiArchives::MeloUiArchives(QString pluginId, ValueGetter valueOf, QObject* parent)
    : QObject(parent), id_(std::move(pluginId)), dataRoot_(pluginDataDir(id_)),
      valueOf_(std::move(valueOf)),
      store_(std::make_shared<PluginArchiveStore>(id_)) {}

void MeloUiArchives::setSchema(const QJsonArray& settings) {
    fields_.clear();
    for (const QJsonValue& v : settings) {
        const QJsonObject f = v.toObject();
        if (f.value(QStringLiteral("type")).toString() != QLatin1String("file")) continue;
        const QString key = f.value(QStringLiteral("key")).toString();
        if (key.isEmpty()) continue;
        FileField field;
        field.dir = f.value(QStringLiteral("dir")).toString();
        for (const QJsonValue& e : f.value(QStringLiteral("extensions")).toArray()) {
            QString ext = e.toString().toLower();
            while (ext.startsWith(QLatin1Char('.'))) ext.remove(0, 1);
            if (!ext.isEmpty()) field.extensions << ext;
        }
        fields_.insert(key, field);
    }
    // A schema change can retire a key a plugin already holds a facade for.
    // The facade stays alive (plugin QML may still be holding it) but must go
    // empty, or it would keep serving the archive its now-undeclared key named.
    for (auto it = facades_.cbegin(); it != facades_.cend(); ++it) {
        if (fields_.contains(it.key())) continue;
        store_->put(it.key(), nullptr);
        // haveLoaded_ back to false, not true: a manifest that declares the key
        // again later must reload it, and a "same value" comparison against the
        // value it was cleared with would decide there was nothing to do.
        it.value()->loadedFrom_.clear();
        it.value()->haveLoaded_ = false;
        it.value()->adopt(nullptr, QStringLiteral("no such settings key: %1").arg(it.key()));
    }
    refresh();
}

QObject* MeloUiArchives::get(const QString& settingsKey) {
    // The key is checked against THIS plugin's own manifest before anything
    // else happens with it. That single lookup is what makes "../../etc",
    // "/etc/passwd", another plugin's key and a plain typo all the same
    // outcome — there is no branch here where an unknown key becomes a path.
    if (!fields_.contains(settingsKey)) return nullptr;

    MeloUiArchive* facade = facades_.value(settingsKey);
    if (!facade) {
        facade = new MeloUiArchive(id_, settingsKey, this);
        facades_.insert(settingsKey, facade);
    }
    // Belt and braces against JavaScriptOwnership. The QObject parent above
    // should already imply C++ ownership for a value returned from a
    // Q_INVOKABLE; this states it outright, and
    // getFacadeSurvivesGarbageCollection() checks it.
    QQmlEngine::setObjectOwnership(facade, QQmlEngine::CppOwnership);

    reload(settingsKey, facade);
    return facade;
}

void MeloUiArchives::refresh() {
    for (auto it = facades_.cbegin(); it != facades_.cend(); ++it)
        if (fields_.contains(it.key())) reload(it.key(), it.value());
}

void MeloUiArchives::reload(const QString& settingsKey, MeloUiArchive* facade) {
    const QString value = valueOf_ ? valueOf_(settingsKey) : QString();
    // Same value, same file, nothing to do — this is what keeps get() cheap
    // enough to call from a binding and keeps refresh() off the disk on every
    // unrelated settings write.
    if (facade->haveLoaded_ && value == facade->loadedFrom_) return;
    facade->haveLoaded_ = true;
    facade->loadedFrom_ = value;

    QString error;
    std::shared_ptr<const SkinArchive> archive;
    QByteArray bytes;
    // Bytes from a verified descriptor, so nothing is reopened by name. Only
    // `value`, a bare file name the plugin wrote, may reach the error text.
    if (readFileForKey(settingsKey, value, &bytes, &error))
        archive = SkinArchive::load(std::move(bytes), value, &error);

    // The store first: it is what the loader thread reads, and a facade that
    // already hands out urls for an archive the store has not got yet would
    // draw one frame of nothing.
    store_->put(settingsKey, archive);
    facade->adopt(archive, archive ? QString() : error);
}

// The security boundary. `settingsKey` is manifest-matched, `value` is
// plugin-writable (see isBareFileName), and `dir` comes from the manifest; none
// is trusted as a path component until checked. Returns bytes, never a path,
// to avoid a check-then-open race.
bool MeloUiArchives::readFileForKey(const QString& settingsKey, const QString& value,
                                    QByteArray* bytes, QString* error) const {
    const auto it = fields_.constFind(settingsKey);
    if (it == fields_.cend()) {          // unreachable via get(); explicit anyway
        if (error) *error = QStringLiteral("no such settings key");
        return false;
    }
    if (dataRoot_.isEmpty()) {
        if (error) *error = QStringLiteral("plugin id is not a path-safe slug");
        return false;
    }
    if (value.isEmpty()) {
        // Not an error the user did anything wrong about: no file is chosen yet.
        if (error) *error = QStringLiteral("no file chosen for \"%1\"").arg(settingsKey);
        return false;
    }
    if (!isBareFileName(value)) {
        if (error) *error = QStringLiteral("setting \"%1\" is not a file name").arg(settingsKey);
        return false;
    }
    if (!isContainedRelativeDir(it->dir)) {
        if (error) *error = QStringLiteral("settings field \"%1\" declares a dir outside the plugin's data folder")
                                .arg(settingsKey);
        return false;
    }
    if (!it->extensions.isEmpty()) {
        // The same filter pluginSettingFiles() lists through, applied on the
        // read side too: a key can only ever open a file melo's own picker
        // would have offered for it.
        const QString suffix = QFileInfo(value).suffix().toLower();
        if (!it->extensions.contains(suffix)) {
            if (error) *error = QStringLiteral("setting \"%1\" names a %2 file, which that field does not accept")
                                    .arg(settingsKey, suffix.isEmpty() ? QStringLiteral("extensionless") : suffix);
            return false;
        }
    }

    // Only the root is canonicalized, as the comparison base. Canonicalizing
    // the target and reopening it is a race: the plugin can spin refresh() via
    // MeloUi.settings.set while its sidecar renames a symlink over the name,
    // exposing any zip-format file the user can read.
    const QString root = QFileInfo(dataRoot_).canonicalFilePath();
    if (root.isEmpty()) {
        if (error) *error = QStringLiteral("the plugin's data folder does not exist yet");
        return false;
    }
    return readVerifiedFile(QDir(QDir(root).filePath(it->dir)).filePath(value),
                            root, value, bytes, error);
}

SkinImageProvider::Resolver MeloUiArchives::resolver() const {
    // By value, so the resolver owns a reference to the store. The provider is
    // destroyed with the engine, which the shell usually tears down after this
    // object, but requestImage can be in flight on another thread while any of
    // it happens.
    return [store = store_](const QString& pluginId, const QString& settingsKey) {
        return store->lookup(pluginId, settingsKey);
    };
}
