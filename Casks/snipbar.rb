cask "snipbar" do
  version "1.0.1"
  sha256 "5eaf6bc15f6a102949dd314a445ad29f262c2dbcd4293c85f9623fc7d61222e7"

  url "https://github.com/joeyxmonkey/SnipBar/releases/download/v#{version}/SnipBar-#{version}.zip"
  name "SnipBar"
  desc "Screen snipping tool with a global keyboard shortcut"
  homepage "https://github.com/joeyxmonkey/SnipBar"

  depends_on macos: :sonoma

  app "SnipBar.app"
end
