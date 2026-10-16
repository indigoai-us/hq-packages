---
name: form-friction-audit
description: "Audit every form on the client's site: required fields, what each is used for, whether it matches the motion (trial or demo), and the analytics start-to-complete rate when the export has it. Recommends the fields to cut."
triggers:
  - form friction
  - audit the forms
  - too many fields
  - form audit
maturity: HQ-native (authored for this package)
---
# /form-friction-audit

## Method

1. List every form on the site: page, purpose (trial, demo, contact,
   newsletter), each field, whether it is required, and the button label.
   Quote the labels.
2. From the product details and the CRM export, note what each field is
   used for downstream. A field nobody reads is a cut. A field sales asks
   for on the first call anyway is a cut.
3. Match the form to the motion. The playbook's rule: a trial takes email
   and password at most; a demo request takes name, work email and company.
   Phone, company size and "how did you hear" are findings.
4. If the analytics export has form starts and completes by page, compute
   the completion rate per form and the drop by device.
5. Write `reports/{YYYY-MM-DD}-form-audit.md`: a table (form, fields,
   required count, completion rate or "not in the data"), one finding per
   form, the recommended field list, and the metric to watch after the
   change.

## Rules

- Never cut a field that compliance or billing needs; ask when unsure.
- Rates only from the export; never estimate a completion rate.
- Fields the CRM shows as always empty are the strongest evidence.
