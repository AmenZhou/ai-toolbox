---
title: >-
  <Deck title>: guidance
category: <folder category>
tags: [slides, guidance]
sources:
  - <each source file or note the deck rests on, with the date it was read>
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
summary: >-
  Guidance for the deck <file>.html: purpose, key points, storyline, how results are counted, wording and decisions.
status: draft            # draft until the owner says yes to sections 2 and 3; then approved
---

<!-- TEMPLATE. The sample text and numbers below belong to the made-up herb-trial deck in template.html,
     so that check_deck.py --selftest passes. Replace everything, keep the 11 numbered sections. -->

# Guidance: <deck title>

Deck: `<file>.html` in this folder. Read this before editing it. If a request conflicts with this spec, ask, then update the spec.

## 1. Purpose and audience
1. Walk a busy reader through the herb trial, step by step.
2. Compare how often each method keeps a herb alive.

Audience: someone who was not in the project. They read the main slides in five minutes.

## 2. Key points and structure
Main slides: at most 10 (fewer is fine). Then a divider and an appendix A1..An.
Main slides that may show numbers: 6
Rules: numbers live in the appendix; a main slide that states a finding links to the appendix slide that proves it; 10 is a ceiling, never a target: add a slide only for a message that needs it.

| # | Message | Main | Proof |
|---|---|---|---|
| 1 | A herb on a windowsill can fail in four ways | 2 | A1 |
| 2 | Light decides the result, and a lamp helps most | 3–5 | A1–A2 |
| 3 | On checked pots a lamp keeps most herbs alive | 6 | A2 |
| 4 | Key challenge: some pots cannot be judged | 7 | A2 |
| 5 | Growers use light, a plan and a log; we have gaps | 8 | A3 |
| 6 | Decisions: start with mint, add a lamp, decide how a doubtful pot counts | 9 | A1–A3 |

## 3. Storyline
| Slide | Content | Must answer |
|---|---|---|
| 1 | Cover with index | What this is; where to find each slide |
| 2 | Why | What can go wrong |
| 3 | The journey | For each step: we asked, we learned, so we |
| 4 | Steps 1–2 | What we did, learned and decided |
| 5 | What we found | The four findings |
| 6 | Success by method | One row per set of pots, same pots for each method |
| 7 | Challenges | Pots nobody could judge; the choice for the owner |
| 8 | Practice and our gaps | Practice, our trial today, what to apply |
| 9 | Decisions | What was decided and what is open |
| A1 | The brief, in three lines | |
| A2 | Results by trial | |
| A3 | Our opinion | |

## 4. How results are counted
1. **Readable pots only.** A pot nobody could judge is in no rate. It is named as a challenge, never as a success or a failure.
2. **Healthy** = a clear verdict from the grower. **Stunted** = a clear verdict of poor growth.
3. Show "cannot judge" next to a rate, never inside it.
4. Give one rate with its count and the 95% range, such as "75% (18 of 24), range 55–88%".
5. Compare methods only on the same pots. Never rank trials against each other.

### Numbers of record
| Trial | Pots | Window alone | Lamp alone | Either one (not built) | Stunted | Who checked | Weakness |
|---|---|---|---|---|---|---|---|
| A | 24 | 75% (18 of 24), range 55–88% | 92% (22 of 24), range 74–98% | 96% (23 of 24), range 80–99% | window 1, lamp 2 of 40 | one grower | one kitchen |
| B | 12 | 50% (6 of 12), range 25–75% | 67% (8 of 12), range 39–86% | not worked out | window 0, lamp 1 of 30 | nobody | small; nobody checked |

Other figures: 40 pots in the window trial, 30 in the lamp trial; 3.3% stunted (1 of 30); USD 12 for lamps and soil.

### Sources
| Item | Source |
|---|---|
| Trials A and B | `<path to the grower's log>`, read <date> |

## 5. What stays off the slides
- Implementation detail unless the main point needs it: task numbers, ticket numbers, merge requests, version codes.
- Any web address or private data. Counts only.
- Speculation about causes that nobody verified.
Banned patterns: \bgrower'?s? notebook\b || \bguaranteed\b
<!-- Banned patterns: one line, plain regular expressions separated by " || "; the check adds them to its built-in list. -->
<!-- Section 2 needs the line "Main slides that may show numbers: <list>" (or "none"), exactly as above. -->
<!-- A number you derive (a difference, a share) may be listed in section 4 as "derived: <sum>" beside its source figures. -->
<!-- Who checked a label: if the source does not say, write "not stated". Never guess a checker. -->

## 6. Wording
- Written for a busy reader who was not in the project: main point first, plain words, short sentences.
- Title = the finding, not the topic. One idea per slide.
- Say "our tests do not show" or "no clear difference" when a test does not show it. Never "proven".
- Explain a term at first use.

## 7. Look
- One HTML file, fixed 1920×1080 stage, dark navy and light cream slides; gold only for rules, headline emphasis and numerals.
- Reuse the layouts of `template.html`. Text must fit without scrolling or overlap.

## 8. How to edit
1. Back up the deck and this spec (copy, do not overwrite a backup).
2. Change text with exact edits that stop if an anchor is missing.
3. If editable text on a slide changed, give that slide a new `data-edit-key`. Footer and header text is not editable.
4. If slides move, update the counters, every "slide N" reference, both indexes and the `#` links.
5. Update this spec when a number, rule or slide changes.

## 9. Done means
- [ ] The main part has at most 10 slides, and only the slides named in section 2 show numbers.
- [ ] Every number is in section 4.
- [ ] No unreadable pot is inside a rate.
- [ ] No item from section 5 is on a slide.
- [ ] `check_deck.py` passes, and every slide was looked at on screen.
- [ ] Open decisions on slides 7 and 9 are still open.

## 10. Decisions
| Date | Decision |
|---|---|
| 2026-01-10 | Start with mint |

## 11. Open
- How a doubtful pot counts (owner).
- Budget for lamps.
