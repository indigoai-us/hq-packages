#!/usr/bin/env python3
"""Regression coverage for the Slack-bot PTY bypass-permissions gate."""
import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "claude-pty-spawn.py"
SPEC = importlib.util.spec_from_file_location("claude_pty_spawn", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def main():
    gate = MODULE.BypassGate()
    writes = []
    original_write = MODULE.os.write
    original_sleep = MODULE.time.sleep
    MODULE.os.write = lambda fd, data: writes.append((fd, data)) or len(data)
    MODULE.time.sleep = lambda _seconds: None
    try:
        # The CSI color sequence and the actual prompt both arrive split
        # across reads, as they do when Claude redraws an interactive PTY.
        assert not MODULE._accept_bypass_gate(gate, 42, b'\x1b[?25l2. \x1b[3')
        assert not MODULE._accept_bypass_gate(gate, 42, b'2mYes, I acc')
        assert MODULE._accept_bypass_gate(gate, 42, b'ept\x1b[0m')
        assert not MODULE._accept_bypass_gate(gate, 42, b'2. Yes, I accept')
    finally:
        MODULE.os.write = original_write
        MODULE.time.sleep = original_sleep

    assert writes == [(42, b'\x1b[B'), (42, b'\r')], writes
    print("PASS: split ANSI bypass prompt accepted exactly once")


if __name__ == "__main__":
    main()
