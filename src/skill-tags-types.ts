// ---------------------------------------------------------------------------
// Skill tag detection config (shared types)
// ---------------------------------------------------------------------------

export interface SkillTagDetectionConfig {
  skillsRoots: string[];
  skillReadToolNames: Set<string>;
  skillExecToolNames: Set<string>;
  skillBuiltinToolMap: Map<string, string>;
  skillEmitMetadata: boolean;
}
