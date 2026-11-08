// The mod's $.state contract (lib/common.sh and mod/hooks/register.ts).
// watch: the artifact's URL when the task is an artifact watch (any label the CLI writes for one), which is not work in
// flight (register.ts ARTIFACT_WATCH)
export type BgTask = { type: string; status: string; watch?: string }

declare module 'claude-code' {
  interface PluginState {
    sala: {
      // what the last classic.Stop saw in flight (its background_tasks: type and status, and an artifact watch's URL)
      bg: BgTask[]
      // the session id the presence stamp was last written for
      stamped: string
      // the turns running now, from turn.start to turn.complete (main loop and subagents alike): the turn id and, for an agent loop, its agent id
      turns: { id: string; agent?: string }[]
    }
  }
}
