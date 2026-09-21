# Terminal complaint corpus and Octet test plan

Collected 2026-09-21. **16 observations from 12 public sources, mapped to 14 acceptance scenarios.** Six additional leads are quarantined until their original content can be verified. This is a pilot corpus, not a market survey.

The main opportunity is reliable everyday terminal behavior with optional agent UI. Octet has promising session organization, recovery and explicit view switching, but search, clipboard routing, completion control and rendering boundaries need attention before we call those pain points solved.

## Files

- [corpus.json](corpus.json): machine-readable sources, observations, code assessments, tests and follow-up leads.
- [test-plan.md](test-plan.md): manual acceptance scenarios with expected behavior.
- [Earlier research](../terminal-pain-points.md): previous single-creator synthesis; kept separate because its raw source digest is absent.

## Latest implementation — second batch, 2026-09-21

- **Live Find:** the real engine probe exposed a 1,000-line snapshot cap. Cmd+F now uses full-buffer search and scrolls the live pane, with next/previous, match counts, bounded stale-content retries and pane-closed errors. Matches are not yet highlighted in the terminal.
- **Bottom anchoring:** font/cell changes trigger clipping relayout; blank space accepts terminal hit testing; hidden/minimized/fully occluded windows stop grid polling. Visible-window polling remains.
- **Verification:** an isolated engine probe found and revealed old/new Unicode matches beyond the snapshot cap. Native Find UI smoke and core tests cover paging, revisions, scroll offsets and failures. Full visual and battery acceptance remains open.

See [second-batch implementation and evidence](implementation-2026-09-21-batch-2.md).

## First implementation batch — historical, 2026-09-21

The first implementation batch is in the working tree:

- **Find:** Cmd+F opens the focused pane's retained output in a native searchable snapshot, with Refresh, next/previous and a truncation notice. Live-terminal highlighting and navigation remain open.
- **Completion control:** Settings → Agents now has an independent “Octet's Tab completions” switch. With it off, Tab hands the line to the shell; the shell then owns that line.
- **Clipboard:** Native paste/copy/select-all, selection paste, Services and drops respect held prompt input. Images insert their path into that line. Multiline/tab input uses bracketed handoff; pasted control bytes are filtered without breaking emoji. Editor/image socket writes are serialized.

Core regression tests and a native UI smoke test cover parts of T01, T02 and T10. Full live-shell acceptance remains pending; original assessment tables below describe the research baseline, before this batch. See [implementation notes](implementation-2026-09-21.md).

## Collection and evidence

Requested sources were Reddit, X, YouTube and other public discussions. Used web search/page retrieval because Chrome automation was not available in connected tools and the plugin search returned no relevant Chrome integration. No authenticated Chrome session was used.

Admitted source counts below are generated from the source records. Reddit page text was filtered to the relevant thread: recommended posts embedded below comments are not observations. GitHub issue state is recorded where available. No full posts, videos or transcripts are redistributed.

- reddit: 7
- github: 3
- personal_blog: 1
- vendor_forum: 1

Eleven sources have retrieved page text; one GitHub flicker report has only title/date/labels and an uninspected video attachment. The latter supports a report's existence, not a causal finding. Original YouTube pages failed retrieval; syndicated show notes and a mirror are leads only. X original content could not be verified. **There are no admitted X or YouTube observations yet.**

Dates are source dates where verified, otherwise null. Crawled/relative dates can disagree; collection date must never be substituted for publication date. Source text is paraphrased. Thread URLs are used where individual comment permalinks were not captured; the source notes identify the relevant comment when available.

## Priorities for Octet

These priorities are our product judgment based on task impact and static code review, not complaint frequency or a competitor benchmark. P1 means core-workflow/reliability work; P2 means discovery or a later usability improvement.

| Priority | Pain / corpus IDs | Octet assessment | Concrete next action |
| --- | --- | --- | --- |
| P1 | Search old output / P01–02 | Gap: TODO #12 and no session search integration found | Implement focused-pane scrollback Find with paste, next/previous and Escape; T01 |
| P1 | Clipboard consistency / P11 | At risk: native paste/select-all directly call engine bindings while Octet buffers input | Unify keyboard/menu/context/drop routes; T10 |
| P1 | Completion takeover / P03–04 | Whole editor can be disabled, but shell completion cannot be chosen independently | Add independent shell-completion control; validate aliases and remote context; T02–03 |
| P1 | Rendering, resize, image overlap / P12–13, P15–16 | Not proven by using a GPU renderer; session layer and native overlays matter | Run full-stack narrow-pane, Unicode, resize and graphics cases; T11–12, T14 |
| P1 | Session continuity / P10 | Features implemented; GUI reconnect, server loss and reboot have different guarantees | Verify identity/cwd and absence of duplicate sessions; T09 |
| P1 | Background battery / P08 | Polling is present; no evidence yet of actual excessive drain | Release-mode CPU/wakeups/RSS baseline before optimization; T07 |
| P1 | Agent/shell confusion / P05 | Terminal default and explicit switch help; transition interrupts terminal agent | Test dismissals, working-session confirmation, resume and unknown session IDs; T04 |
| P2 | Remote administration / P06 | Raw SSH is possible; dedicated host/session UI remains an opportunity | Validate demand and engine API before adding a host manager; T05 |
| P2 | Local control and predictable costs / P07, P09 | Optional UI helps; provider costs/limits still exist | Offline core-workflow check and clear provider-limit errors; T06, T08 |
| P2 | Window/tab ergonomics / P14 | Native chrome is implemented, interaction not verified here | Dense-tab and window-drag checks; T13 |

### Why these findings are credible—and limited

- The [Warp completion request](https://github.com/warpdotdev/Warp/issues/1811) asks for shell completion while retaining rich editing. Octet's single editor toggle addresses only part of that preference.
- A [kitty user reports copy/paste confusion](https://www.reddit.com/r/commandline/comments/1q09jr9/which_terminal_emulator_are_you_using_poll/). This does not demonstrate a kitty defect, but it motivates testing every entry route in Octet.
- A [Warp user reports idle battery drain](https://www.reddit.com/r/warpdotdev/comments/1vh2qfw/battery_drain_is_insane/). No measured battery value was available; Octet's timers are a reason to measure, not evidence it has the same defect.
- A [first-person migration report](https://blog.jamesbrooks.net/posts/migrating-from-iterm2-to-ghostty/) describes wrapping and resize problems. It does not isolate whether an emulator or agent caused them.
- The [Cursor forum image report](https://forum.cursor.com/t/attached-rendered-images-overlap-and-obstruct-terminal-cli-text-in-warp-macos/170046) supplies a concrete versioned reproduction. Octet's image-to-path paste feature does not prove inline image layout works.
- Historical [Ghostty search complaints](https://www.reddit.com/r/Ghostty/comments/1hp0kp0/command_fsearch_nonexistant/) describe a real workflow need, but [Ghostty 1.3 release notes](https://ghostty.org/docs/install/release-notes/1-3-0) confirm search shipped. Do not market the old omission as current.

## What Octet already has worth preserving

Static evidence shows terminal mode is the agent-opening default; explicit switching, a dismissible offer, native workspace/tab organization, agent notices and recovery exist. See AppSettings.swift, AgentOfferBanner.swift, WindowContext.swift, AgentRecoveryController.swift and README.md.

Keep these as **implemented but awaiting acceptance verification**. A free app does not remove external model costs, native code does not guarantee low energy use, and agent conversation recovery is not survival of an ordinary process through a reboot.

## How to run this corpus

1. Use a disposable session and test shell profiles; do not terminate live user sessions for recovery tests.
2. Record Octet commit/build, engine version, macOS/hardware/display scale, shell/dotfiles, agent version and editor/top-bottom settings.
3. Run [test-plan.md](test-plan.md). Store screenshots/logs and actual observations beside a dated result file.
4. Update test execution_status to pass, fail or blocked, with actual and artifact paths. All cases are currently not_run.
5. Treat a code change as coverage only after its scenario passes. Test both plain terminal and native conversation paths where relevant.

## Extending the sample

Next collection should use connected Chrome for original X posts and YouTube transcripts/comments. Resolve L01–L06; store a status/comment permalink or a timestamp, original date and a short paraphrase. Separate video creator statements from audience comments and disclose sponsorship/self-promotion.

Broaden beyond this Warp/Ghostty-heavy sample to iTerm2, Terminal.app, Windows Terminal, kitty, WezTerm and Alacritty, including satisfied-user counterexamples. Seek accessibility/IME, keyboard layouts, remote SSH, tmux, session restore, font migration and multi-display reports. Windows/Linux-only defects are compatibility inspirations, not automatically macOS Octet bugs.

Deduplicate by canonical thread and underlying incident. Multiple complaints from one thread can produce distinct tests but cannot be counted as independent demand. Recheck competitor release notes before describing any gap as current.
