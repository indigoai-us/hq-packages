# The quality bar: how award sites are scored, the rubric, and the critic brief

This skill uses the Awwwards scoring system as its bar. It is public, detailed, and backed by
years of real scores. The goal is a site that would hold up in front of that jury. Submitting
is optional and up to the owner.

## The system (awwwards.com/about-evaluation, verified Oct 2026)

| Criterion | Weight | What reviewers actually judge |
|---|---|---|
| Design | 40% | Craft and control: the typographic system, layout and negative space, color and contrast, consistency, detail. Sites that feel "inevitable" score highest. Piling on effects reads as a lack of control. |
| Usability | 30% | Orientation in under 3 s, clear navigation, load time, responsiveness on real phones, accessibility (keyboard, focus, reduced motion), feedback on interaction. |
| Creativity | 20% | Originality with intent: an idea that could not be moved to another brand. Generic tropes are discounted. |
| Content | 10% | Real, specific copy and imagery integrated into the design. Placeholder content is noticed. |

- Honorable Mention starts at 6.5. Site of the Day is the highest score of the day, and recent
  winners average 7.2 to 7.6.
- The developer review looks for scores above 7 in six areas: **Semantics/SEO,
  Animations/Transitions, Accessibility, WPO (web performance), Responsive Design, and
  Markup/Meta-data.**

## Real scores of recent winners

| Site of the Day | Overall | Design | Usab. | Creat. | Content | Dev: Sem/SEO | Anim | A11y | WPO | Resp | Markup |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Maria Vasilyeva portfolio, Oct 2026 | 7.28 | 7.31 | 7.02 | 7.56 | 7.33 | 7.20 | 8.00 | 6.40 | 7.60 | 7.40 | 7.00 |
| LPAS architecture studio, Oct 2026 | 7.24 | 7.19 | 7.19 | 7.31 | 7.50 | 7.80 | 8.00 | 7.00 | 7.60 | 7.40 | 7.20 |
| TWKS agency (older) | 7.52 | 7.58 | 7.42 | 7.51 | 7.59 | 7.67 | 8.00 | 6.67 | 6.67 | 7.00 | 7.67 |

The pattern: **animations score highest (8.0), while accessibility and performance score
lowest.** A site that pairs this level of motion with real accessibility and performance is
ahead of the field. Only 3 of 11 top studio sites we probed shipped any
`prefers-reduced-motion` handling.

## What gets punished

- A polished template with no point of view. Effects bolted on rather than choreographed.
- Hard cuts or plain fades between states ("craft lives between states").
- A WebGL hero at 18 to 20 fps on a mid-range phone, a 9 MB page, a 6-second progress bar.
- Desktop-only thinking: a broken or squished mobile layout caps a site at Honorable Mention.
- A custom cursor that hides the native one, missing focus states, low contrast.
- A dead site: primary hovers that only swap a color, a concept that freezes the moment the
  visitor stops. Reviewers call it
  "static" or "a template" even when the frames are well composed.
- Lorem ipsum, stock imagery, machine-translated copy.
- Borrowed concepts: this season's horizontal gallery, the same distortion everyone ships.

## Critic's self-test (do this on your screenshots)

1. Screenshot the hero. Is the static frame strong on its own?
2. Throttle (4x CPU, slow 4G). Does it still paint quickly and hold its frame rate? `shoot.mjs`
   runs its mobile pass this way: read `mobile.vitals` and `mobile.scrollFps`.
3. Watch the transitions between states, not just between pages.
4. Toggle reduced motion. Is the site complete and calm?
5. Open it at phone width. Is it designed, or squished?
6. Point at things. Do the links, buttons and images answer in one voice? Leave the mouse
   still for five seconds. Does the concept still breathe?

## Score rubric (1 to 10, with evidence from specific screenshots)

Score as a skeptical critic. Every score needs evidence, for example: "d-01-hero: display type 18vw,
tracking -0.05em, optically aligned to the grid; the static frame works as a poster." No
evidence, no points.

**Design (40%)**
- 6: clean and consistent, but could be any template; safe type; uniform spacing.
- 7: a clear typographic system, an intentional palette, good hierarchy; one or two memorable compositions.
- 8: every frame composed; type used as image; rhythm varied on purpose; every detail designed (hover, focus, captions, footer, 404).
- 9: inevitable. Nothing to add or remove, and a visual language you could recognize from a crop.

**Usability (30%)**
- 6: works, but the loader is long, nav is unclear on some page, mobile is squished, or FPS drops.
- 7: fast, clear nav, mobile works, reduced motion is acceptable.
- 8: instant orientation, mobile composed for the hand, transitions never block, accessibility basics complete, 60 fps, every primary hover target answers in the motion verb (`h-*` pairs; `hover.noHoverChange` empty).
- 9: all of 8, plus delightful feedback everywhere and zero friction on every device.

**Creativity (20%)**
- 6: known patterns, competently assembled.
- 7: one idea specific to the subject, partially carried through.
- 8: the concept drives layout, motion and the signature moment; something reviewers haven't seen this month.
- 9: a new interaction idea that becomes a reference for others.

**Content (10%)**
- 6: placeholder-feeling or generic copy.
- 7: specific copy, honest imagery, a clear story.
- 8: copy with voice and real substance; case studies explain the problem, the idea and the outcome.

**Developer (each 1 to 10):** Semantics/SEO, Animations/Transitions, Accessibility, WPO,
Responsive, Markup/Meta-data. Use the `audit.mjs` and `shoot.mjs` reports as evidence.

Weighted overall = 0.4 Design + 0.3 Usability + 0.2 Creativity + 0.1 Content. Target 8.0 or
higher. Real reviewers score lower than any assessment from inside the build, so an 8 here is
roughly a competitive Site of the Day.

## Critic brief (for a fresh subagent on every QA pass)

The builder knows what it meant to build, so it scores intent instead of what's on screen. A
critic that sees only the evidence scores like a jury. Pass this brief to a fresh subagent,
filling in the three paths. Give it nothing else: no `DESIGN.md`, no code, no concept card, no
earlier scores, no notes on what you were going for.

```
You are an Awwwards juror reviewing a site you have never seen. You get only evidence.

Rubric:      <absolute path to references/quality-bar.md>, the "Score rubric" section
Screenshots: <absolute path to .shots/>. Each page has its own folder with a report.json;
             summary.json gives an overview. Prefixes: d- desktop 1440, m- phone 390,
             r- reduced motion, k- keyboard focus, d-90..92 page transition and back.
             h-NN-rest / h-NN-hover: one pointer target, clipped at the same
             coordinates, at rest and under the pointer (report.json hover.targets
             names each target, says whether it is primary and lists what changed).
Audit:       <absolute path to the saved audit.mjs output>

1. Open every screenshot. Before scoring, write in one sentence what you think the site's
   idea is. If you can't tell, say so: that is a Creativity finding, not a guess to make.
2. Score Design, Usability, Creativity and Content from 1 to 10, and each developer area
   (Semantics/SEO, Animations/Transitions, Accessibility, WPO, Responsive, Markup/Meta-data).
   Cite a screenshot file or a report field for every score. No evidence, no points. Start
   from 6 and make the evidence earn every point above it.
3. Weighted overall = 0.4 Design + 0.3 Usability + 0.2 Creativity + 0.1 Content.
4. List the fixes that would raise a score, most score gained first. Each one names the
   screenshot or field, what is wrong, and what to change. Be concrete ("m-03: the case-study
   title wraps to five lines at 390 px; drop the mobile display size to 14vw"), never generic
   ("improve the typography").
5. Judge interaction from the h- pairs and report.json `hover`. Primary targets in
   `noHoverChange` cost Design and Animations/Transitions points. `colorOnly`, `pixels` and
   `masked` are leads, not verdicts: open each pair. A fill that floods or inverts the whole button is
   a real treatment; a CTA, nav or project link whose text only changes color is not, and
   costs the same points.
   `desktop.idleMotion: false` is not a fault by itself: judge whether a concept this big
   should keep moving at rest. Things you can't judge from stills (how motion feels,
   sound) you leave out of the score. Don't assume they are good.

Reply with: the one-sentence idea, a score table with evidence, the weighted overall, and the
ranked fix list. Do not suggest a new concept; judge the one on screen.
```

The builder compares the critic's one-sentence idea with the Concept Card. If they don't
match, the site isn't saying what it means to say: fix the site, not the critic.

**Without subagents**, score it yourself under the same rules. Look at the screenshots before
rereading `DESIGN.md`, start every category at 6, and give no points without a cited file.
Say in the final message that the score is a self-score.
