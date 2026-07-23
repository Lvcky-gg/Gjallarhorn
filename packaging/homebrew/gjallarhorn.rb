# Homebrew formula for the Gjallarhorn CLI.
#
# This is the canonical copy; the live formula lives in the tap repo
# (Lvcky-gg/homebrew-tap → Formula/gjallarhorn.rb). The homebrew-bump workflow
# (.github/workflows/homebrew-bump.yml) keeps the tap's url + sha256 in sync on
# each release. Seed the tap by copying this file there once.
#
#   brew install lvcky-gg/tap/gjallarhorn
#
# Builds from source with the Odin compiler. Odin is a build- AND run-time
# dependency: `gjallarhorn run` / `build` exec `odin`, and `new` scaffolds Odin
# projects. NOTE: verify `brew info odin` exists in your taps — if Homebrew has no
# `odin` formula, add one to the tap (or document `brew install odin` first).
class Gjallarhorn < Formula
  desc "From-scratch Odin web framework, ORM and template engine, with a scaffolding CLI"
  homepage "https://github.com/Lvcky-gg/Gjallarhorn"
  url "https://github.com/Lvcky-gg/Gjallarhorn/archive/refs/tags/1.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # bumped on release
  license "MIT"
  head "https://github.com/Lvcky-gg/Gjallarhorn.git", branch: "main"

  depends_on "odin"

  def install
    # `-out:gjallarhorn` would collide with the gjallarhorn/ package dir.
    system "odin", "build", "cli", "-out:gjallarhorn.bin", "-o:speed"

    # The real binary goes in libexec; a wrapper in bin sets GJALLARHORN_LIB so
    # `gjallarhorn new` vendors the framework we install below. Homebrew already
    # puts `odin` on PATH for `run` / `build`.
    libexec.install "gjallarhorn.bin" => "gjallarhorn"
    pkgshare.install "gjallarhorn" # -> <prefix>/share/gjallarhorn/gjallarhorn
    (bin/"gjallarhorn").write_env_script libexec/"gjallarhorn",
      GJALLARHORN_LIB: pkgshare/"gjallarhorn"
  end

  test do
    assert_match "gjallarhorn CLI", shell_output("#{bin}/gjallarhorn help")

    # `new` should scaffold a project and vendor the framework via GJALLARHORN_LIB.
    system bin/"gjallarhorn", "new", "smoke"
    assert_predicate testpath/"smoke/main.odin", :exist?
    assert_predicate testpath/"smoke/gjallarhorn/mimir.odin", :exist?
  end
end
