#!/usr/bin/env python3
"""Run a command inside a real pty and tee its output to a log file.

Used by claude-worker.sh to run `claude --remote-control "<prompt>"` with a
pty stdin. AskUserQuestion is rejected synchronously when claude's stdin is
a file pipe; a pty lets it surface to the Remote Control UI.

Usage: claude-pty-spawn.py <log_file> <cmd...>

Exits with the child's exit code. On SIGTERM/SIGINT, forwards SIGTERM to
the child, waits briefly, then SIGKILLs if still alive.
"""
import os
import pty
import select
import signal
import sys
import termios
import time


def set_raw_ish(fd):
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag &= ~(termios.ICRNL | termios.INLCR | termios.IXON | termios.IXOFF)
    oflag &= ~termios.ONLCR
    lflag &= ~(termios.ICANON | termios.ECHO | termios.ISIG)
    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(
            "Usage: claude-pty-spawn.py <log_file> <cmd...>\n"
        )
        sys.exit(2)

    log_file = sys.argv[1]
    cmd = sys.argv[2:]

    out_f = open(log_file, 'wb')
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.pop('CLAUDECODE', None)
        os.execvp(cmd[0], cmd)

    terminating = {'flag': False}

    def _forward(signum, _frame):
        terminating['flag'] = True
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, _forward)
    signal.signal(signal.SIGINT, _forward)

    set_raw_ish(fd)

    exit_code = 0
    try:
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 0.5)
            except InterruptedError:
                continue
            if r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                out_f.write(data)
                out_f.flush()
            wpid, status = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                if os.WIFEXITED(status):
                    exit_code = os.WEXITSTATUS(status)
                elif os.WIFSIGNALED(status):
                    exit_code = 128 + os.WTERMSIG(status)
                break
    finally:
        out_f.close()
        try:
            os.kill(pid, 0)
            if terminating['flag']:
                time.sleep(1)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
