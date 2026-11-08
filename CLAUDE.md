# MokaScreen — project conventions

MokaScreen turns a second MacBook into a low-latency extended display for the
first, over a Thunderbolt cable. The design brief lives in
`Docs/DESIGN_BRIEF.md`; read it before changing the pipeline.

## Indentation

- **Every source file is indented with tabs, not spaces.** This applies to
	all files in this project — Swift, Metal, shell, and this Markdown file
	included. One tab per indentation level. Alignment *past* the indentation
	may use spaces.

- This overrides any default or tool-suggested "4-space" indentation.

## Comments

- **Never write comments that restate what the code plainly does.**

- **Do comment the *why* behind non-obvious decisions:** platform bugs and
	workarounds (cite FB numbers where known), private-API quirks, ordering
	constraints, performance-motivated choices. Keep these precise and factual.

- **Doc comments (`///`) are required on all public types, public methods,
	and public properties.** Internal/private code gets `///` only when its
	purpose is non-obvious.

- **No hedging or narration in comments.** State facts.

- If you encounter code whose *why* you can't determine, flag it rather than
	inventing a rationale.

## Engineering

- Prefer systemic solutions over one-off workarounds.
- No kexts, no recoveryOS changes, no entitlements that need Apple approval.
	One of the two Macs may be MDM-managed, so MokaScreen must remain a plain
	user-space app.
- The hot path (capture → wire → present) runs on dedicated threads with
	blocking sockets. Keep allocation and locking out of it.
- The wire layer sits behind `ByteStream`; nothing above `Transport/` knows
	it is TCP.
