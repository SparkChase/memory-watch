#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
source_app="$project_dir/内存哨兵.app"
target_app="$HOME/Applications/内存哨兵.app"
if [[ ! -x "$source_app/Contents/MacOS/MemoryWatch" ]]; then
  "$project_dir/build.sh"
fi
if [[ -e "$target_app" ]]; then
  print "已存在 $target_app。请先退出并在 Finder 中移走旧版本，再运行安装。"
  exit 1
fi
mkdir -p "$HOME/Applications"
ditto "$source_app" "$target_app"
open "$target_app"
print "已安装并启动：$target_app"
