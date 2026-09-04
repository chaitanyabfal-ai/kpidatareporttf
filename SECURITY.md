# SECURITY.md — read this before you push anything

Scanning the uploaded repo found **three separate secret exposures**, plus a
638 MB data-bloat problem. All are fixed *going forward* in this package
(`.gitignore`, redacted docs) but **git history still has the old versions**
until you clean it up. Only 2 commits exist so far, so this is cheap to fix
properly — do it before this ever becomes a public GitHub repo again.

## What was found

1. **`ilds-key-1787743292.pem`** — a live EC2 SSH private key, committed at
   the repo root and tracked in git.
2. **`.env`** — tracked in git (holds your bucket name / queue URL; low
   sensitivity by itself, but should never be tracked as a matter of habit).
3. **Real Garage S3 credentials in plaintext** inside `RUNBOOK.md` §5.3
   ("Required .env contents" example) — an actual `GARAGE_ACCESS_KEY_ID` /
   `GARAGE_SECRET_ACCESS_KEY` pair, not a placeholder. This is the most
   important one to rotate. (This package's `RUNBOOK.md` has been redacted
   to placeholders — the original in your repo/history still has the real
   values.)
4. **638 MB of CSVs** under `data/incoming_csvs/` (1,002+ files) committed
   to git. Not a secret, but it bloats every clone and push. Trimmed to two
   documented samples in this package.

## Rotate first (do this regardless of the git cleanup below)

- [ ] **EC2 key pair**: in the AWS console, deregister the key pair behind
      `ilds-key-1787743292.pem` and any instance using it. Relaunch with a
      new key pair or switch to SSM Session Manager (no key needed — the
      new `provision_aws_resources.sh` supports launching without
      `EC2_KEY_NAME` set).
- [ ] **Garage credentials**: in your Garage admin panel, revoke the access
      key shown in the old `RUNBOOK.md` and issue a new one. Put the new
      value only in a local, gitignored `.env` — never in a committed file.
- [ ] Check CloudTrail / Garage access logs for any use of these
      credentials you didn't expect, since the repo has been public.

## Clean the git history

With only 2 commits, the simplest fix is a fresh start rather than
history surgery:

```bash
# From a fresh clone of the real remote (not this download):
rm -rf .git
git init
git add -A                      # .gitignore in this package now excludes
                                 # .env, *.pem, and the bulk CSVs
git commit -m "Rebuild history without committed secrets"
git remote add origin https://github.com/chaitanyabfal-ai/kpidataingestreport.git
git push --force origin master  # rewrites the public history
```

If you'd rather preserve commit history, use `git filter-repo` (not the
older `git filter-branch`, which is slow and error-prone) to strip the
specific paths, then force-push:

```bash
pip install git-filter-repo
git filter-repo --path .env --path ilds-key-1787743292.pem --invert-paths
git filter-repo --path RUNBOOK.md --invert-paths   # or hand-edit + re-add
git push --force origin master
```

Either way: **rotating the credentials matters more than the history
rewrite** — a force-push doesn't un-leak something that was already public.

## Going forward

- `.gitignore` in this package blocks `.env`, `*.pem`, `kpi_data/`
  (the venv), caches, and bulk CSVs.
- `RUNBOOK.md` in this package has placeholders instead of real values —
  keep it that way; put real values only in your local `.env`.
- The EC2 path in `provision_aws_resources.sh` now uses an IAM
  **instance profile** instead of static IAM user keys, so nothing
  AWS-side needs to live in `.env` or user-data at all.
