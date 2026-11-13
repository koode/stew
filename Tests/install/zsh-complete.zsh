#!/bin/zsh -f
# Prints the matches zsh's completion system offers for a command line, one per line.
#
#   Tests/install/zsh-complete.zsh FPATH_DIR 'stew needs --'
#
# Runs a throwaway interactive zsh (no dotfiles, its compdump in a temporary folder) in a
# pseudo terminal, with FPATH_DIR first on fpath, types the line and a tab, and reports
# what compadd was given.
fpath_dir="$1"
typed="$2"
work="$(mktemp -d "${TMPDIR:-/tmp}/stew-zsh-complete.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/init.zsh" <<INIT
PROMPT=''
fpath=(${(q)fpath_dir} \$fpath)
autoload -Uz compinit
compinit -u -d ${(q)work}/zcompdump
bindkey '^I' complete-word
zstyle ':completion:*' insert-tab false
stew-complete-done() { print -r -- STEW-COMPLETE-DONE; exit }
comppostfuncs=(stew-complete-done)
compadd() {
  # Calls that only collect matches into an array are not offers.
  if [[ \${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
    builtin compadd "\$@"
    return
  fi
  local -a stew_hits
  builtin compadd -A stew_hits "\$@"
  local stew_hit
  for stew_hit in \$stew_hits; do print -r -- "STEW-HIT:\$stew_hit"; done
}
print -r -- STEW-COMPLETE-READY
INIT

zmodload zsh/zpty || exit 2
zpty stew_complete zsh -f -i
zpty -w stew_complete "source ${(q)work}/init.zsh"
local line
local ready=0
for attempt in {1..50}; do
  zpty -r -t stew_complete line || { sleep 0.1; continue }
  [[ $line == STEW-COMPLETE-READY* ]] && { ready=1; break }
done
(( ready )) || { print -u2 "zsh did not start"; zpty -d stew_complete; exit 2 }
zpty -w -n stew_complete "$typed"$'\t'
local done=0
for attempt in {1..200}; do
  if ! zpty -r -t stew_complete line; then sleep 0.05; continue; fi
  line=${line%$'\r'}
  line=${line%$'\n'}
  line=${line%$'\r'}
  [[ $line == *STEW-COMPLETE-DONE* ]] && { done=1; break }
  [[ $line == *STEW-HIT:* ]] && print -r -- "${line#*STEW-HIT:}"
done
zpty -d stew_complete 2> /dev/null
(( done )) || { print -u2 "no completion result for: $typed"; exit 2 }
exit 0
