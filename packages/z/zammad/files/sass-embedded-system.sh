#!/bin/sh
# Rebuilds the sass-embedded gem in vendor/cache so that its install uses the
# system Dart Sass (/usr/bin/sass, the dart-sass package) instead of
# downloading a prebuilt one: its ext/sass/Rakefile's dart-sass/sass task
# writes a wrapper script. (Zammad's Gemfile.lock has no CHECKSUMS section,
# so a rebuilt gem is accepted.)
set -eu
cache=$1
g=$(cd "$cache" && ls sass-embedded-[0-9]*.gem | head -n1)
v=${g#sass-embedded-}; v=${v%.gem}
w=/tmp/sass-embedded-rebuild
rm -rf "$w" && mkdir -p "$w" && cd "$w"
gem unpack "$cache/$g"
gem spec "$cache/$g" --ruby > sass-embedded.gemspec
ruby -e '
f = ARGV[0]
s = File.read(f)
head = "file File.absolute_path(\x27dart-sass/sass\x27, ARCHDIR) do"
i = s.index(head) or abort("sass-embedded: dart-sass task not found")
j = s.index("\nend\n", i) + 5
s[i...j] = <<~RUBY
  #{head}
    dir = File.absolute_path("dart-sass", ARCHDIR)
    mkdir_p dir
    File.write(File.join(dir, "sass"), "#!/bin/sh\nexec /usr/bin/sass \"$@\"\n")
    chmod 0o755, File.join(dir, "sass")
  end
RUBY
File.write(f, s)
' "sass-embedded-$v/ext/sass/Rakefile"
grep -q '/usr/bin/sass' "sass-embedded-$v/ext/sass/Rakefile"
cd "sass-embedded-$v"
gem build ../sass-embedded.gemspec
rm -f "$cache/$g"
cp "sass-embedded-$v.gem" "$cache/$g"
echo "sass-embedded $v: uses /usr/bin/sass"
