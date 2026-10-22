# Homebrew formula for Floe. It lives in the Buecherfresser/homebrew-floe tap;
# scripts/release.sh fills in the version and checksum.
class Floe < Formula
  desc "Tiling window manager for macOS that works with SIP on"
  homepage "https://github.com/Buecherfresser/floe"
  url "https://github.com/Buecherfresser/floe/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/Buecherfresser/floe.git", branch: "main"

  depends_on macos: :tahoe

  def install
    # SwiftPM's own sandbox doesn't work inside Homebrew's.
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    ENV["SIGN_IDENTITY"] = "-"
    system "./scripts/build-release.sh", version.to_s
    prefix.install "dist/Floe.app"
    bin.install "scripts/sign-local.sh" => "floe-sign"
  end

  def caveats
    <<~EOS
      Put Floe into your Applications folder and start it:
        ln -sfn #{opt_prefix}/Floe.app /Applications/Floe.app
        open /Applications/Floe.app

      Sign it once, so macOS keeps Floe's Accessibility permission across updates
      (asks for your password the first time):
        floe-sign #{opt_prefix}/Floe.app

      Floe updates itself through Homebrew from then on.
    EOS
  end

  test do
    assert_path_exists prefix/"Floe.app/Contents/MacOS/Floe"
  end
end
