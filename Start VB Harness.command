#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC
#
# Double-click this file to start VB Harness on macOS.
# It checks for Git, Node.js and Ruby 3.3+. For each one that is missing it says what it is for and,
# only after you type y, installs it: Git with Apple's Command Line Tools, Node.js and Ruby with
# Homebrew (https://brew.sh). If that is not possible it opens the official download page instead.
# Then it runs: ruby exe/harness ui --open
# It never uses sudo itself; the Homebrew installer asks for your Mac password when it needs it.

set -u
cd "$(dirname "$0")" || exit 1

say() { printf '  %s\n' "$@"; }
ask() { local answer; read -r -p "  $1 Type y for yes or n for no: " answer; [[ $answer == [yY]* ]]; }
open_page() { say "The official download page opens instead: $1"; open "$1"; }
fail() { echo; say "$@"; echo; read -r -p "  Press Return to close this window. " _; exit 1; }

# A new Terminal window may not know where Homebrew puts its tools. Homebrew's Ruby is listed last
# so it comes first, ahead of the old Ruby that macOS ships.
use_brew_paths() {
  local dir
  for dir in /usr/local/bin /opt/homebrew/bin /usr/local/opt/ruby/bin /opt/homebrew/opt/ruby/bin; do
    [[ -d $dir && ":$PATH:" != *":$dir:"* ]] && PATH="$dir:$PATH"
  done
  export PATH
}

ruby_ok() {
  command -v ruby >/dev/null &&
    ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3") ? 0 : 1)' 2>/dev/null
}

# /usr/bin/git is only a placeholder until Apple's Command Line Tools are installed.
git_ok() {
  local git
  git=$(command -v git) || return 1
  [[ $git != /usr/bin/git ]] || xcode-select -p >/dev/null 2>&1
}

# Makes sure Homebrew is there, installing it with its official installer after a yes.
brew_ready() {
  command -v brew >/dev/null && return 0
  say "Homebrew is missing. It is the usual way to install developer tools on a Mac."
  ask "Install Homebrew now (from brew.sh, it asks for your Mac password)?" || return 1
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  use_brew_paths
  command -v brew >/dev/null
}

# brew_install NAME FORMULA DOWNLOAD-PAGE
brew_install() {
  if ! ask "Install $1 now?"; then
    say "Skipped. You can install $1 yourself from $3"
    return 1
  fi
  if ! brew_ready; then
    open_page "$3"
    return 1
  fi
  say "Installing $1 with Homebrew."
  if ! brew install "$2"; then
    say "Homebrew could not install $1."
    open_page "$3"
    return 1
  fi
  use_brew_paths
}

echo
say "VB Harness" "=========="
echo

[[ -f exe/harness ]] || fail "This file has to run from the unzipped folder." \
  "Double-click the ZIP you downloaded, open the new folder and double-click \"Start VB Harness\" there."

use_brew_paths

if ! git_ok; then
  say "Git is missing. VB Harness uses Git to keep every change on its own branch, so a build can" \
      "always be undone. On a Mac it comes with Apple's Command Line Tools."
  if ask "Install Apple's Command Line Tools now?"; then
    xcode-select --install
    fail "A window from Apple opens: choose Install and wait until it says it is done." \
      "Then double-click \"Start VB Harness\" again."
  fi
  say "Skipped. Without Git, VB Harness can show you around but cannot build."
  echo
fi

if ! command -v node >/dev/null; then
  say "Node.js is missing. It runs website projects: \"New Astro site\" needs it. You can skip it" \
      "if you only build other kinds of projects."
  brew_install "Node.js" node "https://nodejs.org/en/download"
  echo
fi

if ! ruby_ok; then
  say "VB Harness is written in Ruby and needs version 3.3 or newer, which this Mac does not have yet."
  brew_install "Ruby" ruby "https://www.ruby-lang.org/en/documentation/installation/"
  ruby_ok || fail "VB Harness cannot start without Ruby 3.3 or newer." \
    "Install it, then double-click \"Start VB Harness\" again."
  echo
fi

say "Starting VB Harness. Your browser opens in a moment." \
    "Keep this window open while you use it. Close it to stop VB Harness."
echo
ruby exe/harness ui --open ||
  fail "VB Harness stopped with an error; the message is above." \
    "If it says it cannot listen on port 4567, VB Harness is probably already open in another window."
