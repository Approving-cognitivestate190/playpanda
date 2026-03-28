Output demo.gif

Set Shell "zsh"
Set FontSize 16
Set Width 900
Set Height 600
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 40ms

# Hidden setup
Hide
Type "alias playpanda=$PWD/zig-out/bin/playpanda"
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 300ms
Show

# Simple fetch
Type "# Fetch any webpage as LLM-ready markdown"
Enter
Sleep 800ms
Type "playpanda https://example.com"
Sleep 300ms
Enter
Sleep 3s

# GitHub page
Type ""
Enter
Type "# Works on JS-rendered pages"
Enter
Sleep 800ms
Type "playpanda https://github.com/nicoxiang/lightpanda-io/browser 2>/dev/null | head -15"
Sleep 300ms
Enter
Sleep 5s

# Multiple URLs
Type ""
Enter
Type "# Multiple URLs at once"
Enter
Sleep 500ms
Type "playpanda https://example.com,https://ziglang.org 2>/dev/null | head -20"
Sleep 300ms
Enter
Sleep 5s

# Show help
Type ""
Enter
Type "# Simple CLI — 4 commands"
Enter
Sleep 500ms
Type "playpanda --help"
Sleep 300ms
Enter
Sleep 3s

Sleep 2s
