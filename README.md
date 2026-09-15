# skills

Claude Code plugins I use every day, packaged as a marketplace so they install
with one command and update in place. The same skills also install into any
agent (Cursor, Codex, Copilot, Windsurf, etc.) through the cross-agent
`skills` CLI.

| Plugin | What it gives you |
|---|---|
| `worktrees` | One isolated git worktree per branch, driven by `just` recipes, with per-worktree setup hooks (env files, deps, a forked database). |
| `ship` | `/build-ticket`: a ticket goes in, a reviewed draft PR comes out. Subagents build, review from three angles, fix, tidy, push. Ships with the skills it calls: `pr`, `review`, `ui-review`, `testing-review`, `testing`, `unslop`, `rodney-tips`. |

## Install

### Claude Code plugin

```
/plugin marketplace add DKeen0123/skills
/plugin install worktrees@dankeen
/plugin install ship@dankeen
```

Update later with `/plugin marketplace update dankeen`.

### Any agent, via the `skills` CLI

[`skills`](https://github.com/vercel-labs/skills) discovers all nine
skills in this repo (`build-ticket`, `pr`, `review`, `ui-review`,
`testing-review`, `testing`, `unslop`, `rodney-tips`, `worktrees`) and
installs them by bare name into whichever agents you target — no Claude Code
required.

```bash
npx skills add DKeen0123/skills                                              # interactive pick
npx skills add DKeen0123/skills --skill build-ticket --agent claude-code cursor
npx skills add DKeen0123/skills --all                                        # every skill, every agent
npx skills add DKeen0123/skills --all -g                                     # install globally (user-level)
npx skills add DKeen0123/skills --list                                       # list without installing
```

`--agent` and `--skill` take space-separated names (see `npx skills add
--help`); `--all` is shorthand for `--skill '*' --agent '*' -y`.

**`worktrees` is the exception.** The `skills` CLI only copies `SKILL.md`
folders — it doesn't deliver `worktrees`' `just` module or shell scripts, so
installing that skill through the CLI gets you the reference doc but not a
working plugin. For `worktrees`, use the Claude Code plugin route above, or
clone this repo and copy `plugins/worktrees/` by hand (see
`plugins/worktrees/README.md`).

## What your repo needs

The skills read project facts from your repo's `CLAUDE.md` rather than
guessing. Each plugin's README lists the facts it depends on.

## Layout

```
.claude-plugin/marketplace.json   the catalogue
plugins/<name>/.claude-plugin/plugin.json
plugins/<name>/skills/<skill>/SKILL.md
skills.sh.json                    groups skills by plugin on the skills.sh listing page
```

Each plugin has its own README.

## License

MIT
