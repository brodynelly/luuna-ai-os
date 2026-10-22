# Roots as an optional Luuna intent layer

Use the name **Luuna Roots** (`luuna-roots`) for a maintained fork if the pilot succeeds. Keep attribution to the MIT-licensed upstream. The product role is human-owned intent: why a project exists, which goals serve others, and which tensions the developer has accepted. Missions owns work; Atlas owns verified learning; Beacon owns reusable prompts; Luuna owns execution authority.

Pilot in one repository before creating an installation or runtime dependency:

1. Record two or three human-authored goals in Roots.
2. Link one accepted goal ID to a Missions ticket without copying the human's prose into agent-owned data as if it were agent-authored.
3. During Luuna planning, display the relevant goal and its provenance. Store the goal ID and content revision/hash with the approved plan. A material change requires a new approval.
4. Let agents ask questions and propose edges; only the human accepts them. Do not treat Roots text or agent proposals as runtime policy.
5. Check native Windows interaction and worktree behavior. Roots currently reads `.seeds/` and `.mulch/` directly, so a supported Luuna fork or adapter must read `.luuna/missions/` and `.luuna/atlas/` through stable interfaces.

Keep Roots opt-in until this loop proves useful and its cross-component integration is verified.
