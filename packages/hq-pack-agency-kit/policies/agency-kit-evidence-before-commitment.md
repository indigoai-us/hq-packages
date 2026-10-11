---
id: agency-kit-evidence-before-commitment
title: Agency findings cite their evidence, and nothing becomes a client commitment without a strategist's approval
when: client-onboarding || audit || kickoff || weekly-update || proposal || scope-check || agency-kit
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
scope: pack:hq-pack-agency-kit
tags: [agency-kit, evidence, approval]
public: true
version: 1
created: 2026-10-09
source: pack:hq-pack-agency-kit
---

## Rule

1. Every finding, number and recommendation an agency-kit skill writes cites its
   source: the file and the section, timestamp or rows it came from. A claim
   with no source is left out.
2. Numbers are calculated from the data provided, and the calculation is shown.
3. When the data cannot support a conclusion, write "Not supported by the data
   provided" and name the data that would settle it. Never estimate, project or
   assume to fill the gap.
4. Briefs, audits, kickoff packages, updates, proposals and replies are drafts.
   None becomes a client commitment, and none is sent, until a named strategist
   or account lead approves it in the session. Sending is a separate approved
   action under `client-service-approval-gate-external-actions`.
5. When the contract and anything else disagree, the contract wins and the
   difference becomes an open question with an owner.

## Rationale

An agency's AI output is only as useful as a strategist's ability to check it.
Sourced findings can be checked in minutes. Unsourced ones have to be redone,
and a confident wrong number in front of a client costs more than the time AI
saved.
