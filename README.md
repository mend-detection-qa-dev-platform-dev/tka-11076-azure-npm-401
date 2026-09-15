# TKA-11076 reproduction — Azure Artifacts npm credentials rejected (ERR_PNPM_FETCH_401)

Reproduces: Mend's PSB writes Azure Artifacts npm credentials into `.npmrc`, pnpm sends
them, and Azure returns 401 — while Mend's own connectivity check against the same feed
succeeds.

Customer shape (from TKA-11076 scanner logs):
- registry `https://pkgs.dev.azure.com/vista/_packaging/VistaShared-Npm/npm/registry/`, hostType `azure`
- pnpm workspace, lockfile up to date (`resolution step is skipped`)
- 401 on an **upstream-proxied public** package (`@types/react`), not a feed-native private one
- fails with both `_authToken` (Bearer) and `_password` (Basic)

---

## Part 1 — Azure DevOps setup (you)

### 1.1 Organization
Any Azure DevOps org. Note its name — it is used verbatim three times: in the feed URL, as
the `.npmrc` `username`, and as `<ORG>` below.

### 1.2 Artifacts feed
- **Artifacts → Create Feed**
- Name: `mend-qa-npm`
- Visibility: *Members of my organization*
- **Upstream sources: ENABLED, including `npmjs`** ← load-bearing. The customer's 401 is on
  `@types/react`, a public package proxied through the feed. Without upstream sources the
  repro doesn't match.

Feed URL will be:
`https://pkgs.dev.azure.com/<ORG>/_packaging/mend-qa-npm/npm/registry/`

### 1.3 PAT
**User settings → Personal access tokens → New Token**
- Scopes: **Packaging → Read** (nothing else)
- Expiry: 90 days
- Save the raw value. Azure DevOps PATs are ~52 chars, lowercase alphanumeric.

> Keep the **raw** PAT. Azure's npm docs tell you to base64-encode it for `.npmrc`
> `_password`, but Mend's host-rule field wants the raw secret. Which of the two Mend
> actually writes is precisely what is under test — do not pre-encode it when pasting into
> Mend.

### 1.4 Repo
Create an Azure Repos repository `tka-11076-azure-npm-401` in that org and push the
contents of this directory (see Part 2).

---

## Part 2 — Probe repo contents (this directory)

Minimal pnpm workspace that pulls a public package through the Azure feed.

1. `read -s PAT` then `ORG=detection-qa FEED=mend-qa-npm PAT="$PAT" ./generate-lockfile.sh`
   - writes `.npmrc` from `.npmrc.template` (credential-free, safe to commit)
   - generates `pnpm-lock.yaml`
   - runs two self-checks and refuses to pass unless both hold
2. Commit and push: `package.json`, `pnpm-workspace.yaml`, `packages/app/package.json`,
   `.npmrc`, `pnpm-lock.yaml`, `.whitesource`, `.gitignore`, `generate-lockfile.sh`, `README.md`.
3. **Never commit** `.npmrc.local` (gitignored) - it is the only file that holds the PAT.

### What routes the fetch to Azure

**The `registry=` line in `.npmrc`, NOT the lockfile.** pnpm lockfile v9 records integrity
hashes only and never registry or tarball URLs, so there is nothing Azure-specific in
`pnpm-lock.yaml` and there never will be. At install time pnpm derives
`<registry>/@types/react/-/react-19.2.18.tgz` from the configured registry. This is exactly
how the customer's scan reached their feed.

Verified baseline (2026-09-15, feed `detection-qa/mend-qa-npm`):

```
Lockfile is up to date, resolution step is skipped
 ERR_PNPM_FETCH_401  GET https://pkgs.dev.azure.com/detection-qa/_packaging/mend-qa-npm/npm/registry/@types/react/-/react-19.2.18.tgz: Unauthorized - 401
No authorization header was set for the request.
```

Note the last line. With **no** credential pnpm says `No authorization header was set`;
the customer's log says `An authorization header was used: Basic dmlz[hidden]`. That single
line distinguishes "Mend supplied nothing" from "Mend supplied something Azure rejected",
which is the question this repro exists to answer.

### Stage-0 result: SETTLED

`generate-lockfile.sh` authenticates with a **base64-encoded** `_password`, the form Azure
documents. **Confirmed working 2026-09-15** against `detection-qa/mend-qa-npm` - the lockfile
resolved with no error. So base64 `_password` is correct for this feed. If Mend's injected
credential is then rejected, Mend is encoding or sourcing it differently.

---

## Part 3 — Mend Developer Platform for Azure (you)

1. Onboard the Azure DevOps org/project into Mend DP for Azure.
2. Add the repo as a Mend project.
3. **Org-level host rule** (DP does NOT read `.whitesource` — this is the only place the
   credential can come from):
   - matchHost: `https://pkgs.dev.azure.com/<ORG>/_packaging/mend-qa-npm/npm/registry/`
   - hostType: `azure`
   - username: `<ORG>`
   - password (or token): the **raw** PAT
4. Trigger a scan.

### Variants worth running (cheap, and they localize the defect)
| # | Change | Distinguishes |
|---|---|---|
| A | host rule with **password** | the Basic / `_password` path (customer's Sept scan) |
| B | host rule with **token** | the Bearer / `_authToken` path (customer's July scan) |
| C | hostType **`npm`** instead of `azure`, same feed + credential | whether the `azure` branch is the defect — our Nexus probe uses `npm` and works |
| D | add a package published **directly** to the feed (not upstream-proxied) | whether only upstream-proxied packages 401 |

Variant **C** is the highest-value one.

---

## Part 4 — What to capture

From the scan's SCA log:
- `will handle host rules for [npm]` / `HandleHostRules for pnpm`
- `... - checking connectivity` and `connectivity check took: ...`
- `SCA_RESULTS_JSON` → `totalSuccess.CONNECTIVITY`, `totalFail`, `results.error`
- the `ERR_PNPM_FETCH_401` block, including `An authorization header was used: ...` and
  `These authorization settings were found:`

**Reproduced** = `ERR_PNPM_FETCH_401` present while `totalSuccess` carries `CONNECTIVITY: 1`.

**Not reproduced** = pnpm resolves. Then the defect is narrower than the ticket suggests —
likely specific to the customer's feed, PAT, or org config — and the SCA bug should say so.
