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

# Claude Code shows a one-time interactive "Bypass Permissions mode" acceptance
# gate on every fresh --remote-control launch (claude >= ~2.1.x). Neither the
# ~/.claude.json `bypassPermissionsModeAccepted` flag nor IS_SANDBOX=1 suppress
# it in remote-control mode, and pty-spawn has no human to click it -> workers
# hang forever. Detect the gate in the output stream and send the accept
# keystroke once. ANSI cursor-positioning interleaves the menu text, so match on
# an ESC-stripped rolling buffer.
_ANSI_RE = re.compile(rb'\x1b\[[0-9;?]*[a-zA-Z]')
_GATE_ACCEPT_RE = re.compile(rb'(?i)yes.{0,4}i.{0,4}accept')
_GATE_CANCEL_RE = re.compile(rb'(?i)esc.{0,4}to.{0,4}cancel')


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

    gate_accepted = False
    gate_buf = b''

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
                if not gate_accepted:
                    gate_buf = (gate_buf + data)[-8192:]
                    stripped = _ANSI_RE.sub(b'', gate_buf)
                    if _GATE_ACCEPT_RE.search(stripped) and \
                            _GATE_CANCEL_RE.search(stripped):
                        # Menu defaults to option 1 ("No, exit"); move the
                        # selection down to option 2 ("Yes, I accept") then
                        # confirm. Number-jump is unreliable for this prompt.
                        try:
                            time.sleep(0.3)
                            os.write(fd, b'\x1b[B')
                            time.sleep(0.2)
                            os.write(fd, b'\r')
                        except OSError:
                            pass
                        gate_accepted = True
                        gate_buf = b''
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
