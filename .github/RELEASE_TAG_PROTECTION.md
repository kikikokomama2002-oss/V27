# Release tag protection

Production releases require an **ACTIVE GitHub repository tag ruleset** targeting `refs/tags/v*` with both `update` and `deletion` restrictions.

The canonical policy is `.github/RELEASE_TAG_PROTECTION.json`.

Apply that exact policy in GitHub Repository Settings → Rules → Rulesets before enabling releases. GitHub rulesets can target tags and can restrict both tag updates and deletions. The release workflow also fails closed when the canonical policy file is missing or malformed; the actual GitHub ruleset remains repository-level configuration and must be active.
