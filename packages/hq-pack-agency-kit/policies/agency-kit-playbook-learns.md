---
id: agency-kit-playbook-learns
title: When a strategist catches something the process missed, update the agency playbook
when: client-onboarding || strategist || playbook || agency-kit
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
scope: pack:hq-pack-agency-kit
tags: [agency-kit, learning]
public: true
version: 1
created: 2026-10-09
source: pack:hq-pack-agency-kit
---

## Rule

When a strategist corrects an agency-kit output, or says the process should have
caught something, record it in `companies/{firm}/knowledge/agency-playbook/learnings.md`
and propose the matching change to the playbook file that should have caught it
(onboarding checklist, audit criteria, scope rules or examples). Write the change
only after the user agrees.

Lessons go into the firm's playbook, never into a client's company and never
into the pack itself, so each agency's process improves on its own.

## Rationale

The playbook is what makes the agency's process repeatable. A correction that
is not written back is lost, and the next client gets the same miss.
