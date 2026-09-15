# claude-skills

Claude Code plugins I use every day, packaged as a marketplace so they install
with one command and update in place.

| Plugin | What it gives you |
|---|---|
| `worktrees` | One isolated git worktree per branch, driven by `just` recipes, with per-worktree setup hooks (env files, deps, a forked database). |
| `ship` | `/build-ticket`: a ticket goes in, a reviewed draft PR comes out. Subagents build, review from three angles, fix, tidy, push. Ships with the skills it calls: `/pr`, `/review`, `/ui-review`, `/testing-review`, `/testing`, `/unslop`, `/rodney-tips`. |

## Install

```
/plugin marketplace add DKeen0123/claude-skills
/plugin install worktrees@dankeen
/plugin install ship@dankeen
```

Update later with `/plugin marketplace update dankeen`.

## What your repo needs

The skills read project facts from your repo's `CLAUDE.md` rather than
guessing. Each plugin's README lists the facts it depends on.

## Layout

```
.claude-plugin/marketplace.json   the catalogue
plugins/<name>/.claude-plugin/plugin.json
plugins/<name>/skills/<skill>/SKILL.md
```

Each plugin has its own README.

## License

MIT
