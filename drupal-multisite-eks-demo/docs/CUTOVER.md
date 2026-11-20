# Steps 17–20: Rehearsal, cutover and rollback (not executed)
1. Verify per-site mapping, private files, API integrations, cache/search replacements and security controls.
2. Run staging import and sequential per-site Drush deploy; record each result.
3. Rehearse full rollback with compatible code, database, files and configuration.
4. Set change freeze; capture final database/files deltas; pause writes during final sync.
5. Validate application paths, user login, accessibility, HTTP response, p95 latency, error rate and cron.
6. Switch traffic only after signed go/no-go; monitor, reconcile writes, retain Acquia fallback.
7. **Never assume Kubernetes rollout undo reverses database schema changes.**
