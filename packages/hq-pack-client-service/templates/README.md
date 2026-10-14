# templates/

Firm-neutral templates the skills instantiate into an installing firm or into a
client company. Templates carry no firm's branding, vendor names, or identifiers.

- `handover-checklist.md` (US-005) — staged by `/new-client` into the **client**
  company as `companies/{client}/handover-checklist.md`, and the executable
  runway for `/handover-client` (US-011): client team invited and active, firm
  packs in their desired end state, secrets rotated or removed, ACLs and shares
  revoked, commercials closed, sign-off. It lives in the client's company, so it
  is client-visible by construction and carries nothing firm-internal.
  Placeholders: `{{CLIENT_NAME}}`, `{{CLIENT_SLUG}}`, `{{FIRM_NAME}}`,
  `{{TODAY}}`, `{{INVITE_STATUS}}`. An already-staged checklist is a human's
  working file and is never overwritten.

The engagement template is **not** a file here. `/onboard-firm` writes it
directly to `companies/{firm}/clients/_templates/engagement.template.md` so the
firm owns and edits its own copy; `/new-client` instantiates **that** file, never
a pack-side one. Placeholders it fills: `{{CLIENT_NAME}}`, `{{FIRM_NAME}}`,
`{{CLIENT_SLUG}}`, `{{FIRM_SLUG}}`, `{{TODAY}}`.
