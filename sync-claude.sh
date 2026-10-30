#!/bin/bash
# 手元のユーザー規約 (~/.codex/AGENTS.md と ~/.claude/rules/*.md) から、クラウドに配る claude/CLAUDE.md を生成する。
# 手元の規約が正本。変更したらこれを実行してコミットし、main に push する。
# このリポジトリは public なので、生成結果に秘密情報・個人を特定できるパスが無いか差分で確認する。
set -euo pipefail
cd "$(dirname "$0")"

AGENTS="${AGENTS:-$HOME/.codex/AGENTS.md}"
RULES_DIR="${RULES_DIR:-$HOME/.claude/rules}"

mkdir -p claude
{
  echo '<!-- 生成物: ./sync-claude.sh で手元の ~/.codex/AGENTS.md と ~/.claude/rules/ から生成。直接編集しない -->'
  echo
  # @import はクラウドで解決できない手元のパスを指すため除く (RTK.md は rtk 用でクラウドに不要)
  # 末尾の @import 行を除くと空行が残るので、それを次の節との区切りにする
  grep -v '^@' "$AGENTS"
  # 手元では settings.json の language と UserPromptSubmit hook で指定しているが、クラウドには持ち込めないためここに書く
  echo '## 言語'
  echo
  echo '- ユーザーに見える文章（返答・途中経過・報告・計画・質問・タスクリスト）はすべて日本語で書く。英語の資料・ツール出力を読んだ後や会話の圧縮後も日本語を保つ。英語のままにしてよいのはコード・識別子・パス・コマンド・エラー文の引用だけ。'
  echo
  # この CLAUDE.md はクラウドにだけ置くため、クラウド固有の手順もここに書く
  echo '## クラウド環境'
  echo
  echo '- セッションで最初の依頼に取りかかる前に `cloud-env-check` を1回実行する。`NG` の行があれば、その内容と対処をユーザーに報告してから作業する。全部 `OK` なら報告は不要。'
  echo '- `cloud-env-check` が無い場合は、cloud-dev-env の setup が動いていないか古いので、その旨を報告する。'
  for f in "$RULES_DIR"/*.md; do
    [ -f "$f" ] || continue
    # paths 指定の frontmatter を持つルールは条件付き読み込みのため、常時読まれる CLAUDE.md には混ぜない
    if [ "$(head -1 "$f")" = '---' ]; then
      echo "skip (frontmatter): $f" >&2
      continue
    fi
    echo
    # ルールの見出しを1段下げて、規約の節として並べる
    sed 's/^#/##/' "$f"
  done
} > claude/CLAUDE.md
echo "built claude/CLAUDE.md ($(wc -c < claude/CLAUDE.md) bytes)"
