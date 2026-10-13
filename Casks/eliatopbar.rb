# typed: false
# frozen_string_literal: true

# This file is a Homebrew cask. The repository doubles as a Homebrew tap:
#   Casks/  ->  brew tap vakandi/Elia-Topbar
#   then   ->  brew install --cask vakandi/Elia-Topbar/EliaTopBar
#
# `brew tap <user>/<repo>` clones the repository into a locally named
# homebrew-<repo> directory, so this repo does not need to be renamed.

cask "eliatopbar" do
  version "2.3"
  sha256 "b619b26661d0ef2b99cb931c88e4b74a98813ab8673277bf28a9363a737512eb"

  url "https://github.com/vakandi/Elia-Topbar/releases/download/v#{version}/EliaTopBar-v#{version}.dmg"
  name "EliaTopBar"
  desc "Native macOS menu bar command center for the Elia agent ecosystem"
  homepage "https://github.com/vakandi/Elia-Topbar"

  depends_on macos: ">= :ventura"

  app "EliaTopBar.app"

  # Ad-hoc signed, not notarized. Without this a Gatekeeper-blocked download
  # cannot be opened at all, which is the first thing a new user hits.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "/Applications/EliaTopBar.app"],
                   must_succeed: false
  end

  # The app only writes under the user's home, so uninstall needs no sudo.
  # A `delete:` stanza pointing at /Library would make plain uninstall fail.
  uninstall quit: "com.elia.elia-topbar"

  zap trash: [
    "~/Library/Application Support/EliaTopBar",
    "~/Library/Logs/EliaTopBar",
    "~/Library/Preferences/com.elia.elia-topbar.plist",
  ]

  caveats <<~EOS
    EliaTopBar is ad-hoc signed and not notarized by Apple. The cask removes
    the quarantine flag for you. If macOS still refuses to open it:
      xattr -dr com.apple.quarantine /Applications/EliaTopBar.app

    EliaTopBar is a menu bar app (LSUIElement). There is no Dock icon — look for
    it in the menu bar, next to the system status items.

    "uninstall" leaves your agent photos in place; use "brew uninstall --zap"
    to remove those too.
  EOS
end