# ---- modules/claude-config.sh ----
# クラウドでは手元の ~/.claude/CLAUDE.md が読まれないため、claude/CLAUDE.md をユーザー規約として置く。
# Claude Code は root で動くので /root/.claude/CLAUDE.md になる
module_claude_config() {
  mkdir -p "$HOME/.claude" &&
  curl -fsSL --retry 3 -o "$HOME/.claude/CLAUDE.md" "$RAW_BASE/claude/CLAUDE.md"
}
