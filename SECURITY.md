# Security policy

ClearScan is an alpha-stage, offline-first personal scanner. Scanned pages may
contain sensitive information, so privacy regressions are treated as security
issues.

## Reporting

Please use GitHub's private vulnerability reporting for this repository instead
of opening a public issue. Include affected versions, reproduction steps, impact,
and a minimal test document with all personal information removed.

## Sensitive data rules

- Native pages remain in the app container unless the user explicitly exports
  or uploads them.
- The companion backend stores data only in its configured local data directory.
- Google access tokens stay in memory and must not be written to logs or disk.
- OAuth Client IDs are public identifiers; client secrets, service-account keys,
  refresh tokens, and access tokens must never be committed.
- Apple certificates, private keys, provisioning profiles, Team configuration,
  and personal Bundle IDs stay outside Git.

The repository excludes `data/`, `work/`, `.env.local`, `Local.xcconfig`,
DerivedData, collaborator sandboxes, and signing artifacts by default.
