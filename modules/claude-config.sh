# ---- modules/claude-config.sh ----
# クラウドでは手元の ~/.claude/CLAUDE.md が読まれないため、claude/CLAUDE.md をユーザー規約として置く。
# Claude Code は root で動くので /root/.claude/CLAUDE.md になる
module_claude_config() {
  mkdir -p "$HOME/.claude" &&
  curl -fsSL --retry 3 -o "$HOME/.claude/CLAUDE.md" "$RAW_BASE/claude/CLAUDE.md"
}

check_claude_config() {
  if [ -s "$HOME/.claude/CLAUDE.md" ]; then check_ok "ユーザー規約 ~/.claude/CLAUDE.md"; else check_ng "ユーザー規約 ~/.claude/CLAUDE.md が無い"; fi
}
