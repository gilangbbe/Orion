// Docs/19 M1: the Codebase Model, its queries and the teaching logic moved to `OrionCore` so the
// iOS companion can link them without the analysis pipeline. Re-exported so every existing
// `import OrionCodeIntel` (CLIs, OrionAgent, the Mac app, tests) keeps compiling unchanged.
@_exported import OrionCore
