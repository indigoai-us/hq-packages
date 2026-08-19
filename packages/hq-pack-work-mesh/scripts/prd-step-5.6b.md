## Step 5.6b: Work-mesh genesis

After the board upsert, if `{co}` is a cloud-backed company (`cloudCompanyUid` in `companies/{co}/company.yaml`) and `core/scripts/hq-work-mesh-genesis.sh` exists, run it. Mesh write is the source of truth — do not skip because a desktop window is open.

```bash
bash core/scripts/hq-work-mesh-genesis.sh --company {co} {name}
```

Require exit 0. Confirm `companies/{co}/projects/{name}/fabric-genesis.json` has `channelId`. Fail the /prd step if genesis fails (do not silently leave a board-only project).

Skip when `{co}` is unset, the company has no `cloudCompanyUid`, the helper is missing, or the project is personal/HQ (no company mesh). Do not call another company's genesis script.
