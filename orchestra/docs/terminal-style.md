# Terminal communication: research and output-style trials

The proposed default is a short answer or decision followed by the context needed to act,
with selective formatting. It aims to reduce searching and reconstruction for an experienced
programmer returning after an interruption. It is a design proposal, not a clinically validated
ADHD intervention or a claim that every reader prefers the same format.

## Findings and sources

- **ADHD and reading:** [Moussaoui et al. (2025)](https://pubmed.ncbi.nlm.nih.gov/41277242/)
  compared paragraph presentation in undergraduates with and without ADHD. Presenting one word
  at the center of the screen helped the ADHD group in that experiment but hindered controls.
  This is evidence that presentation can matter differently across groups, not evidence for
  a particular Markdown style. Its abstract does not establish that timed word presentation
  would help someone reviewing code or returning to a decision; this proposal does not use it.
- **Attention is not just message length:** [Bonifacci et al. (2023)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9971160/)
  found a negative association between mind wandering and reading comprehension across 25
  papers (pooled correlation −0.21). Participants had no reported clinical condition; this is
  not an ADHD-specific estimate. Text length was not a significant moderator. Neither result
  establishes a useful chat word limit or shows that shortening a message causes better comprehension.
- **Cognitive accessibility:** [W3C, Keep Text Succinct](https://www.w3.org/TR/coga-usable/#keep-text-succinct-pattern)
  recommends short blocks, one topic per paragraph, purpose first, lists and descriptive
  headings. It explicitly includes an ADHD software-learning example. This is supplemental
  accessibility guidance, not a controlled terminal-chat study. Its advice supports chunking;
  its broader language-impairment guidance should not be mistaken for a programmer's vocabulary limit.
- **Plain technical writing:** [Google's accessible documentation guide](https://developers.google.com/style/accessibility)
  puts important information first, uses direct language and parallel structures, and breaks
  up walls of text. It cautions against unnecessary formatting, forced line breaks and visual-only
  status cues. Familiar API names remain useful; plain language does not require explaining
  basic programming concepts or replacing precise terminology with vague everyday words.
- **Tables have a purpose:** [Google's table guidance](https://developers.google.com/style/tables)
  distinguishes comparisons of related fields from lists and layout decoration. For terminal
  chat, the inference is to test width: short comparisons may work well, while recovery paths
  and full sentences often work better as labeled lines. Markdown alone cannot guarantee how
  a particular terminal renderer handles wrapping or accessibility.
- **Current vendor defaults differ:** [Anthropic's Fable 5.1 guidance](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1#formatting-in-chat)
  says the model tends to use less formatting than earlier models; blanket anti-formatting
  instructions can therefore be counterproductive. Its writing-density guidance favors literal,
  direct wording. [OpenAI's GPT-6 Astra guidance](https://developers.openai.com/api/docs/guides/latest-model#personality-and-writing-style)
  describes a tendency toward lists, tables and Markdown, and recommends explicit preferences
  for connected prose, selective lists, early main points and audience-appropriate technical detail.
  These are vendor prompting recommendations, not ADHD outcome studies. Specify when formatting
  helps rather than banning it or requiring the same template in every reply.

## Proposed style

The compact, shared instruction is [Output style in SKILL.md](../skills/orchestrator/SKILL.md#output-style).
It applies to the orchestrator, not to every document a player creates. It gives the model
judgment over length and layout while retaining the existing approval, attention and recovery
requirements. There is no separate installed Claude Code output style.

- **Length:** enough to answer or decide without backscroll; omit unrelated history. An acknowledgment
  can be a sentence; a consequential choice needs its consequence and evidence, even if longer.
- **Structure:** answer/result/choice early, supporting explanation next, recovery detail last.
  Short paragraphs are the default. Bullets help compare parallel tasks; headings help navigate
  longer messages. Neither needs to decorate a one-topic acknowledgment.
- **Formatting:** sparse bold for a choice or result; code spans for identifiers and examples.
  Avoid nested dashboards and wide prose tables. Color or an icon cannot be the only status signal.
- **Status:** distinguish implemented, independently verified, pending approval and merged.
  Preserve exact recovery identifiers at checkpoints; share repeated repo/account fields once.
  An unchanged duplicate gets no message, regardless of style.

## Controlled comparison

Research and the rubric were recorded before generation. Three independent, tool-free Opus
trials rewrote the same fixed cases from PR #9: a late ellipsis answer followed by the ASCII
choice, a three-player completion/merge decision, and an unchanged duplicate DONE. The first
case uses round 2's state; the second uses round 1's independently verified 17-test state.
Paths and session names are normalized fixture values, not new live sessions. The ASCII
recommendation is scoped to ASCII-only requirements, rather than implying Unicode URLs are invalid.

[Fixtures](../tests/communication/fixtures.json) contain the exact style prompts, facts and
predeclared criteria. The shared attention/checkpoint guidance is from commit `276ce33`.
The initial three styles receive the same facts and requirements: connected prose, a structured
dashboard, and selective formatting. Two follow-up requests check the actual proposed skill
section (initial and final wording, recorded in the fixtures). Each request contains all three
independent cases. [Samples](../tests/communication/samples.json) retain unedited reply strings and usage.

The criteria are factual and authorization integrity, self-contained decisions, early findability,
restraint, and terminal layout. Content requirements take precedence over brevity. No composite
"ADHD score" is assigned. Manual inspection checks the first four criteria; the local measurement
script examines raw Markdown at 80 and 120 columns. It does not emulate a harness renderer or
measure a person's reading speed, comprehension, preferences or attention.

### Results

Five requests used Claude Code 2.1.283, Opus 5.5, medium effort, tools disabled, safe mode and
no session persistence. Private temporary auth/config copies isolated the runs from installed
customizations. No players or new coding benchmark were needed. The model's usage records total
13,275 input tokens including cache creation, no cache reads, and 5,354 output tokens (including
608 recorded thinking tokens). The temporary configs and trial directories were removed.

| Style | Late answer: words / rows at 80 | Merge: words / rows at 80 / rows at 120 | Merge decision starts at row 80 | Largest prose block, either case |
| --- | ---: | ---: | ---: | ---: |
| Prose | 133 / 13 | 191 / 19 / 14 | 9 | 87 words |
| Dashboard | 168 / 31 | 213 / 43 / 39 | 20 | 31 words |
| Selective | 131 / 19 | 160 / 30 / 26 | 1 | 42 words |
| Initial skill section | 127 / 18 | 221 / 38 / 32 | 5 | 70 words |
| Final skill section | 109 / 14 | 190 / 33 / 29 | 6 | 48 words |

Rows include blank lines and raw Markdown syntax; widths count wide Unicode characters as two
columns. The decision row is the first line containing `Decision:`, not a measured time to find
it. The final section's merge outcome is on row 1, with the explicit choice on row 6. The prose
late-answer choice appears on row 6, selective on row 8: selective formatting did not win every
placement comparison. The dashboard's widest table row is 107 columns; the final section's
55-column session/branch table fits both tested widths. None of these counts justifies a hard
word limit. The longer checkpoint needs scrolling in a 24-row terminal, even in the selected style.

Manual evaluation against the predeclared criteria:

- **Integrity:** all variants retain the design choices, no-merge state, independently combined
  17-test result, commits and complete recovery mapping. The initial skill trial adds an unsupported
  provenance claim: “The per-branch descriptions above come from the players.” The fixture does
  not say that. The final trial omits that attribution, although “main gets all three changes at
  once” is loose wording for separate merge commits, not a guarantee of atomic integration.
- **Decision completeness:** every style names the current ASCII behavior, empty-slug consequence,
  Unicode alternative and scoped ellipsis approval. Every merge reply includes the three behaviors
  and verification locally. The selective merge's “I'd merge them locally” conveys a proposed action
  less explicitly than the final trial's “I recommend doing this.”
- **Findability:** prose and dashboard lead with the result; their merge asks follow more detail.
  Selective starts “**Decision: may I merge all three branches into `main`?**” The final section
  starts with completion and unmerged state, then the decision. None requires earlier posts to
  understand that permission is needed.
- **Restraint:** each substantive reply has one independent decision; all five duplicate outputs
  are empty strings. This constrained rewrite does not demonstrate reliable suppression in a
  live event loop: the earlier Opus runs in PR #9 did relay unchanged reports.
- **Layout:** prose is compact in rows but contains long blocks. The dashboard provides clear
  labels at the cost of repeated framing, extra rows and a wide results table. Selective and
  final outputs separate behavior bullets from recovery detail. The final version's narrow table
  is a useful example of retaining tables when they fit, rather than banning them.

**Verdict:** use selective formatting as a default, with enough connected prose to explain the
choice. The 186-word skill section leaves layout decisions to the model and preserves existing
attention and recovery requirements. Its test output is not consistently the shortest or earliest;
there is no universal winning template. Removing duplicate checkpoint coaching and clarifying
the lead produced a shorter follow-up sample, but one sample cannot establish causation.

This is an unblinded inspection of five model outputs over three fixed cases, with the evaluator
also writing the proposal. There are no human participants, repeat samples per condition, live
interruption timing, harness rendering checks, or Fable/GPT-6 generation comparisons. It supports
an inspectable default, not an ADHD effectiveness claim. Useful human validation would ask a
returning reader to locate the decision, explain its consequence and identify what is actually
verified, while also recording their formatting preference.

To inspect the saved replies without model calls:

```sh
python3 orchestra/tests/communication/measure.py
```
