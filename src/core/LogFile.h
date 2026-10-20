#pragma once
#include <QByteArray>
#include <QString>
#include <QtGlobal>
#include <cstdio>

// <config>/logs/melo.log: everything melo writes to stderr, Qt's messages and
// the sidecar's relayed lines, redacted. Rotates at `cap` bytes, keeping
// melo.log.1 .. .<keep>.
class LogFile {
public:
    explicit LogFile(const QString& dir, qint64 cap = 5 * 1024 * 1024, int keep = 3);
    ~LogFile();
    // one line, without its newline; redacted here
    void writeLine(const QByteArray& line);
    void flush();
    QString path() const { return path_; }

    // cookies, auth headers, tokens, API keys and googlevideo URLs replaced
    static QByteArray redact(const QByteArray& line);

    // The process side (glibc): melo's stdio stderr becomes a pipe a worker thread
    // reads, writing each chunk to the real stderr unchanged and each line to the
    // file. fd 2 stays the real stderr, so child processes never see the pipe. Qt's
    // messages also come through a handler chained to the one before, for when
    // Qt sends them to journald; `smoke`: the --smoke handler prints them itself.
    static bool startTee(const QString& dir, bool smoke);
    static void stopTee();
    static bool teeRunning();

private:
    void open();
    void rotate();
    QString dir_, path_;
    qint64 cap_;
    int keep_;
    std::FILE* f_ = nullptr;
    qint64 size_ = 0;
};
