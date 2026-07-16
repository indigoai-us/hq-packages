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
import re
import select
import signal
import sys
import termios
import time


# claude --remote-control shows two interactive dialogs the worker must
# clear or it hangs forever (the read loop below only tees output, it
# never typed anything before this). Strip ANSI/VT noise so we can match
# the prompt text reliably, then auto-answer:
#   * "trust this folder" -> press Enter (default = trust)
#   * "Bypass Permissions mode … Yes, I accept" -> one Down then Enter
_CSI = re.compile(rb'\x1b\[[0-9;<>?]*[A-Za-z]')
_OSC = re.compile(rb'\x1b\][^\x07]*\x07')
_OTHER = re.compile(rb'\x1b[()][0-9A-Za-z]|\x1b[=>NODME]')


def _clean(b):
    b = _OSC.sub(b'', b)
    b = _CSI.sub(b'', b)
    b = _OTHER.sub(b'', b)
    b = re.sub(rb'[\x00-\x08\x0e-\x1f\x7f ]', b'', b)
    return b


def _looks_like_bypass_prompt(raw_bytes):
    """Return true for the bypass confirmation despite ANSI redraw noise."""
    # "2. Yes, I accept" is the accept option of the bypass-mode warning.
    return b'yes,iaccept' in _clean(raw_bytes).lower()


class BypassGate:
    """Detect the bypass prompt over arbitrarily split PTY reads once."""

    def __init__(self):
        self.recent = b''
        self.accepted = False

    def feed(self, data):
        if self.accepted:
            return False
        self.recent = (self.recent + data)[-8192:]
        if not _looks_like_bypass_prompt(self.recent):
            return False
        # Mark first so redraws cannot inject a second Down+Enter pair.
        self.accepted = True
        self.recent = b''
        return True


def _accept_bypass_gate(gate, fd, data):
    """Send the already-decided bypass answer exactly once."""
    if not gate.feed(data):
        return False
    try:
        time.sleep(0.3)
        os.write(fd, b'\x1b[B')  # Down: select "Yes, I accept".
        time.sleep(0.2)
        os.write(fd, b'\r')      # Enter: confirm.
    except OSError:
        pass
    return True


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
    dlg_buf = b''
    trust_done = False
    bypass_gate = BypassGate()
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
                if not (trust_done and bypass_gate.accepted):
                    dlg_buf = (dlg_buf + data)[-8000:]
                    txt = _clean(dlg_buf)
                    if (not trust_done) and b'trustthisfolder' in txt.lower():
                        time.sleep(0.4)
                        os.write(fd, b'\r')
                        trust_done = True
                        dlg_buf = b''
                    elif _accept_bypass_gate(bypass_gate, fd, data):
                        dlg_buf = b''
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
