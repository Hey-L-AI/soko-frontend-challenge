# Make a good plan easier to find

## Goal

Improve the experience of discovering and choosing something to do in Lisbon.
We want to understand how you reason about usability, turn ideas into working Flutter
code, and use tools to check your decisions.

You have a working, simplified app with fictional data. You can change its UI, copy,
interactions and code structure. You do not need to recreate the full Soko app.

## Time box

Spend **at most eight hours total**, including research, coding, verification,
documentation and any bonus work. Stop at the limit and explain anything unfinished.
There is no reward for spending longer. Tell us roughly how you used your time.

Suggested allocation: 30 minutes setup, 60 minutes usability review, 30 minutes
prioritisation, four hours implementation, and two hours verification and handover.
The bonus is optional and must fit inside the same limit.

## 1. Review the experience

Imagine it is Friday, 25 September 2026. Your task:

> Find something you would enjoy doing in Lisbon this weekend, understand the
> practical details, and save it so you can return to it later.

Observe someone attempting this task for 10–15 minutes if a participant is readily
available. Do not coach them through the interface. Ask their permission before
recording; anonymous notes are sufficient.

If no participant is available, do a structured task walkthrough yourself and label
it as such. We do not expect recruitment or a formal research study. Clearly separate
observations, your interpretation, and assumptions that still need validation.

Identify **3–5 points of friction**. Use screenshots and concrete examples where useful.

## 2. Choose two improvements

For each, explain:

- What problem does it solve, and for whom?
- What evidence or observation led you to it?
- Why prioritise it over the other issues?
- What outcome would tell you that it helped?

Choose two changes small enough to finish within the time limit. We value clear
reasoning and thoughtful execution; neither change needs to be a large feature.

## 3. Implement both in Flutter

Make your changes in this standalone app. Keep the journey working: discover an event,
open its details, save it, find it in Saved, and remove it again.

The required target is **Flutter web**, reviewed at mobile and desktop widths. Consider
accessibility and relevant edge cases. Explain how you verified the changed behaviour;
add focused automated tests where they give useful confidence.

You may add packages or change the architecture if useful. You are not expected to
add a backend, authentication, maps, payments, deployment or native mobile builds.
Keep the app runnable with the provided local fixtures and no credentials.

## 4. Show how you used tools

Use AI assistance during the exercise, alongside whichever documentation, debugging,
design and testing tools help you. Any AI tool is acceptable; tell your interviewer
before starting if access is a problem so comparable access can be arranged.

Explain what you used, give a concrete example, and describe how you checked the
output. Mention anything you corrected or rejected if applicable. You are responsible
for the submitted work and should be able to explain its code and tradeoffs.

Short, sanitised agent-log excerpts are optional. Full private transcripts are not required.

## Deliverables

- Working Flutter application and clear run instructions.
- Completed `SUBMISSION.md`: usability findings, your two decisions, tool use,
  verification, time spent and known limitations.
- Before/after screenshots or a short demo recording.
- Source repository shared with the interviewer, or a source ZIP.

## Optional extra: prepare an A/B experiment

Put **one** improvement behind original and improved variants, using a separate
interview PostHog project. Define a hypothesis and success metric, demonstrate both
variants, and verify that the relevant events arrive. See [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md).

You do not need real users, statistical significance or a winning result. If a sandbox
is not available, include a short experiment design instead; do not spend the day
setting up infrastructure. A design note is useful but is not an implemented experiment.

## What we assess

| Area | Weight | What we look for |
| --- | --- | --- |
| Reasoning and UX | 35% | Evidence, prioritisation, coherent interactions, clear tradeoffs |
| Implementation | 35% | Working changes, readable Flutter code, appropriate scope |
| Verification | 20% | Checks that match the risks, edge cases, honest limitations |
| Tool use | 10% | Effective assistance, critical checking, ownership of the result |

The bonus is assessed separately and does not replace the core work. There is no
single correct pair of improvements. We will discuss your decisions in a short
follow-up and may ask you to make a small change to your implementation.
