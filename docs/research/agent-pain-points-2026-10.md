# A third pass: what people using coding agents complain about now (2026-10-07)

The earlier passes (`terminal-pain-points.md`) were about terminals. This one
is about the agents themselves and the work around them, to decide what the
next release should build.

## How far to trust it

- Most-reacted open issues on `anthropics/claude-code`, `openai/codex` and
  `sst/opencode`, read from GitHub's reaction-sorted lists. The pages give the
  order, not reliable counts, so rank here means "near the top", not a number.
- Web search over blog write-ups, Hacker News and Reddit summaries, product
  pages and a few papers. Hacker News itself could not be opened from here, so
  threads are known only through the write-ups that cite them. Reddit was not
  read directly.
- Several figures are secondhand or from vendors (marked below). Treat the
  themes as strong and the numbers as weak.

## The complaints, ranked

1. **Usage runs out and nobody can say where it went.** The most repeated
   theme in every source. Claude Code: instantly hitting Max limits (#16157),
   limits exhausted abnormally fast since March (#38335), a version that
   inflates cache creation by about 20K tokens for the same payload (#46917).
   Codex: layered five-hour and weekly windows with allowances that are hard to
   predict (#34035). Gemini CLI counts one prompt as 5 to 15 requests. People
   switch agents mid-session when they hit a wall.
2. **Hitting the wall stops the work.** Claude Code #13354 asks to continue
   when the session limit is reached; OpenCode #7602 asks for model failover.
3. **Approval fatigue.** Anthropic is quoted as saying users approve 93% of
   permission prompts (secondhand, not confirmed at the source). The usual
   escape is skipping permissions entirely, which removes the audit trail too.
   Related: a prompt that fires on `cd` instead of the real command in a
   compound shell line (#28240), a classifier for auto-approval (OpenCode
   #37564), sandboxing the agent (OpenCode #2242), approving in a diff
   (Codex #2998).
4. **Reviewing what the agent did is the new bottleneck.** A 2026 Sonar survey
   is cited for 96% of developers not fully trusting AI code (vendor report). A
   CHI '26 paper on verification load and fatigue finds rejection streaks and
   overconfident snippets push people to stop reviewing. Proposed fix in the
   literature: look at evidence of trustworthiness, not raw output.
5. **Agents say it is done when it is not.** Claims of completed edits that
   were not made, ignored "no", context rot in long sessions.
6. **One instruction file per agent.** Claude Code does not read `AGENTS.md`
   (#31005); Codex wants nested `AGENTS.md` loading (#12115).
7. **Running several agents.** Worktrees isolate files but not ports,
   databases or `.env`; agents forget to enter the worktree; people lose track
   of which terminal is on which branch; five or so agents is where it stops
   paying.
8. **Knowing from a phone.** A crowd of small products exist for "alert me
   when an agent needs me", and the stated want is to answer, not only be told.
   Codex #3962 asks for a sound when a task finishes.
9. **Carried over, still the most-reacted terminal complaint:** the view
   jumping or flickering while an agent streams (Claude Code #826, #1913,
   #769).

## Where Octet stands

| Complaint | Today | Gap |
| --- | --- | --- |
| Usage (1) | Usage meters, weekly pace, reset countdown, a rate graph, model policies that step down at thresholds | No answer to "which conversation spent it" |
| The wall (2) | Limit card with a countdown; model policies | Cannot continue the task in another agent, or resume by itself at the reset |
| Approvals (3) | Allow, Deny and allow-for-session on each prompt; quick-answer panel | No permanent per-project rules to review or remove |
| Review (4) | Diff review with comments, session changes, checkpoints, rewind | Nothing says where to look first, or whether the last edit was ever tested |
| Done but not (5) | Recap shows files, commands and failures per run | No "edited after the last test run" signal |
| Instruction files (6) | None found in code | Not handled |
| Several agents (7) | Workspaces, worktree env copy and setup script, agents board, Recap | Ports per worktree (open since the second pass) |
| Phone (8) | ntfy push, sounds, Remote Control | One-way: cannot answer from the phone |
| Flicker (9) | Native conversation view avoids repainting | Terminal path unchanged |
| Multiple accounts, rewind, paste cleanup | Done | None |

## What the next release should build, in order

1. **Hand off and resume.** On the limit card: *Continue in…* another installed
   agent (a summary, the todo list and the diff carried into a new
   conversation), and *Resume when it resets*, which sends "continue" at the
   countdown's end. The same handoff answers context rot: start fresh with a
   summary. Everything it needs already exists: the limit card, fork, todos.
2. **Where the usage went.** A ranked list of conversations by tokens and cost
   in the current window, with the biggest cache-creation jumps flagged, in
   the usage view. Uses numbers each conversation already keeps.
3. **Share instructions across agents.** One click makes `AGENTS.md` the
   source and has `CLAUDE.md` import it, and warns when the two drift. Small,
   and exactly what a cross-agent app is for.
4. **Tested since the last edit.** On a finished run in Recap and in the
   conversation header: edited files, then no test command after the last edit.
   Evidence instead of a claim, from transcript data Recap already reads.
5. **Always-allow rules.** An *Always allow in this project* button on the
   prompt, writing the agent's own allow rule, and a list of rules per project
   to review and remove.

Worth verifying before building anything on it: Codex #28969 reports that a
question left unanswered for 60 seconds resolves itself. If that holds in the
app-server mode Octet uses, someone who steps away answers by default.

## Sources

- Reaction-sorted open issues: [anthropics/claude-code](https://github.com/anthropics/claude-code/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc), [openai/codex](https://github.com/openai/codex/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc), [sst/opencode](https://github.com/sst/opencode/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)
- Claude Code complaints: [The Register](https://www.theregister.com/2026/04/13/claude_outage_quality_complaints/), [Hongkiat](https://www.hongkiat.com/blog/claude-code-getting-worse/), [Cybernews](https://cybernews.com/security/claude-code-disregarding-developers-commands/), [Morph on Reddit](https://www.morphllm.com/claude-code-reddit), [HN: quality reports](https://news.ycombinator.com/item?id=47878905), [HN: getting worse?](https://news.ycombinator.com/item?id=47936579)
- Parallel agents: [DEV: keeping parallel agents apart](https://dev.to/sahil_kat/how-to-keep-parallel-coding-agents-from-stepping-on-each-other-e5g), [DEV: why multitasking breaks down](https://dev.to/johannesjo/why-multitasking-with-ai-coding-agents-breaks-down-and-how-i-fixed-it-2lm0), [Developers Digest](https://www.developersdigest.tech/blog/git-worktrees-claude-code-parallel-agents-guide)
- Limits and cost: [AI coding CLI pricing 2026](https://inventivehq.com/blog/ai-coding-cli-pricing-guide-2025), [Claude Code vs Codex vs Gemini CLI](https://intuitionlabs.ai/articles/claude-code-vs-codex-vs-gemini-cli-comparison)
- Review and verification: [The New Stack](https://thenewstack.io/agentic-ai-verification-impact/), [CHI '26: When Help Hurts](https://dl.acm.org/doi/full/10.1145/3772318.3791176), [Supervising AI coding agents](https://arxiv.org/pdf/2609.24234)
- Permissions: [Obsidian Security](https://www.obsidiansecurity.com/blog/dangerously-skip-permissions-what-it-does-and-how-to-contain-it), [scalex.dev](https://scalex.dev/blog/ai-agent-permissions/), [WorkOS](https://workos.com/blog/agent-permissions-blast-radius)
- Phone monitoring: [Tactic Remote](https://tacticremote.com/blog/2026-02-28-monitor-ai-coding-agents-on-phone), [Junction Panel](https://junctionpanel.dev/blog/what-ai-coding-agent-notifications-should-actually-tell-you/), [AgentsRoom](https://agentsroom.dev/blog/control-coding-agents-from-your-phone)
