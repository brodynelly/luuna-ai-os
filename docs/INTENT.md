# Roots as an optional Luuna intent layer

The [Luuna Roots](https://github.com/brodynelly/luuna-roots) fork is pinned in this suite. Its upstream history and MIT attribution are preserved. The product role is human-owned intent: why a project exists, which goals serve others, and which tensions the developer has accepted. Missions owns work; Atlas owns verified learning; Beacon owns reusable prompts; Luuna owns execution authority.

The CLI is available from the suite's source installer, but the runtime does not yet consume Roots. Pilot in one repository before making Roots a runtime dependency:

1. Record two or three human-authored goals in Roots.
2. Link one accepted goal ID to a Missions ticket without copying the human's prose into agent-owned data as if it were agent-authored.
3. During Luuna planning, display the relevant goal and its provenance. Store the goal ID and content revision/hash with the approved plan. A material change requires a new approval.
4. Let agents ask questions and propose edges; only the human accepts them. Do not treat Roots text or agent proposals as runtime policy.
5. Check native Windows interaction and worktree behavior. The fork now reads `.luuna/missions/` and `.luuna/atlas/` directly; verify these readers against the current component data contracts.

Keep Roots opt-in until this loop proves useful and its cross-component integration is verified.
