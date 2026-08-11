#!/usr/bin/env python3
"""Validate an HQ issue-orchestrator configuration without external packages."""

from __future__ import annotations

import json
import pathlib
import re
import sys

REQUIRED_TOP = {
    "schemaVersion",
    "company",
    "agent",
    "mode",
    "goals",
    "nonGoals",
    "sources",
    "scope",
    "lifecycle",
    "permissions",
    "handoff",
    "schedule",
    "pilot",
}
WRITE_KEYS = {
    "comment",
    "createTickets",
    "changeStatus",
    "assign",
    "openDraftChanges",
    "merge",
    "deploy",
    "closeOrResolve",
}
SECRET_VALUE = re.compile(r"(?:xox[baprs]-|gh[pousr]_|sk_(?:live|test)_|AKIA[0-9A-Z]{12,})")
SECRET_KEY_NAME = re.compile(r"^[A-Z][A-Z0-9_]{2,127}$")


def fail(message: str) -> None:
    print(f"invalid: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: validate_config.py <config.json>")

    path = pathlib.Path(sys.argv[1])
    try:
        raw = path.read_text(encoding="utf-8")
        config = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        fail(str(exc))

    if not isinstance(config, dict):
        fail("root must be an object")
    missing = sorted(REQUIRED_TOP - config.keys())
    if missing:
        fail(f"missing keys: {', '.join(missing)}")
    if config["schemaVersion"] != 1:
        fail("schemaVersion must be 1")
    if not isinstance(config["company"], str) or config["company"] == "COMPANY_OR_PERSONAL":
        fail("company must be a resolved company slug or personal")
    agent = config["agent"]
    if not isinstance(agent, dict) or not isinstance(agent.get("id"), str) or agent.get("id") == "AGENT_ID":
        fail("agent.id must identify a resolved existing agent")
    if not isinstance(agent.get("displayName"), str) or agent.get("displayName") == "AGENT_NAME":
        fail("agent.displayName must be resolved")
    if config["mode"] not in {"pilot", "active", "paused"}:
        fail("mode must be pilot, active, or paused")
    if not isinstance(config["goals"], list) or not config["goals"]:
        fail("goals must contain at least one measurable goal")
    if not isinstance(config["nonGoals"], list) or not config["nonGoals"]:
        fail("nonGoals must contain at least one explicit boundary")
    if not isinstance(config["sources"], list) or not config["sources"]:
        fail("sources must contain at least one source")
    for source in config["sources"]:
        required_source = {"id", "type", "locator", "secretKeys", "readPolicy", "identityKey", "canonicalLocation"}
        if not isinstance(source, dict) or not required_source <= source.keys():
            fail("each source needs id, type, locator, secretKeys, readPolicy, identityKey, and canonicalLocation")
        if not isinstance(source["id"], str) or not source["id"]:
            fail("source.id must be a non-empty string")
        if not isinstance(source["type"], str) or not source["type"]:
            fail("source.type must be a non-empty string")
        if not isinstance(source["secretKeys"], list) or not all(
            isinstance(key, str) and SECRET_KEY_NAME.fullmatch(key) for key in source["secretKeys"]
        ):
            fail("source.secretKeys must contain uppercase HQ secret key names only")
    permissions = config["permissions"]
    if not isinstance(permissions, dict) or not {"read", "classify"} | WRITE_KEYS <= permissions.keys():
        fail("permissions is incomplete")
    if not all(type(permissions[key]) is bool for key in {"read", "classify"} | WRITE_KEYS):
        fail("every permission must be a boolean")
    if config["mode"] == "pilot" and any(permissions[key] for key in WRITE_KEYS):
        fail("pilot mode requires every write permission to be false")
    if permissions["merge"] or permissions["deploy"]:
        fail("merge and deploy are never pack-managed permissions")
    lifecycle = config["lifecycle"]
    if not isinstance(lifecycle, dict) or not isinstance(lifecycle.get("states"), list) or not lifecycle["states"]:
        fail("lifecycle.states must contain at least one state")
    if lifecycle.get("terminalRequiresHuman") is not True:
        fail("terminalRequiresHuman must be true")
    handoff = config["handoff"]
    if not isinstance(handoff, dict) or not isinstance(handoff.get("destination"), str):
        fail("handoff.destination must be a string")
    if not handoff["destination"] or handoff["destination"] == "DESTINATION":
        fail("handoff.destination must be resolved")
    if not isinstance(handoff.get("requiredFields"), list) or not handoff["requiredFields"]:
        fail("handoff.requiredFields must not be empty")
    if not isinstance(handoff.get("escalateOn"), list) or not handoff["escalateOn"]:
        fail("handoff.escalateOn must not be empty")
    schedule = config["schedule"]
    if not isinstance(schedule, dict) or schedule.get("kind") not in {"manual", "interval", "event"}:
        fail("schedule.kind must be manual, interval, or event")
    pilot = config["pilot"]
    if not isinstance(pilot, dict) or pilot.get("sourceWrites") is not False:
        fail("pilot.sourceWrites must be false")
    if SECRET_VALUE.search(raw):
        fail("configuration appears to contain a credential value; store key names only")
    scope = config["scope"]
    if not isinstance(scope, dict):
        fail("scope must be an object")
    max_items = scope.get("maxItemsPerRun")
    max_work = scope.get("maxConcurrentWork")
    if not isinstance(max_items, int) or not 1 <= max_items <= 100:
        fail("scope.maxItemsPerRun must be between 1 and 100")
    if not isinstance(max_work, int) or not 1 <= max_work <= 10:
        fail("scope.maxConcurrentWork must be between 1 and 10")
    sample_size = pilot.get("sampleSize")
    if not isinstance(sample_size, int) or not 1 <= sample_size <= max_items:
        fail("pilot.sampleSize must be between 1 and scope.maxItemsPerRun")

    print(f"valid: {path}")


if __name__ == "__main__":
    main()
