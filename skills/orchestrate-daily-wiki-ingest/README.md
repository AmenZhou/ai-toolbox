# orchestrate-daily-wiki-ingest

Daily 6pm enqueue → tend runs this skill to ingest recent orchestration history into the Obsidian wiki and prune entries older than 30 days.

## Install

Included in `install-launchd.sh`:

```bash
PROJECT_DIR="$HOME/apps/my-project" bash skills/task-orchestrate/bin/install-launchd.sh
```

Manual trigger (enqueue only):

```bash
bash skills/orchestrate-daily-wiki-ingest/bin/enqueue-wiki-ingest-daily.sh
```

## Requires

- `OBSIDIAN_VAULT_PATH` in project `.env` or `~/.obsidian-wiki/config`
- `orchestrate-history/MANIFEST.md` and archive files in the project root
- tend (`com.orchestrate.tend`) to drain the inbox queue

## Output

- Wiki: `$VAULT/Orchestration/Daily/<YYYY-MM-DD>/`
- Pruned archives: `orchestrate-history/archive/`
