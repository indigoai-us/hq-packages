---
id: hq-cross-device-deck-sync-pubnub-bridge
title: Sync a static-hosted deck + presenter notes across two devices via a PubNub REST bridge
scope: global
trigger: syncing a static-hosted deck and presenter notes across two devices with no backend
when: (deck || slide || presenter) && (sync || pubnub || broadcastchannel || cross-device || subscribe)
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-06-26
updated: 2026-06-26
source: session-learning
tags: [frontend]
---

## Rule

ALWAYS: to sync a static-hosted deck + presenter-notes across TWO devices with no backend, bridge the existing same-device sync (BroadcastChannel/localStorage) to a public PubNub demo channel via REST — publish GET https://ps.pndsn.com/publish/demo/demo/0/<ch>/0/<urlenc-json>, subscribe by long-polling GET https://ps.pndsn.com/subscribe/demo/<ch>/0/<timetoken> (skip the first response's old messages, then loop on the returned timetoken). Gate the whole module on a ?sync=<room> URL param so the public audience URL never joins or hijacks; channel = 'prefix-'+room (both devices same room); echo-guard with a per-client random id; wrap in try/catch + setTimeout retry so it degrades to manual arrow nav. Expose window.__knApplyDeck / __knApplyNotes from each nav IIFE and hook window.__knPub into go(), guarded by a window.__knApplying flag to prevent echo loops.

## Rationale

A static-hosted deck has no backend to coordinate two presenter devices (e.g. a laptop driving and a phone/confidence monitor following). The existing same-device sync (BroadcastChannel/localStorage) only spans tabs on one machine. PubNub's public demo keyset gives a zero-backend pub/sub channel reachable over plain REST GETs, so the bridge ships inside the same static HTML. Gating on ?sync=<room> keeps the public audience URL inert (no join, no hijack), the per-client random id plus window.__knApplying flag prevent the apply→publish→apply echo loop, and the try/catch + setTimeout retry means a flaky network degrades gracefully to manual arrow navigation rather than breaking the deck. Captured from the AI Summit keynote deck.
